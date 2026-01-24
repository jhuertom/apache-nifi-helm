# Resumen de Cambios para Soporte LDAP

## Fecha
24 de enero de 2026

## Objetivo
Adaptar el Helm chart de Apache NiFi para que funcione correctamente con autenticación LDAP, basándose en la configuración de Docker documentada en `DOCUMENTACION_NIFI_LDAP.md`.

## Problemas Identificados en la Configuración Original

1. **Falta configuración de login-identity-providers.xml**: El Helm chart no configuraba el proveedor LDAP en login-identity-providers.xml, solo eliminaba el proveedor de usuario único.

2. **Orden incorrecto del composite provider**: El orden de los proveedores en el composite-user-group-provider no seguía las mejores prácticas.

3. **No se limpiaban archivos de autorización**: Los archivos `users.xml` y `authorizations.xml` previos no se eliminaban, causando conflictos al cambiar de autenticación básica a LDAP.

4. **Valores por defecto incorrectos**: Los valores por defecto en values.yaml asumían Active Directory con LDAPS, no eran apropiados para LDAP simple.

## Cambios Realizados

### 1. Archivo: `templates/configmap.yaml`

#### Cambio 1.1: Configuración completa de login-identity-providers.xml
**Líneas modificadas**: Sección de habilitación LDAP (~línea 70)

**Antes**:
```bash
xmlstarlet ed --inplace -d "//provider[identifier='single-user-provider']" 'conf/login-identity-providers.xml'
```

**Después**:
- Elimina el proveedor single-user
- Crea o actualiza el proveedor ldap-provider
- Configura todas las propiedades necesarias: Authentication Strategy, Manager DN, Manager Password, URL, User Search Base, User Search Filter, Identity Strategy, etc.
- Incluye soporte para TLS (LDAPS/START_TLS) con certificados

**Justificación**: Según la documentación de Docker, login-identity-providers.xml debe estar completamente configurado con todas las propiedades LDAP. El Helm chart original solo eliminaba el proveedor de usuario único pero no configuraba el proveedor LDAP.

#### Cambio 1.2: Limpieza de archivos de autorización en startup
**Líneas añadidas**: Después de configurar login-identity-providers.xml

```bash
# IMPORTANT: Remove existing authorization files on startup
echo "Cleaning existing authorization files for LDAP fresh start..."
rm -f "${PERSISTENT_CONF_DIR}/users.xml" "${PERSISTENT_CONF_DIR}/authorizations.xml"
```

**Justificación**: Según la documentación, es crítico eliminar users.xml y authorizations.xml al cambiar de autenticación básica a LDAP para evitar conflictos. Esto se menciona explícitamente en la sección "Solución de Problemas" del documento de Docker.

#### Cambio 1.3: Orden correcto del composite provider
**Líneas modificadas**: Configuración de composite-configurable-user-group-provider (~línea 319)

**Antes**:
```bash
xmlstarlet ed --inplace \
  --update "//userGroupProvider[identifier='composite-configurable-user-group-provider']/property[@name='User Group Provider 1']" \
  --value 'ldap-user-group-provider' \
  "${authorizers_file}"
```

**Después**:
```bash
xmlstarlet ed --inplace \
  --update "//userGroupProvider[identifier='composite-configurable-user-group-provider']/property[@name='User Group Provider 1']" \
  --value 'file-user-group-provider' \
  "${authorizers_file}"

xmlstarlet ed --inplace \
  --update "//userGroupProvider[identifier='composite-configurable-user-group-provider']/property[@name='User Group Provider 2']" \
  --value 'ldap-user-group-provider' \
  "${authorizers_file}"
```

**Justificación**: El orden debe ser file-user-group-provider primero para los certificados de nodos del cluster, y ldap-user-group-provider segundo para usuarios LDAP. Esto previene el error "Multiple UserGroupProviders are claiming to provide user" mencionado en la documentación.

#### Cambio 1.4: Uso de xmlstarlet para configurar User Group Provider
**Líneas modificadas**: Configuración de managed-authorizer

**Antes**:
```bash
sed -i -E "s|<property name=\"User Group Provider\">file-user-group-provider</property>|<property name=\"User Group Provider\">composite-configurable-user-group-provider</property>|g" "${authorizers_file}"
```

**Después**:
```bash
xmlstarlet ed --inplace \
  --update "//accessPolicyProvider[identifier='file-access-policy-provider']/property[@name='User Group Provider']" \
  --value 'composite-configurable-user-group-provider' \
  "${authorizers_file}"
```

