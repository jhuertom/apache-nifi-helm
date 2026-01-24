# Guía de Configuración de Apache NiFi con LDAP en Kubernetes

## Resumen Ejecutivo

Este documento detalla la configuración completa de un clúster Apache NiFi 2.x con autenticación LDAP en Kubernetes, incluyendo todos los problemas encontrados y sus soluciones.

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│  │   nifi-0    │     │   nifi-1    │     │   nifi-2    │           │
│  │             │◄───►│             │◄───►│             │           │
│  │ CN=nifi-0.  │     │ CN=nifi-1.  │     │ CN=nifi-2.  │           │
│  │ nifi.nifi   │     │ nifi.nifi   │     │ nifi.nifi   │           │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘           │
│         │                   │                   │                   │
│         └─────────────┬─────┴─────────────┬─────┘                   │
│                       │                   │                         │
│              ┌────────▼────────┐ ┌────────▼────────┐               │
│              │  Ingress (TLS)  │ │    OpenLDAP     │               │
│              │  CN=nifi.nifi   │ │  ldap://...389  │               │
│              └────────┬────────┘ └─────────────────┘               │
│                       │                                             │
└───────────────────────┼─────────────────────────────────────────────┘
                        │
                   ┌────▼────┐
                   │ Usuario │
                   │nifiadmin│
                   └─────────┘
```

## Componentes Clave

| Componente | Valor |
|------------|-------|
| **NiFi Version** | 2.7.2 |
| **Nodos del Clúster** | 3 (nifi-0, nifi-1, nifi-2) |
| **Namespace** | nifi |
| **OpenLDAP URL** | ldap://openldap.ldap.svc.cluster.local:389 |
| **Manager DN** | cn=admin,dc=local |
| **User Search Base** | ou=people,dc=local |
| **Admin LDAP** | nifiadmin |
| **Identity Strategy** | USE_USERNAME |

---

## Problemas Encontrados y Soluciones

### 1. Error: "Insufficient Permissions"

**Síntoma:**
```
Unable to view the user interface. Insufficient Permissions
```

**Causa:**
La configuración de `Identity Strategy` estaba configurada como `USE_DN`, lo que hacía que NiFi esperara el DN completo del usuario (ej: `cn=nifiadmin,ou=people,dc=local`) en lugar del nombre de usuario simple (`nifiadmin`).

**Solución:**
Cambiar `Identity Strategy` a `USE_USERNAME` en `login-identity-providers.xml`:

```xml
<property name="Identity Strategy">USE_USERNAME</property>
```

Y también en `authorizers.xml` para el `ldap-user-group-provider`:
```xml
<property name="Identity Strategy">USE_USERNAME</property>
```

---

### 2. Error: "Multiple UserGroupProviders claiming user"

**Síntoma:**
```
Multiple UserGroupProviders claim to provide user nifi-admin. 
Ensure that providers are not configured to overlap
```

**Causa:**
El usuario estaba definido tanto en el `file-user-group-provider` como en el `ldap-user-group-provider`, causando un conflicto en el `composite-configurable-user-group-provider`.

**Solución:**
Configurar el `composite-configurable-user-group-provider` para usar **solo** el `ldap-user-group-provider` como proveedor no configurable:

```xml
<userGroupProvider>
    <identifier>composite-configurable-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.CompositeConfigurableUserGroupProvider</class>
    <property name="Configurable User Group Provider">file-user-group-provider</property>
    <property name="User Group Provider 1">ldap-user-group-provider</property>
    <!-- NO agregar file-user-group-provider aquí - ya es el Configurable -->
