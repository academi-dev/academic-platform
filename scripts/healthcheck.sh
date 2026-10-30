#!/usr/bin/env bash
# ==============================================================================
# Academic Platform — Script de Verificación de Salud (Healthcheck)
# Organización: academic-dev
# Equipo:
#   - Jean Mena (@hilton45)
#   - Eyfer Mena (@Eyfer3174)
# ==============================================================================
# Este script verifica el estado y tiempo de respuesta de cada servicio:
#   1. Gateway Nginx (Reverse Proxy) -> http://localhost:${GATEWAY_PORT}/health
#   2. Academic API (FastAPI)        -> http://localhost:${API_PORT}/api/v1/health
#   3. Academic RAG (FastAPI + AI)   -> http://localhost:${RAG_PORT}/health
#   4. PostgreSQL 16                 -> pg_isready dentro del contenedor
#   5. Academic Bot (Telegram)       -> Estado del contenedor en Docker
# ==============================================================================

set -euo pipefail

# Colores de salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Directorios
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Cargar variables de entorno si existen
if [ -f "${PLATFORM_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${PLATFORM_DIR}/.env"
    set +a
fi

GATEWAY_PORT="${GATEWAY_PORT:-80}"
API_PORT="${API_PORT:-8000}"
RAG_PORT="${RAG_PORT:-8001}"
POSTGRES_USER="${POSTGRES_USER:-academic_user}"
POSTGRES_DB="${POSTGRES_DB:-academic_db}"

# Comando Docker Compose
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

TOTAL_CHECKS=0
PASSED_CHECKS=0

echo -e "\n${BOLD}${CYAN}====================================================================${NC}"
echo -e "${BOLD}${CYAN}   ACADEMIC PLATFORM — REPORTE DE SALUD DE SERVICIOS                ${NC}"
echo -e "${BOLD}${CYAN}====================================================================${NC}\n"

check_http_service() {
    local name="$1"
    local url="$2"
    local expected_status="${3:-200}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -n -e "Verificando ${BOLD}${name}${NC} (${url})... "

    start_time=$(date +%s%N 2>/dev/null || date +%s)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")
    end_time=$(date +%s%N 2>/dev/null || date +%s)

    # Calcular latencia aproximada en ms si date +%s%N está disponible
    if [ "${#start_time}" -gt 10 ]; then
        latency=$(( (end_time - start_time) / 1000000 ))
        latency_str="${latency}ms"
    else
        latency_str="<1s"
    fi

    if [ "${http_code}" -eq "${expected_status}" ] || [ "${http_code}" -eq 200 ]; then
        echo -e "${GREEN}[OK]${NC} (HTTP ${http_code}, ${latency_str})"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    elif [ "${http_code}" -eq "000" ]; then
        echo -e "${RED}[FALLÓ]${NC} No se pudo conectar al endpoint."
        return 1
    else
        echo -e "${YELLOW}[ALERTA]${NC} Código inesperado: ${http_code} (esperado: ${expected_status})"
        return 1
    fi
}

check_postgres() {
    local name="PostgreSQL 16"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -n -e "Verificando ${BOLD}${name}${NC} (pg_isready)... "

    if ${DOCKER_COMPOSE} -f "${PLATFORM_DIR}/docker-compose.yml" exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} Aceptando conexiones."
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "${RED}[FALLÓ]${NC} Base de datos no disponible o no lista."
        return 1
    fi
}

check_container_status() {
    local service_name="$1"
    local display_name="$2"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -n -e "Verificando estado de contenedor ${BOLD}${display_name}${NC}... "

    container_status=$(${DOCKER_COMPOSE} -f "${PLATFORM_DIR}/docker-compose.yml" ps --format "{{.Status}}" "${service_name}" 2>/dev/null || echo "no existe")

    if echo "${container_status}" | grep -q "Up"; then
        echo -e "${GREEN}[OK]${NC} (${container_status})"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "${RED}[FALLÓ]${NC} Contenedor inactivo o detenido (${container_status})"
        return 1
    fi
}

# 1. Comprobar PostgreSQL
check_postgres || true

# 2. Comprobar Academic API (directo y a través de endpoint /api/v1/health)
check_http_service "academic-api" "http://localhost:${API_PORT}/api/v1/health" 200 || true

# 3. Comprobar Academic RAG
check_http_service "academic-rag" "http://localhost:${RAG_PORT}/health" 200 || true

# 4. Comprobar Academic Bot (por estado de contenedor, ya que es un long-polling worker)
check_container_status "academic-bot" "academic-bot (Telegram)" || true

# 5. Comprobar Gateway Nginx (si está activo)
if ${DOCKER_COMPOSE} -f "${PLATFORM_DIR}/docker-compose.yml" ps --services --filter "status=running" | grep -q "^nginx$"; then
    check_http_service "Nginx Gateway" "http://localhost:${GATEWAY_PORT}/health" 200 || true
fi

echo -e "\n--------------------------------------------------------------------"
echo -e "Resultado: ${PASSED_CHECKS} de ${TOTAL_CHECKS} verificaciones exitosas."

if [ "${PASSED_CHECKS}" -eq "${TOTAL_CHECKS}" ]; then
    echo -e "${GREEN}${BOLD}¡Todos los servicios están operando correctamente! [SALUD: 100%]${NC}\n"
    exit 0
else
    echo -e "${YELLOW}${BOLD}Advertencia: Uno o más servicios presentan inconvenientes.${NC}\n"
    exit 1
fi
