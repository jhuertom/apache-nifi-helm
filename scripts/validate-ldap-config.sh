#!/bin/bash
# Script para validar la configuración LDAP de NiFi

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para imprimir mensajes
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Variables (ajusta según tu instalación)
NAMESPACE="${NAMESPACE:-nifi}"
RELEASE_NAME="${RELEASE_NAME:-nifi}"
POD_NAME="${RELEASE_NAME}-0"

print_info "Validando configuración LDAP de NiFi..."
echo ""

# 1. Verificar que el pod está corriendo
print_info "1. Verificando estado del pod..."
if kubectl get pod -n "$NAMESPACE" "$POD_NAME" &> /dev/null; then
    POD_STATUS=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.status.phase}')
    if [ "$POD_STATUS" == "Running" ]; then
        print_info "   ✓ Pod $POD_NAME está en estado Running"
    else
        print_error "   ✗ Pod $POD_NAME está en estado: $POD_STATUS"
        exit 1
    fi
else
    print_error "   ✗ Pod $POD_NAME no encontrado en namespace $NAMESPACE"
    exit 1
fi
echo ""

# 2. Verificar variables de entorno LDAP
print_info "2. Verificando variables de entorno LDAP..."
LDAP_VARS=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- env | grep -E "LDAP_|AUTH=" || true)
if [ -n "$LDAP_VARS" ]; then
    print_info "   ✓ Variables LDAP configuradas:"
    echo "$LDAP_VARS" | while read line; do
        # Ocultar contraseñas
        if [[ $line == *"PASSWORD"* ]]; then
            echo "      $(echo $line | cut -d'=' -f1)=********"
        else
            echo "      $line"
        fi
    done
else
    print_warning "   ⚠ No se encontraron variables LDAP"
fi
echo ""

# 3. Verificar el secret del LDAP manager
print_info "3. Verificando secret del LDAP manager..."
SECRET_NAME=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.spec.containers[0].env[?(@.name=="LDAP_MANAGER_PASSWORD")].valueFrom.secretKeyRef.name}' || true)
if [ -n "$SECRET_NAME" ]; then
    if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &> /dev/null; then
        print_info "   ✓ Secret $SECRET_NAME existe"
    else
        print_error "   ✗ Secret $SECRET_NAME no encontrado"
    fi
else
    print_warning "   ⚠ No se encontró referencia a secret de LDAP manager"
fi
echo ""

# 4. Verificar conectividad LDAP
print_info "4. Verificando conectividad con servidor LDAP..."
LDAP_URL=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- env | grep "LDAP_URL=" | cut -d'=' -f2- || true)
if [ -n "$LDAP_URL" ]; then
    # Extraer host y puerto del URL
    LDAP_HOST=$(echo "$LDAP_URL" | sed -E 's|^ldaps?://([^:,]+).*|\1|')
    LDAP_PORT=$(echo "$LDAP_URL" | sed -E 's|^ldaps?://[^:]+:([0-9]+).*|\1|')
    
    print_info "   Testeando conexión a $LDAP_HOST:$LDAP_PORT..."
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "nc -zv -w 5 $LDAP_HOST $LDAP_PORT" &> /dev/null; then
        print_info "   ✓ Conexión exitosa a $LDAP_HOST:$LDAP_PORT"
    else
        print_error "   ✗ No se pudo conectar a $LDAP_HOST:$LDAP_PORT"
    fi
else
    print_warning "   ⚠ LDAP_URL no configurada"
fi
echo ""

# 5. Verificar archivos de configuración
print_info "5. Verificando archivos de configuración..."

# Verificar login-identity-providers.xml
print_info "   Verificando login-identity-providers.xml..."
LDAP_PROVIDER=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- grep -A 5 "ldap-identity-provider" /opt/nifi/nifi-current/conf/login-identity-providers.xml | grep "<class>" || true)
if [ -n "$LDAP_PROVIDER" ]; then
    print_info "   ✓ LDAP identity provider configurado"
else
    print_warning "   ⚠ LDAP identity provider no encontrado en login-identity-providers.xml"
fi

# Verificar authorizers.xml
print_info "   Verificando authorizers.xml..."
LDAP_AUTHORIZER=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- grep -A 3 "ldap-user-group-provider" /opt/nifi/nifi-current/conf/authorizers.xml | grep "<class>" || true)
if [ -n "$LDAP_AUTHORIZER" ]; then
    print_info "   ✓ LDAP user group provider configurado en authorizers.xml"
else
    print_warning "   ⚠ LDAP user group provider no encontrado en authorizers.xml"
fi
echo ""

# 6. Verificar logs de NiFi
print_info "6. Verificando logs de NiFi para errores LDAP..."
LDAP_ERRORS=$(kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=500 | grep -i "ldap" | grep -iE "error|exception|failed" || true)
if [ -n "$LDAP_ERRORS" ]; then
    print_error "   ✗ Errores LDAP encontrados en logs:"
    echo "$LDAP_ERRORS" | tail -5
else
    print_info "   ✓ No se encontraron errores LDAP en logs recientes"
fi
echo ""

# 7. Verificar configuración de authorizers
print_info "7. Mostrando configuración de authorizers.xml..."
print_info "   User Group Provider configurado:"
USER_GROUP_PROVIDER=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- xmlstarlet sel -t -v "//authorizer[@id='managed-authorizer']/property[@name='User Group Provider']" /opt/nifi/nifi-current/conf/authorizers.xml 2>/dev/null || echo "No disponible")
echo "      User Group Provider: $USER_GROUP_PROVIDER"
echo ""

# 8. Resumen
print_info "=========================================="
print_info "RESUMEN DE VALIDACIÓN"
print_info "=========================================="

if [ -n "$LDAP_VARS" ] && [ -n "$SECRET_NAME" ] && [ -n "$LDAP_PROVIDER" ] && [ -n "$LDAP_AUTHORIZER" ]; then
    print_info "✓ Configuración LDAP parece estar correcta"
    echo ""
    print_info "Próximos pasos:"
    echo "   1. Intenta acceder a la interfaz web de NiFi"
    echo "   2. Usa credenciales LDAP para autenticarte"
    echo "   3. Verifica que el usuario inicial admin tiene permisos completos"
else
    print_warning "⚠ Algunas validaciones fallaron. Revisa los mensajes anteriores."
fi
echo ""
