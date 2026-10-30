#!/usr/bin/env bash
# ==============================================================================
# Academic Platform — Script de Inicialización de Base de Datos y Migraciones
# Organización: academic-dev
# Equipo:
#   - Jean Mena (@hilton45)
#   - Eyfer Mena (@Eyfer3174)
# ==============================================================================
# Este script:
#   1. Verifica la existencia de Docker y Docker Compose
#   2. Carga las variables de entorno desde .env si existe
#   3. Espera a que el contenedor de PostgreSQL esté saludable y listo para recibir conexiones
#   4. Ejecuta las migraciones de Alembic dentro del contenedor de academic-api
# ==============================================================================

set -euo pipefail

# Colores para salida en terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Obtener directorio del script y raíz de academic-platform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PLATFORM_DIR}"

log_info "Directorio de trabajo: ${PLATFORM_DIR}"

# Cargar variables de entorno si existe el archivo .env
if [ -f "${PLATFORM_DIR}/.env" ]; then
    log_info "Cargando variables desde .env..."
    # Exportar variables sin sobrescribir las que ya existan en la sesión
    set -a
    # shellcheck disable=SC1091
    source "${PLATFORM_DIR}/.env"
    set +a
else
    log_warn "No se encontró archivo .env. Usando valores predeterminados de docker-compose.yml."
fi

POSTGRES_USER="${POSTGRES_USER:-academic_user}"
POSTGRES_DB="${POSTGRES_DB:-academic_db}"

# Detectar comando docker compose
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    log_error "No se encontró 'docker compose' ni 'docker-compose'. Por favor instala Docker."
    exit 1
fi

log_info "Comando detectado: ${DOCKER_COMPOSE}"

# Verificar que los contenedores estén en ejecución
log_info "Comprobando estado del contenedor de PostgreSQL..."
if ! ${DOCKER_COMPOSE} ps --services --filter "status=running" | grep -q "^postgres$"; then
    log_warn "El contenedor 'postgres' no está corriendo. Iniciando dependencias..."
    ${DOCKER_COMPOSE} up -d postgres
fi

# Esperar a que PostgreSQL esté listo usando pg_isready
MAX_RETRIES=30
RETRY_INTERVAL=2
COUNT=0

log_info "Esperando a que PostgreSQL esté listo (Base de datos: '${POSTGRES_DB}', Usuario: '${POSTGRES_USER}')..."

until ${DOCKER_COMPOSE} exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; do
    COUNT=$((COUNT + 1))
    if [ "${COUNT}" -ge "${MAX_RETRIES}" ]; then
        log_error "Tiempo de espera agotado. PostgreSQL no respondió tras $((MAX_RETRIES * RETRY_INTERVAL)) segundos."
        exit 1
    fi
    echo -n "."
    sleep "${RETRY_INTERVAL}"
done
echo ""

log_success "¡PostgreSQL está listo y aceptando conexiones!"

# Iniciar academic-api si no está corriendo
if ! ${DOCKER_COMPOSE} ps --services --filter "status=running" | grep -q "^academic-api$"; then
    log_info "Iniciando contenedor academic-api..."
    ${DOCKER_COMPOSE} up -d academic-api
fi

# Ejecutar migraciones de Alembic
log_info "Ejecutando migraciones de base de datos con Alembic en academic-api..."
if ${DOCKER_COMPOSE} exec -T academic-api alembic upgrade head; then
    log_success "Migraciones de Alembic aplicadas correctamente a la versión HEAD."
else
    log_error "Falló la ejecución de las migraciones de Alembic."
    log_info "Para ver logs detallados ejecuta: ${DOCKER_COMPOSE} logs academic-api"
    exit 1
fi

log_success "=== Inicialización de base de datos completada con éxito ==="