</userGroupProvider>
```

**Importante:** El `file-user-group-provider` ya está incluido como `Configurable User Group Provider`, por lo que NO debe agregarse también como `User Group Provider`.

---

### 3. Error: "No applicable policies could be found"

**Síntoma:**
```
Unable to view the user interface.
No applicable policies could be found. Contact the system administrator.
```

**Causa:**
Las políticas de autorización para el root process group no existían. Esto ocurre porque:
1. `users.xml` y `authorizations.xml` se crean ANTES de que exista `flow.json.gz`
2. Sin el flow, no se conoce el `ROOT_ID` del root process group
3. NiFi necesita políticas explícitas para `/process-groups/{ROOT_ID}`, `/data/process-groups/{ROOT_ID}`, y `/operation/process-groups/{ROOT_ID}`

**Solución:**
Implementar un mecanismo en el script de inicio que:
1. Detecte cuando existe `flow.json.gz` pero faltan las políticas del root group
2. Extraiga el `ROOT_ID` del flow
3. Agregue las políticas necesarias a `authorizations.xml`

```bash
# UPDATE ROOT GROUP POLICIES if flow.json.gz exists but policies are missing
if [ -f "$AUTH_XML" ] && [ -s "$FLOW_FILE" ]; then
    ROOT_ID=$(zcat "$FLOW_FILE" | jq -r '.rootGroup.identifier')
    if [ -n "$ROOT_ID" ] && ! grep -q "process-groups/$ROOT_ID" "$AUTH_XML"; then
        # Agregar políticas para el root group
        ...
    fi
fi
```

---

### 4. Error: Archivos de autorización borrados en cada reinicio

**Síntoma:**
Los permisos configurados manualmente se perdían después de cada reinicio del pod.

**Causa:**
El script de inicio contenía un comando `rm -f` que eliminaba los archivos de autorización en cada inicio:

```bash
# INCORRECTO - Esto borraba los permisos en cada reinicio
rm -f "$PERSISTENT_CONF_DIR/users.xml" "$PERSISTENT_CONF_DIR/authorizations.xml"
```

**Solución:**
Eliminar el comando `rm -f` y solo crear los archivos si NO existen:

```bash
if [ ! -f "$USERS_XML" ] || [ ! -f "$AUTH_XML" ]; then
    # Crear archivos solo si no existen
    ...
fi
```

---

### 5. Error: "Untrusted proxy CN=nifi.nifi"

**Síntoma:**
```
Untrusted proxy CN=nifi.nifi
```

**Causa:**
El Ingress de Kubernetes usa un certificado TLS con CN=nifi.nifi para comunicarse con los nodos NiFi. Esta identidad necesita:
1. Estar registrada en `users.xml`
2. Tener permisos de `/proxy` (lectura y escritura)
3. Tener permisos de `/controller` (lectura y escritura)

**Solución:**
Agregar la identidad del Ingress a `users.xml`:

```xml
<user identifier="INGRESS_UUID" identity="CN=nifi.nifi"/>
```

Y agregar las políticas necesarias en `authorizations.xml`:

```xml
<!-- /proxy - Requerido para proxy de requests -->
<policy action="R" identifier="..." resource="/proxy">
    <user identifier="INGRESS_UUID"/>
</policy>
<policy action="W" identifier="..." resource="/proxy">
    <user identifier="INGRESS_UUID"/>
</policy>

<!-- /controller - Requerido para comunicación del clúster -->
<policy action="R" identifier="..." resource="/controller">
    <user identifier="INGRESS_UUID"/>
</policy>
<policy action="W" identifier="..." resource="/controller">
    <user identifier="INGRESS_UUID"/>
</policy>
```

---

### 6. Error: Sincronización de clúster sobrescribiendo políticas

**Síntoma:**
Después de modificar las políticas en un nodo, los cambios se perdían porque otro nodo del clúster sincronizaba sus archivos antiguos.

**Causa:**
NiFi sincroniza los archivos `users.xml` y `authorizations.xml` entre todos los nodos del clúster. Si un nodo tiene archivos diferentes, el clúster puede sobrescribirlos.

**Solución:**
Aplicar los mismos cambios en **TODOS** los nodos del clúster simultáneamente:

```bash
for node in nifi-0 nifi-1 nifi-2; do
    kubectl exec $node -n nifi -- bash -c "
        # Aplicar cambios a users.xml y authorizations.xml
        ...
    "
