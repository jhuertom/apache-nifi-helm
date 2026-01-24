# Configuración de Apache NiFi con LDAP

## Resumen

Esta documentación describe los pasos necesarios para configurar un clúster de Apache NiFi con autenticación LDAP y los problemas encontrados durante el proceso.

---

## Arquitectura

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     NiFi-1      │     │     NiFi-2      │     │     NiFi-3      │
│   (puerto 8443) │     │   (puerto 8444) │     │   (puerto 8445) │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │      OpenLDAP           │
                    │    (puerto 389/636)     │
                    └─────────────────────────┘
```

---

## Archivos de Configuración

### 1. `docker-compose.yml`

Contiene la definición de los servicios:
- **ldap**: Servidor OpenLDAP
- **phpldapadmin**: Interfaz web para administrar LDAP (puerto 8080)
- **nifi-1, nifi-2, nifi-3**: Nodos del clúster NiFi

**Configuración importante en cada nodo NiFi:**

```yaml
environment:
  - NIFI_SECURITY_USER_LOGIN_IDENTITY_PROVIDER=ldap-provider
  - NIFI_SECURITY_USER_AUTHORIZER=managed-authorizer
```

**En el entrypoint de cada nodo:**

```bash
update_prop "nifi.security.user.login.identity.provider" "ldap-provider"
update_prop "nifi.security.user.authorizer" "managed-authorizer"

# IMPORTANTE: Eliminar archivos de autorización existentes al iniciar
rm -f /opt/nifi/nifi-current/conf/users.xml /opt/nifi/nifi-current/conf/authorizations.xml
```

---

### 2. `login-identity-providers.xml`

Define cómo NiFi autentica usuarios contra LDAP.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<loginIdentityProviders>
    <provider>
        <identifier>ldap-provider</identifier>
        <class>org.apache.nifi.ldap.LdapProvider</class>
        <property name="Authentication Strategy">SIMPLE</property>
        <property name="Manager DN">cn=admin,dc=nifi,dc=org</property>
        <property name="Manager Password">admin</property>
        <property name="Referral Strategy">FOLLOW</property>
        <property name="Connect Timeout">10 secs</property>
        <property name="Read Timeout">10 secs</property>
        <property name="Url">ldap://ldap:389</property>
        <property name="User Search Base">ou=users,dc=nifi,dc=org</property>
        <property name="User Search Filter">uid={0}</property>
        <property name="Identity Strategy">USE_USERNAME</property>  <!-- ⚠️ CRÍTICO -->
        <property name="Authentication Expiration">12 hours</property>
    </provider>
</loginIdentityProviders>
```

#### ⚠️ Problema Resuelto #1: Identity Strategy

**Error:** `Insufficient Permissions - Unable to view the user interface`

**Causa:** `Identity Strategy` estaba configurado como `USE_DN`, lo que generaba identidades como `uid=nifi-admin,ou=users,dc=nifi,dc=org`, pero el `Initial Admin Identity` en `authorizers.xml` esperaba `nifi-admin`.

**Solución:** Cambiar `Identity Strategy` de `USE_DN` a `USE_USERNAME`

---

### 3. `authorizers.xml`

