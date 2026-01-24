# Arquitectura de Autenticación LDAP en NiFi

## Flujo de Autenticación

```
┌─────────────────────────────────────────────────────────────────┐
│                        Usuario Accede                            │
│                    https://nifi.company.com                      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    NiFi Web Interface                            │
│                  (puerto 8443, HTTPS)                            │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              login-identity-providers.xml                        │
│                   (Autenticación)                                │
│                                                                   │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  ldap-provider                                          │    │
│  │  • Authentication Strategy: SIMPLE/LDAPS/START_TLS     │    │
│  │  • Identity Strategy: USE_USERNAME (recomendado)       │    │
│  │  • URL: ldap://ldap-server:389                         │    │
│  │  • User Search Base: ou=users,dc=nifi,dc=org          │    │
│  │  • User Search Filter: uid={0}                         │    │
│  └────────────────────┬───────────────────────────────────┘    │
└───────────────────────┼────────────────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │   Servidor LDAP/AD            │
        │   • Valida credenciales       │
        │   • Retorna atributos usuario │
        └───────────────┬───────────────┘
                        │
                        ▼ (Usuario autenticado)
┌─────────────────────────────────────────────────────────────────┐
│                    authorizers.xml                               │
│                   (Autorización)                                 │
│                                                                   │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  composite-configurable-user-group-provider             │    │
│  │                                                          │    │
│  │  1. file-user-group-provider                            │    │
│  │     • Identidades de nodos (certificados)               │    │
│  │     • CN=nifi-0.nifi.namespace, etc.                   │    │
│  │                                                          │    │
│  │  2. ldap-user-group-provider                            │    │
│  │     • Usuarios de LDAP                                  │    │
│  │     • User Identity Attribute: uid                      │    │
│  │     • Sincroniza grupos cada 5 minutos                  │    │
│  └────────────────────┬───────────────────────────────────┘    │
│                       │                                          │
│  ┌────────────────────▼───────────────────────────────────┐    │
│  │  file-access-policy-provider                            │    │
│  │  • Initial Admin Identity: nifi-admin                   │    │
│  │  • Políticas almacenadas en authorizations.xml         │    │
│  │  • users.xml vincula identidades con permisos          │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Acceso Concedido/Denegado                       │
└─────────────────────────────────────────────────────────────────┘
```

## Archivos Generados en Persistent Storage

```
/opt/nifi/nifi-current/persistent_conf/
│
├── users.xml
│   └── Contiene:
│       • Usuarios de LDAP (sincronizados)
│       • Identidades de nodos del cluster
│       • Grupos (si groupSearchBase está configurado)
│
├── authorizations.xml
│   └── Contiene:
│       • Políticas de acceso por recurso (/flow, /controller, etc.)
│       • Asignaciones de usuarios/grupos a políticas
│       • Se genera automáticamente al inicio si no existe
│
└── flow.json.gz
    └── Definición del flujo de datos de NiFi
```

## Proceso de Inicio con LDAP

```
┌────────────────────────────────────────────────────────────┐
│ 1. Pod Inicia (custom-startup.sh)                          │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 2. Detecta LDAP habilitado                                 │
│    • global.ldap.enabled: true                             │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 3. Limpia archivos previos (IMPORTANTE)                    │
│    • rm -f users.xml authorizations.xml                    │
│    • Previene conflictos de configuración anterior         │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 4. Configura login-identity-providers.xml                  │
│    • Elimina single-user-provider                          │
│    • Crea/actualiza ldap-provider                          │
│    • Establece todas las propiedades LDAP                  │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 5. Configura authorizers.xml                               │
│    • Habilita ldap-user-group-provider                     │
│    • Configura composite-configurable-user-group-provider  │
│    • Establece Initial Admin Identity                      │
│    • Registra identidades de nodos del cluster             │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 6. NiFi Inicia                                             │
│    • Lee configuraciones                                    │
│    • Conecta a LDAP                                        │
│    • Genera users.xml y authorizations.xml si no existen  │
│    • Sincroniza usuarios/grupos de LDAP                   │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────────────────────┐
│ 7. Sistema Listo                                           │
│    • UI accesible                                          │
│    • Initial Admin puede iniciar sesión                    │
│    • Usuarios LDAP pueden autenticarse                     │
└────────────────────────────────────────────────────────────┘
```

## Comparación: Identity Strategy

### USE_USERNAME (Recomendado)

```
Usuario ingresa: nifi-admin
                    ↓
           [LDAP Valida]
                    ↓
      Identidad en NiFi: nifi-admin
                    ↓
  Initial Admin Identity: nifi-admin
                    ↓
            ✅ COINCIDE
                    ↓
          Acceso Concedido
```