done
```

---

## Identidades Requeridas

Para un clúster NiFi con LDAP, se necesitan las siguientes identidades en `users.xml`:

| Identidad | Descripción | Ejemplo |
|-----------|-------------|---------|
| **Admin LDAP** | Usuario administrador de LDAP | `nifiadmin` |
| **Ingress** | Certificado del Ingress Controller | `CN=nifi.nifi` |
| **Nodo 0** | Certificado del primer nodo | `CN=nifi-0.nifi.nifi` |
| **Nodo 1** | Certificado del segundo nodo | `CN=nifi-1.nifi.nifi` |
| **Nodo 2** | Certificado del tercer nodo | `CN=nifi-2.nifi.nifi` |

---

## Políticas de Autorización Requeridas

### Políticas Globales

| Recurso | Acción | Usuarios |
|---------|--------|----------|
| `/flow` | R | Admin |
| `/controller` | R/W | Admin, Ingress, Todos los nodos |
| `/proxy` | R/W | Ingress, Todos los nodos |
| `/tenants` | R/W | Admin |
| `/policies` | R/W | Admin |
| `/restricted-components` | R/W | Admin |
| `/counters` | R/W | Admin |
| `/system` | R | Admin |
| `/provenance` | R/W | Admin |
| `/site-to-site` | R | Admin |

### Políticas del Root Process Group

| Recurso | Acción | Usuarios |
|---------|--------|----------|
| `/process-groups/{ROOT_ID}` | R/W | Admin |
| `/data/process-groups/{ROOT_ID}` | R/W | Admin, Todos los nodos |
| `/operation/process-groups/{ROOT_ID}` | R/W | Admin |

**Nota:** `{ROOT_ID}` es el UUID del root process group, que se obtiene de `flow.json.gz`.

---

## Configuración del Helm Chart

### values.yaml - Sección LDAP

```yaml
global:
  ldap:
    enabled: true
    url: "ldap://openldap.ldap.svc.cluster.local:389"
    authenticationStrategy: "SIMPLE"
    manager:
      distinguishedName: "cn=admin,dc=local"
    userSearchBase: "ou=people,dc=local"
    userSearchFilter: "(uid={0})"
    identityStrategy: "USE_USERNAME"
    initialAdminIdentity: "nifiadmin"
    tlsProtocol: "TLS"
  nifi:
    nodeCount: 3
  tls:
    certificate: "nifi-tls"
```

### Secreto para contraseña LDAP

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: nifi-ldap-credentials
  namespace: nifi
type: Opaque
stringData:
  ldap-manager-password: "your-ldap-password"
```

---

## Generación de UUIDs Determinísticos

Para garantizar que los UUIDs sean consistentes entre reinicios y entre nodos, se usa una función de generación determinística basada en MD5:

```bash
GET_UUID() {
  python3 -c "
import uuid, hashlib
md5 = hashlib.md5('$1'.encode('utf-8')).digest()
uid = list(md5)
uid[6] = (uid[6] & 0x0f) | 0x30  # Version 3
uid[8] = (uid[8] & 0x3f) | 0x80  # Variant
print(str(uuid.UUID(bytes=bytes(uid))))
"
}

# Ejemplos de uso:
ADMIN_ID=$(GET_UUID "user-nifiadmin")
POLICY_ID=$(GET_UUID "policy-/flow-R")
```

Esto garantiza que:
- El mismo input siempre genera el mismo UUID
- Los archivos `users.xml` y `authorizations.xml` son idénticos en todos los nodos
- No hay conflictos de sincronización en el clúster

---

## Estructura de Archivos

### users.xml

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<tenants>
  <groups/>
  <users>
    <user identifier="UUID-ADMIN" identity="nifiadmin"/>
    <user identifier="UUID-INGRESS" identity="CN=nifi.nifi"/>
    <user identifier="UUID-NODE0" identity="CN=nifi-0.nifi.nifi"/>
    <user identifier="UUID-NODE1" identity="CN=nifi-1.nifi.nifi"/>
    <user identifier="UUID-NODE2" identity="CN=nifi-2.nifi.nifi"/>
  </users>
</tenants>
```

### authorizations.xml (estructura simplificada)

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<authorizations>
  <policies>
    <!-- /flow - Solo admin -->
    <policy action="R" identifier="..." resource="/flow">
      <user identifier="UUID-ADMIN"/>
    </policy>
    
    <!-- /controller - Admin, Ingress y todos los nodos -->
    <policy action="R" identifier="..." resource="/controller">
      <user identifier="UUID-ADMIN"/>
      <user identifier="UUID-INGRESS"/>
      <user identifier="UUID-NODE0"/>
      <user identifier="UUID-NODE1"/>
      <user identifier="UUID-NODE2"/>
    </policy>
    
    <!-- /proxy - Ingress y todos los nodos -->
    <policy action="R" identifier="..." resource="/proxy">
      <user identifier="UUID-INGRESS"/>
      <user identifier="UUID-NODE0"/>
      <user identifier="UUID-NODE1"/>
      <user identifier="UUID-NODE2"/>
    </policy>
    
    <!-- Root Process Group -->
    <policy action="R" identifier="..." resource="/process-groups/ROOT-UUID">
      <user identifier="UUID-ADMIN"/>
    </policy>
    
    <!-- ... más políticas ... -->
  </policies>
</authorizations>
```