Define los proveedores de usuarios/grupos y las políticas de acceso.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizers>
    <!-- Proveedor de usuarios desde archivo (para nodos del clúster) -->
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <!-- ⚠️ NO incluir nifi-admin aquí si viene de LDAP -->
        <property name="Initial User Identity 1">CN=localhost, OU=NiFi, O=NiFi, L=Santa Clara, ST=CA, C=US</property>
    </userGroupProvider>

    <!-- Proveedor de usuarios desde LDAP -->
    <userGroupProvider>
        <identifier>ldap-user-group-provider</identifier>
        <class>org.apache.nifi.ldap.tenants.LdapUserGroupProvider</class>
        <property name="Authentication Strategy">SIMPLE</property>
        <property name="Manager DN">cn=admin,dc=nifi,dc=org</property>
        <property name="Manager Password">admin</property>
        <property name="Url">ldap://ldap:389</property>
        <property name="Referral Strategy">FOLLOW</property>
        <property name="Connect Timeout">10 secs</property>
        <property name="Read Timeout">10 secs</property>

        <!-- Configuración de búsqueda de usuarios -->
        <property name="User Search Base">ou=users,dc=nifi,dc=org</property>
        <property name="User Object Class">inetOrgPerson</property>
        <property name="User Search Scope">SUBTREE</property>
        <property name="User Search Filter">(uid=*)</property>
        <property name="User Identity Attribute">uid</property>

        <!-- Configuración de búsqueda de grupos -->
        <property name="Group Search Base">ou=groups,dc=nifi,dc=org</property>
        <property name="Group Object Class">posixGroup</property>
        <property name="Group Search Scope">SUBTREE</property>
        <property name="Group Search Filter">(cn=*)</property>
        <property name="Group Name Attribute">cn</property>
        <property name="Group Member Attribute">memberUid</property>

        <property name="Sync Interval">5 mins</property>
    </userGroupProvider>

    <!-- Proveedor compuesto que combina archivo + LDAP -->
    <userGroupProvider>
        <identifier>composite-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.CompositeUserGroupProvider</class>
        <property name="User Group Provider 1">file-user-group-provider</property>
        <property name="User Group Provider 2">ldap-user-group-provider</property>
    </userGroupProvider>

    <!-- Proveedor de políticas de acceso -->
    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">composite-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">nifi-admin</property>  <!-- Usuario de LDAP -->
        <property name="Node Identity 1">CN=localhost, OU=NiFi, O=NiFi, L=Santa Clara, ST=CA, C=US</property>
    </accessPolicyProvider>

    <!-- Autorizador principal -->
    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>
</authorizers>
```

#### ⚠️ Problema Resuelto #2: Usuario duplicado en múltiples proveedores

**Error:** `Multiple UserGroupProviders are claiming to provide user nifi-admin`

**Causa:** El usuario `nifi-admin` estaba definido tanto en `file-user-group-provider` (como `Initial User Identity`) como en `ldap-user-group-provider` (desde LDAP).

**Solución:** Eliminar `nifi-admin` del `file-user-group-provider`. Solo debe existir en un proveedor.

---

### 4. `setup-ldap.sh`

Script para crear la estructura de usuarios y grupos en LDAP.

```bash
#!/bin/bash

cat <<EOF > init.ldif
dn: ou=users,dc=nifi,dc=org
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=nifi,dc=org
objectClass: organizationalUnit
ou: groups

dn: uid=nifi-admin,ou=users,dc=nifi,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: nifi-admin
sn: Admin
cn: NiFi Admin
displayName: NiFi Admin
uidNumber: 10000
gidNumber: 10000
userPassword: nifi-password
homeDirectory: /home/nifi-admin
loginShell: /bin/bash

dn: cn=nifi-admins,ou=groups,dc=nifi,dc=org
objectClass: posixGroup
cn: nifi-admins
gidNumber: 10000
memberUid: nifi-admin
EOF