**Justificación**: xmlstarlet es más preciso y confiable para editar XML que sed con expresiones regulares.

### 2. Archivo: `values.yaml`

#### Cambio 2.1: Actualización de comentarios y valores por defecto
**Líneas modificadas**: Sección global.ldap (~línea 49)

**Cambios**:
- Actualizado `authenticationStrategy` default a `SIMPLE` (estaba `LDAPS`)
- Actualizado `userSearchFilter` default a `uid={0}` (estaba `sAMAccountName={0}`)
- Actualizado `groupMembershipAttribute` default a `memberUid` (estaba `member`)
- Mejorados los comentarios para explicar mejor cada opción
- Añadida nota sobre que `initialAdminIdentity` debe ser el uid, no el DN completo cuando se usa `USE_USERNAME`

**Justificación**: Los valores por defecto originales asumían Active Directory. Los nuevos valores son apropiados para LDAP OpenLDAP estándar, que es el caso de uso documentado.

### 3. Nuevo Archivo: `examples/values-ldap-simple.yaml`

**Descripción**: Archivo de ejemplo completo para configuración LDAP simple (non-TLS)

**Contenido**:
- Configuración LDAP con `authenticationStrategy: SIMPLE`
- `identityStrategy: USE_USERNAME`
- Ejemplo de estructura LDAP compatible
- Configuración de persistent volumes necesarios

**Justificación**: Proporciona un punto de partida claro para usuarios que quieren configurar LDAP, basado en la configuración Docker documentada.

### 4. Nuevo Archivo: `docs/LDAP_CONFIGURATION.md`

**Descripción**: Guía completa de configuración LDAP para el Helm chart

**Contenido**:
- Explicación detallada de los puntos críticos de configuración
- Sección sobre Identity Strategy (el problema #1 más común)
- Guía paso a paso de configuración
- Ejemplos para LDAP simple, LDAPS y Active Directory
- Sección completa de troubleshooting
- Explicación de cómo funciona internamente
- Mejores prácticas de seguridad

**Justificación**: Proporciona documentación clara basada en los aprendizajes del setup de Docker, facilitando que los usuarios configuren LDAP correctamente sin caer en los errores comunes.

## Problemas Resueltos

### 1. Error: "Insufficient Permissions"
- **Causa**: Identity Strategy incorrecto o Initial Admin Identity no coincidía
- **Solución**: Configuración correcta de `identityStrategy: USE_USERNAME` y documentación clara

### 2. Error: "Multiple UserGroupProviders are claiming to provide user"
- **Causa**: Usuario existía en múltiples proveedores
- **Solución**: Orden correcto de composite provider y limpieza de archivos en startup

### 3. Error: "No applicable policies could be found"
- **Causa**: Archivos users.xml y authorizations.xml corruptos de configuración anterior
- **Solución**: Limpieza automática de archivos en startup con LDAP

### 4. Autenticación LDAP no funciona
- **Causa**: login-identity-providers.xml no estaba configurado
- **Solución**: Configuración completa automática del proveedor LDAP

## Configuración de Prueba Recomendada

Para validar los cambios:

1. Levantar servidor LDAP de prueba:
```bash
docker run -d --name ldap-test \
  -p 389:389 \
  -e LDAP_ORGANISATION="NiFi Org" \
  -e LDAP_DOMAIN="nifi.org" \
  -e LDAP_ADMIN_PASSWORD="admin" \
  osixia/openldap:latest
```

2. Crear estructura LDAP:
```bash
# Ver setup-ldap.sh en DOCUMENTACION_NIFI_LDAP.md
```

3. Desplegar NiFi con Helm:
```bash
helm install nifi . -f examples/values-ldap-simple.yaml
```

4. Acceder con usuario: `nifi-admin` / contraseña: `nifi-password`

## Referencias

- Documentación original de Docker: `DOCUMENTACION_NIFI_LDAP.md`
- Apache NiFi Admin Guide: https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html
- Especialmente secciones sobre LDAP y Authorizers

## Notas Adicionales

- Los cambios son **backward compatible**: si LDAP no está habilitado, el comportamiento es idéntico al anterior
- El clustering funciona correctamente con LDAP (a diferencia de basic auth)
- Se mantiene soporte para OIDC como prioridad máxima
- La limpieza de archivos solo ocurre cuando LDAP está habilitado, no afecta otros modos de autenticación
