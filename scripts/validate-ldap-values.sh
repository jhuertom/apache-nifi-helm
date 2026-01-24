#!/bin/bash

# Script de validación de configuración LDAP para NiFi Helm Chart (pre-deployment)
# Valida el archivo values.yaml antes de desplegar

set -e

echo "=== Validación de Configuración LDAP para NiFi (Pre-Deployment) ==="
echo ""

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para mostrar resultados
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Verificar que existe un archivo de valores
if [ -z "$1" ]; then
    echo "Uso: $0 <archivo-values.yaml>"
    echo "Ejemplo: $0 examples/values-ldap-simple.yaml"
    exit 1
fi

VALUES_FILE="$1"

if [ ! -f "$VALUES_FILE" ]; then
    check_fail "Archivo de valores no encontrado: $VALUES_FILE"
    exit 1
fi

check_pass "Archivo de valores encontrado: $VALUES_FILE"
echo ""

# Extraer valores de configuración LDAP usando yq o grep
echo "=== Verificando Configuración LDAP ==="
echo ""

# Verificar si LDAP está habilitado
LDAP_ENABLED=$(grep -A 1 "ldap:" "$VALUES_FILE" | grep "enabled:" | awk '{print $2}' | tr -d ' ')
if [ "$LDAP_ENABLED" = "true" ]; then
    check_pass "LDAP habilitado"
else
    check_fail "LDAP no está habilitado (ldap.enabled: false)"
    exit 1
fi

# Verificar URL de LDAP
LDAP_URL=$(grep "url:" "$VALUES_FILE" | head -1 | sed 's/.*url: *"\(.*\)".*/\1/' | sed 's/.*url: *\(.*\)/\1/' | tr -d '"')
if [ -n "$LDAP_URL" ] && [ "$LDAP_URL" != '""' ]; then
    check_pass "LDAP URL configurado: $LDAP_URL"
else
    check_fail "LDAP URL no configurado"
fi