docker exec -i ldap-server ldapadd -x -w admin -D "cn=admin,dc=nifi,dc=org" < init.ldif
rm init.ldif
```

---

## Procedimiento de Instalación

### Paso 1: Iniciar los servicios

```bash
docker compose up -d
```

### Paso 2: Esperar que LDAP inicie (10-15 segundos)

```bash
sleep 15
```

### Paso 3: Crear usuarios en LDAP

```bash
bash setup-ldap.sh
```

### Paso 4: Esperar que NiFi inicie completamente (1-2 minutos)

```bash
docker logs -f nifi-1
# Esperar hasta ver: "Started Server on https://nifi-1:8443/nifi"
```

### Paso 5: Acceder a NiFi

- **URL:** https://localhost:8443/nifi
- **Usuario:** nifi-admin
- **Contraseña:** nifi-password

---

## Solución de Problemas

### Problema: "Insufficient Permissions"

**Síntoma:** El usuario puede iniciar sesión pero no puede ver la interfaz.

**Soluciones:**

1. Verificar que `Identity Strategy` sea `USE_USERNAME` en `login-identity-providers.xml`
2. Verificar que `Initial Admin Identity` coincida exactamente con el `uid` del usuario LDAP
3. Eliminar archivos de autorización y reiniciar:

```bash
docker exec nifi-1 rm -f /opt/nifi/nifi-current/conf/users.xml /opt/nifi/nifi-current/conf/authorizations.xml
docker exec nifi-2 rm -f /opt/nifi/nifi-current/conf/users.xml /opt/nifi/nifi-current/conf/authorizations.xml
docker exec nifi-3 rm -f /opt/nifi/nifi-current/conf/users.xml /opt/nifi/nifi-current/conf/authorizations.xml
docker compose restart nifi-1 nifi-2 nifi-3
```

### Problema: "Multiple UserGroupProviders are claiming to provide user"

**Síntoma:** Error en los logs indicando que múltiples proveedores reclaman el mismo usuario.

**Solución:** Asegurar que cada usuario solo exista en UN proveedor:
- Usuarios de LDAP: Solo en `ldap-user-group-provider`
- Identidades de nodos (certificados): Solo en `file-user-group-provider`

### Problema: "No applicable policies could be found"

**Síntoma:** Error después de iniciar sesión.

**Solución:** Los archivos `users.xml` y `authorizations.xml` tienen datos corruptos o de una configuración anterior. Eliminarlos y reiniciar.

---

## Verificación de la Configuración

### Verificar conexión LDAP

```bash
docker exec ldap-server ldapsearch -x -b "dc=nifi,dc=org" -D "cn=admin,dc=nifi,dc=org" -w admin
```

### Verificar usuarios en LDAP

```bash
docker exec ldap-server ldapsearch -x -b "ou=users,dc=nifi,dc=org" -D "cn=admin,dc=nifi,dc=org" -w admin "(uid=*)"
```

### Verificar logs de NiFi

```bash
docker logs nifi-1 2>&1 | grep -E "(LDAP|ldap|authentication|authorization|ERROR)"
```

---

## Resumen de Configuraciones Críticas

| Archivo | Propiedad | Valor Correcto |
|---------|-----------|----------------|
| login-identity-providers.xml | Identity Strategy | `USE_USERNAME` |
| authorizers.xml | Initial Admin Identity | `nifi-admin` (debe coincidir con uid de LDAP) |
| authorizers.xml | file-user-group-provider | NO incluir usuarios que vienen de LDAP |
| docker-compose.yml | nifi.security.user.login.identity.provider | `ldap-provider` |
| docker-compose.yml | nifi.security.user.authorizer | `managed-authorizer` |

---

## Credenciales

| Servicio | Usuario | Contraseña |
|----------|---------|------------|
| LDAP Admin | cn=admin,dc=nifi,dc=org | admin |
| NiFi Admin | nifi-admin | nifi-password |
| phpLDAPadmin | cn=admin,dc=nifi,dc=org | admin |

---

## Puertos

| Servicio | Puerto |
|----------|--------|
| NiFi Node 1 | 8443 (HTTPS) |
| NiFi Node 2 | 8444 (HTTPS) |
| NiFi Node 3 | 8445 (HTTPS) |
| LDAP | 389 (LDAP), 636 (LDAPS) |
| phpLDAPadmin | 8080 (HTTP) |

---

## Referencias

- [Apache NiFi Admin Guide - User Authentication](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#user_authentication)
- [Apache NiFi Admin Guide - LDAP](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#ldap_login_identity_provider)
- [Apache NiFi Admin Guide - Authorizers](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#authorizers-setup)