---

## Verificación de la Configuración

### 1. Verificar usuarios registrados

```bash
kubectl exec nifi-0 -n nifi -- cat /opt/nifi/nifi-current/persistent_conf/users.xml
```

### 2. Verificar políticas de autorización

```bash
kubectl exec nifi-0 -n nifi -- cat /opt/nifi/nifi-current/persistent_conf/authorizations.xml
```

### 3. Verificar configuración LDAP en authorizers.xml

```bash
kubectl exec nifi-0 -n nifi -- cat /opt/nifi/nifi-current/conf/authorizers.xml | grep -A 50 "ldap-user-group-provider"
```

### 4. Verificar configuración LDAP en login-identity-providers.xml

```bash
kubectl exec nifi-0 -n nifi -- cat /opt/nifi/nifi-current/conf/login-identity-providers.xml | grep -A 20 "ldap-provider"
```

### 5. Verificar logs de NiFi

```bash
kubectl logs nifi-0 -n nifi | grep -i "ldap\|auth\|permission\|identity"
```

### 6. Obtener ROOT_ID del flow

```bash
kubectl exec nifi-0 -n nifi -- bash -c "zcat /opt/nifi/nifi-current/persistent_conf/flow.json.gz | jq -r '.rootGroup.identifier'"
```

---

## Troubleshooting

### Problema: Usuario no puede ver la UI después de login

1. Verificar que el usuario existe en `users.xml`
2. Verificar que tiene política de `/flow` (Read)
3. Verificar que tiene políticas del root process group

### Problema: Error de proxy entre nodos

1. Verificar que todos los nodos están en `users.xml`
2. Verificar que tienen política de `/proxy` (Read/Write)
3. Verificar que tienen política de `/controller` (Read/Write)

### Problema: Cambios de políticas no persisten

1. Verificar que no hay `rm -f` en el script de inicio
2. Verificar que los cambios se aplican a TODOS los nodos
3. Verificar que los PVCs están correctamente montados

### Problema: Identity mismatch entre autenticación y autorización

1. Verificar que `Identity Strategy` es `USE_USERNAME` en ambos:
   - `login-identity-providers.xml` (ldap-provider)
   - `authorizers.xml` (ldap-user-group-provider)
2. Verificar que `User Identity Attribute` está configurado correctamente (ej: `uid`)

---

## Comandos Útiles

### Reiniciar todos los pods de NiFi

```bash
kubectl delete pod -n nifi -l app.kubernetes.io/name=nifi
```

### Forzar recreación completa (incluye PVCs)

```bash
kubectl delete pvc -n nifi --all
kubectl delete pod -n nifi --all
```

### Ver estado del clúster NiFi

```bash
kubectl exec nifi-0 -n nifi -- /opt/nifi/nifi-toolkit-current/bin/cli.sh nifi get-nodes \
  -u https://nifi-http.nifi:8443
```

### Exportar configuración actual

```bash
kubectl exec nifi-0 -n nifi -- tar czf - \
  /opt/nifi/nifi-current/persistent_conf/users.xml \
  /opt/nifi/nifi-current/persistent_conf/authorizations.xml \
  /opt/nifi/nifi-current/conf/authorizers.xml \
  /opt/nifi/nifi-current/conf/login-identity-providers.xml \
  > nifi-config-backup.tar.gz
```

---

## Referencias

- [Apache NiFi Administration Guide](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html)
- [Apache NiFi LDAP Authentication](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#ldap_login_identity_provider)
- [Apache NiFi Authorizers Configuration](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#authorizers-configuration)
- [NiFi Cluster Communication](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#clustering)

---

## Historial de Cambios

| Fecha | Versión | Descripción |
|-------|---------|-------------|
| 2026-01-24 | 1.0 | Documentación inicial con todas las soluciones |