# Verificar Authentication Strategy
AUTH_STRATEGY=$(grep "authenticationStrategy:" "$VALUES_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
if [ -n "$AUTH_STRATEGY" ]; then
    check_pass "Authentication Strategy: $AUTH_STRATEGY"
    if [ "$AUTH_STRATEGY" = "SIMPLE" ] && [[ "$LDAP_URL" == ldaps://* ]]; then
        check_warn "Usando SIMPLE con LDAPS URL - considera usar authenticationStrategy: LDAPS"
    fi
    if [ "$AUTH_STRATEGY" = "LDAPS" ] && [[ "$LDAP_URL" == ldap://* ]]; then
        check_warn "Usando LDAPS con ldap:// URL - asegúrate que el puerto sea 636"
    fi
else
    check_fail "Authentication Strategy no configurado"
fi

# Verificar Identity Strategy - CRÍTICO
IDENTITY_STRATEGY=$(grep "identityStrategy:" "$VALUES_FILE" | head -1 | awk '{print $2}' | tr -d ' ')
if [ "$IDENTITY_STRATEGY" = "USE_USERNAME" ]; then
    check_pass "Identity Strategy: USE_USERNAME (RECOMENDADO)"
elif [ "$IDENTITY_STRATEGY" = "USE_DN" ]; then
    check_warn "Identity Strategy: USE_DN - Asegúrate que initialAdminIdentity sea el DN completo"
else
    check_fail "Identity Strategy no configurado o inválido"
fi

# Verificar Initial Admin Identity
INITIAL_ADMIN=$(grep "initialAdminIdentity:" "$VALUES_FILE" | head -1 | sed 's/.*initialAdminIdentity: *"\(.*\)".*/\1/' | sed 's/.*initialAdminIdentity: *\(.*\)/\1/' | tr -d '"')
if [ -n "$INITIAL_ADMIN" ] && [ "$INITIAL_ADMIN" != '""' ]; then
    check_pass "Initial Admin Identity: $INITIAL_ADMIN"
    
    # Verificar consistencia con Identity Strategy
    if [ "$IDENTITY_STRATEGY" = "USE_USERNAME" ]; then
        if [[ "$INITIAL_ADMIN" == *"="* ]]; then
            check_warn "Identity Strategy es USE_USERNAME pero Initial Admin Identity parece un DN: $INITIAL_ADMIN"
            echo "         Debería ser solo el username (ej: nifi-admin)"
        fi
    fi
    if [ "$IDENTITY_STRATEGY" = "USE_DN" ]; then
        if [[ "$INITIAL_ADMIN" != *"="* ]]; then
            check_warn "Identity Strategy es USE_DN pero Initial Admin Identity parece un username: $INITIAL_ADMIN"
            echo "         Debería ser el DN completo (ej: uid=nifi-admin,ou=users,dc=nifi,dc=org)"
        fi
    fi
else
    check_fail "Initial Admin Identity no configurado"
fi

# Verificar Manager DN
MANAGER_DN=$(grep "distinguishedName:" "$VALUES_FILE" | head -1 | sed 's/.*distinguishedName: *"\(.*\)".*/\1/' | sed 's/.*distinguishedName: *\(.*\)/\1/' | tr -d '"')
if [ -n "$MANAGER_DN" ] && [ "$MANAGER_DN" != '""' ]; then
    check_pass "Manager DN configurado: $MANAGER_DN"
else
    check_fail "Manager DN no configurado"
fi

# Verificar Manager Password o Secret
MANAGER_PASSWORD=$(grep -A 2 "manager:" "$VALUES_FILE" | grep "password:" | head -1 | awk '{print $2}' | tr -d '"')
if [ -n "$MANAGER_PASSWORD" ] && [ "$MANAGER_PASSWORD" != '""' ]; then
    check_pass "Manager Password configurado (valor presente)"
    check_warn "Password en plain text - considera usar passwordSecretRef en producción"
else
    # Verificar si usa secretRef
    SECRET_REF=$(grep -A 4 "manager:" "$VALUES_FILE" | grep "name:" | head -1 | awk '{print $2}' | tr -d '"')
    if [ -n "$SECRET_REF" ] && [ "$SECRET_REF" != '""' ]; then
        check_pass "Manager Password usando secretRef: $SECRET_REF"
    else
        check_fail "Manager Password no configurado"
    fi
fi

# Verificar User Search Base
USER_SEARCH_BASE=$(grep "userSearchBase:" "$VALUES_FILE" | head -1 | sed 's/.*userSearchBase: *"\(.*\)".*/\1/' | sed 's/.*userSearchBase: *\(.*\)/\1/' | tr -d '"')
if [ -n "$USER_SEARCH_BASE" ] && [ "$USER_SEARCH_BASE" != '""' ]; then
    check_pass "User Search Base: $USER_SEARCH_BASE"
else
    check_fail "User Search Base no configurado"
fi

# Verificar User Search Filter
USER_SEARCH_FILTER=$(grep "userSearchFilter:" "$VALUES_FILE" | head -1 | sed 's/.*userSearchFilter: *\(.*\)/\1/')
if [ -n "$USER_SEARCH_FILTER" ]; then
    check_pass "User Search Filter: $USER_SEARCH_FILTER"
else
    check_fail "User Search Filter no configurado"
fi

# Verificar configuración de grupos (opcional)
GROUP_SEARCH_BASE=$(grep "groupSearchBase:" "$VALUES_FILE" | head -1 | sed 's/.*groupSearchBase: *"\(.*\)".*/\1/' | sed 's/.*groupSearchBase: *\(.*\)/\1/' | tr -d '"')
if [ -n "$GROUP_SEARCH_BASE" ] && [ "$GROUP_SEARCH_BASE" != '""' ]; then
    check_pass "Group Search Base configurado: $GROUP_SEARCH_BASE (sincronización de grupos habilitada)"
else
    echo "  Group Search Base no configurado (sincronización de grupos deshabilitada)"
fi

echo ""
echo "=== Verificando Configuración de Cluster ==="
echo ""

# Verificar node count
NODE_COUNT=$(grep "nodeCount:" "$VALUES_FILE" | head -1 | awk '{print $2}')
if [ -n "$NODE_COUNT" ]; then
    check_pass "Node Count: $NODE_COUNT"
    if [ "$NODE_COUNT" -eq 1 ]; then
        check_warn "Cluster de un solo nodo - considera usar múltiples nodos para alta disponibilidad"
    fi
else
    echo "  Node Count no especificado (se usará valor por defecto)"
fi

echo ""
echo "=== Resumen de Validación ==="
echo ""

# Verificar que los elementos críticos estén presentes
CRITICAL_CHECKS=0

if [ "$LDAP_ENABLED" != "true" ]; then
    ((CRITICAL_CHECKS++))
fi

if [ -z "$LDAP_URL" ] || [ "$LDAP_URL" = '""' ]; then
    ((CRITICAL_CHECKS++))
fi

if [ "$IDENTITY_STRATEGY" != "USE_USERNAME" ] && [ "$IDENTITY_STRATEGY" != "USE_DN" ]; then
    ((CRITICAL_CHECKS++))
fi

if [ -z "$INITIAL_ADMIN" ] || [ "$INITIAL_ADMIN" = '""' ]; then
    ((CRITICAL_CHECKS++))
fi

if [ -z "$MANAGER_DN" ] || [ "$MANAGER_DN" = '""' ]; then
    ((CRITICAL_CHECKS++))
fi

if [ -z "$USER_SEARCH_BASE" ] || [ "$USER_SEARCH_BASE" = '""' ]; then
    ((CRITICAL_CHECKS++))
fi

if [ $CRITICAL_CHECKS -eq 0 ]; then
    check_pass "Configuración LDAP parece válida"
    echo ""
    echo "Puedes desplegar con:"
    echo "  helm install nifi . -f $VALUES_FILE"
    echo ""
    echo "O actualizar un despliegue existente con:"
    echo "  helm upgrade nifi . -f $VALUES_FILE"
    exit 0
else
    check_fail "Se encontraron $CRITICAL_CHECKS errores críticos en la configuración"
    echo ""
    echo "Por favor, corrige los errores antes de desplegar."
    echo "Consulta docs/LDAP_CONFIGURATION.md para más información."
    exit 1
fi