### USE_DN (NO Recomendado)

```
Usuario ingresa: nifi-admin
                    ↓
           [LDAP Valida]
                    ↓
      Identidad en NiFi: uid=nifi-admin,ou=users,dc=nifi,dc=org
                    ↓
  Initial Admin Identity: nifi-admin
                    ↓
          ❌ NO COINCIDE
                    ↓
  "Insufficient Permissions" Error
```

**Solución para USE_DN:**
```yaml
identityStrategy: USE_DN
initialAdminIdentity: "uid=nifi-admin,ou=users,dc=nifi,dc=org"  # DN completo
```

## Composite User Group Provider

El provider compuesto combina múltiples fuentes de usuarios:

```
composite-configurable-user-group-provider
│
├── 1. file-user-group-provider (Nodos del cluster)
│   ├── CN=nifi-0.nifi.namespace
│   ├── CN=nifi-1.nifi.namespace
│   └── CN=nifi-2.nifi.namespace
│
└── 2. ldap-user-group-provider (Usuarios LDAP)
    ├── nifi-admin
    ├── user1
    └── user2
        └── Groups:
            ├── nifi-admins
            └── nifi-users
```

**Reglas Importantes:**
1. Cada usuario debe existir en **solo UN** provider
2. Los nodos (certificados) van en `file-user-group-provider`
3. Los usuarios LDAP van en `ldap-user-group-provider`
4. El orden importa: file primero, LDAP segundo

## Sincronización LDAP

```
NiFi ejecuta cada 5 minutos:
│
├── Consulta LDAP
│   ├── User Search Base: ou=users,dc=nifi,dc=org
│   ├── User Search Filter: (uid=*)
│   └── User Identity Attribute: uid
│
├── Actualiza users.xml
│   ├── Agrega nuevos usuarios
│   ├── Actualiza atributos existentes
│   └── NO elimina usuarios (solo marca como inactivos)
│
└── Si groupSearchBase configurado:
    ├── Consulta grupos LDAP
    ├── Actualiza membresías
    └── Mantiene sincronizado con LDAP
```

## Ejemplo de Estructura LDAP

```
dc=nifi,dc=org
│
├── ou=users (userSearchBase)
│   ├── uid=nifi-admin (initialAdminIdentity)
│   │   ├── cn: NiFi Admin
│   │   ├── sn: Admin
│   │   └── userPassword: {SSHA}...
│   │
│   ├── uid=user1
│   │   └── ...
│   │
│   └── uid=user2
│       └── ...
│
└── ou=groups (groupSearchBase)
    ├── cn=nifi-admins
    │   ├── memberUid: nifi-admin
    │   └── memberUid: user1
    │
    └── cn=nifi-users
        └── memberUid: user2
```

## Troubleshooting Flow

```
                  [Problema]
                      │
        ┌─────────────┼─────────────┐
        │                           │
        ▼                           ▼
[Login Falla]              [Login OK, Sin Permisos]
        │                           │
        ▼                           ▼
1. Verifica conexión      1. Verifica Identity Strategy
   a LDAP                    • USE_USERNAME vs USE_DN
        │                           │
2. Verifica Manager        2. Verifica Initial Admin Identity
   DN y password              • Debe coincidir exactamente
        │                           │
3. Verifica User           3. Revisa logs:
   Search Base/Filter         • kubectl logs nifi-0 | grep -i ldap
        │                           │
4. Test manual:            4. Limpia y reinicia:
   ldapsearch ...             • Borra PVC config
                              • Redespliega
```

## Comandos Útiles

```bash
# Ver configuración LDAP en el pod
kubectl exec -it nifi-0 -- cat /opt/nifi/nifi-current/conf/login-identity-providers.xml

# Ver configuración de autorización
kubectl exec -it nifi-0 -- cat /opt/nifi/nifi-current/conf/authorizers.xml

# Ver usuarios sincronizados
kubectl exec -it nifi-0 -- cat /opt/nifi/nifi-current/persistent_conf/users.xml

# Ver políticas de acceso
kubectl exec -it nifi-0 -- cat /opt/nifi/nifi-current/persistent_conf/authorizations.xml

# Ver logs de autenticación
kubectl logs nifi-0 | grep -i "ldap\|authentication\|authorization"

# Probar conexión LDAP desde el pod
kubectl exec -it nifi-0 -- nc -zv ldap-server 389

# Test LDAP search manual
kubectl exec -it nifi-0 -- ldapsearch -x -H ldap://ldap-server:389 \
  -D "cn=admin,dc=nifi,dc=org" -w "admin" \
  -b "ou=users,dc=nifi,dc=org" "(uid=nifi-admin)"
```
