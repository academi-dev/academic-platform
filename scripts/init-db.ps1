# ==============================================================================
# Academic Platform — Script de Inicialización de Base de Datos (PowerShell)
# Organización: academic-dev
# Equipo:
#   - Jean Mena (@hilton45)
#   - Eyfer Mena (@Eyfer3174)
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[AVISO] $Message" -ForegroundColor Yellow }
function Write-Failure { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlatformDir = Split-Path -Parent $ScriptDir
Set-Location $PlatformDir

Write-Info "Directorio de trabajo: $PlatformDir"

# Cargar .env si existe
$envFile = Join-Path $PlatformDir ".env"
$postgresUser = "academic_user"
$postgresDb = "academic_db"

if (Test-Path $envFile) {
    Write-Info "Cargando variables desde .env..."
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            [Environment]::SetEnvironmentVariable($key, $val, "Process")
            if ($key -eq "POSTGRES_USER") { $postgresUser = $val }
            if ($key -eq "POSTGRES_DB") { $postgresDb = $val }
        }
    }
} else {
    Write-Warn "No se encontró archivo .env. Usando valores predeterminados."
}

# Verificar Docker
try {
    $composeCmd = "docker compose"
    docker compose version | Out-Null
} catch {
    Write-Failure "No se encontró 'docker compose'. Por favor verifica que Docker Desktop esté instalado y corriendo."
    exit 1
}

Write-Info "Comprobando contenedor de PostgreSQL..."
$running = docker compose ps --services --filter "status=running"
if ($running -notcontains "postgres") {
    Write-Warn "Iniciando servicio postgres..."
    docker compose up -d postgres
}

# Esperar disponibilidad
$maxRetries = 30
$retryInterval = 2
$ready = $false

Write-Info "Esperando a que PostgreSQL esté listo (DB: '$postgresDb', User: '$postgresUser')..."
for ($i = 0; $i -lt $maxRetries; $i++) {
    docker compose exec -T postgres pg_isready -U $postgresUser -d $postgresDb 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        break
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds $retryInterval
}
Write-Host ""

if (-not $ready) {
    Write-Failure "Tiempo de espera agotado. PostgreSQL no respondió."
    exit 1
}

Write-Success "¡PostgreSQL está listo y aceptando conexiones!"

# Asegurar que academic-api esté arriba
$running = docker compose ps --services --filter "status=running"
if ($running -notcontains "academic-api") {
    Write-Info "Iniciando servicio academic-api..."
    docker compose up -d academic-api
}

Write-Info "Ejecutando migraciones de Alembic en academic-api..."
docker compose exec -T academic-api alembic upgrade head

if ($LASTEXITCODE -eq 0) {
    Write-Success "Migraciones de Alembic aplicadas correctamente a la versión HEAD."
} else {
    Write-Failure "Ocurrió un error al ejecutar las migraciones de Alembic."
    exit 1
}

Write-Success "=== Inicialización de base de datos completada con éxito ==="
