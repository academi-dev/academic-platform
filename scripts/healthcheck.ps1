# ==============================================================================
# Academic Platform — Script de Verificación de Salud (PowerShell)
# Organización: academic-dev
# Equipo:
#   - Jean Mena (@hilton45)
#   - Eyfer Mena (@Eyfer3174)
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

function Write-Header { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[AVISO] $Message" -ForegroundColor Yellow }
function Write-Failure { param([string]$Message) Write-Host "[FALLÓ] $Message" -ForegroundColor Red }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlatformDir = Split-Path -Parent $ScriptDir
Set-Location $PlatformDir

# Cargar .env si existe
$envFile = Join-Path $PlatformDir ".env"
$apiPort = 8000
$ragPort = 8001
$gatewayPort = 80
$postgresUser = "academic_user"
$postgresDb = "academic_db"

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            if ($key -eq "API_PORT") { $apiPort = [int]$val }
            if ($key -eq "RAG_PORT") { $ragPort = [int]$val }
            if ($key -eq "GATEWAY_PORT") { $gatewayPort = [int]$val }
            if ($key -eq "POSTGRES_USER") { $postgresUser = $val }
            if ($key -eq "POSTGRES_DB") { $postgresDb = $val }
        }
    }
}

$total = 0
$passed = 0

Write-Header "ACADEMIC PLATFORM — REPORTE DE SALUD DE SERVICIOS"

# 1. Comprobar PostgreSQL
$total++
Write-Host -NoNewline "Verificando PostgreSQL 16 (pg_isready)... "
docker compose -f "$PlatformDir\docker-compose.yml" exec -T postgres pg_isready -U $postgresUser -d $postgresDb 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "Aceptando conexiones activas."
    $passed++
} else {
    Write-Failure "Base de datos no disponible o no lista."
}

# 2. Comprobar Academic API
$total++
Write-Host -NoNewline "Verificando academic-api (http://localhost:$apiPort/api/v1/health)... "
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest -Uri "http://localhost:$apiPort/api/v1/health" -Method Get -TimeoutSec 5 -UseBasicParsing
    $sw.Stop()
    if ($response.StatusCode -eq 200) {
        Write-Success "(HTTP 200, $($sw.ElapsedMilliseconds)ms)"
        $passed++
    } else {
        Write-Warn "Código HTTP $($response.StatusCode)"
    }
} catch {
    Write-Failure "No responde: $($_.Exception.Message)"
}

# 3. Comprobar Academic RAG
$total++
Write-Host -NoNewline "Verificando academic-rag (http://localhost:$ragPort/health)... "
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest -Uri "http://localhost:$ragPort/health" -Method Get -TimeoutSec 5 -UseBasicParsing
    $sw.Stop()
    if ($response.StatusCode -eq 200) {
        Write-Success "(HTTP 200, $($sw.ElapsedMilliseconds)ms)"
        $passed++
    } else {
        Write-Warn "Código HTTP $($response.StatusCode)"
    }
} catch {
    Write-Failure "No responde: $($_.Exception.Message)"
}

# 4. Comprobar Academic Bot
$total++
Write-Host -NoNewline "Verificando academic-bot (Contenedor Docker)... "
$botStatus = docker compose -f "$PlatformDir\docker-compose.yml" ps --format "{{.Status}}" academic-bot 2>$null
if ($botStatus -match "Up") {
    Write-Success "($botStatus)"
    $passed++
} else {
    Write-Failure "Contenedor inactivo o en error ($botStatus)"
}

# 5. Comprobar Gateway Nginx
$nginxRunning = docker compose -f "$PlatformDir\docker-compose.yml" ps --services --filter "status=running"
if ($nginxRunning -contains "nginx") {
    $total++
    Write-Host -NoNewline "Verificando Nginx Gateway (http://localhost:$gatewayPort/health)... "
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri "http://localhost:$gatewayPort/health" -Method Get -TimeoutSec 5 -UseBasicParsing
        $sw.Stop()
        if ($response.StatusCode -eq 200) {
            Write-Success "(HTTP 200, $($sw.ElapsedMilliseconds)ms)"
            $passed++
        } else {
            Write-Warn "Código HTTP $($response.StatusCode)"
        }
    } catch {
        Write-Failure "No responde: $($_.Exception.Message)"
    }
}

Write-Host "`n--------------------------------------------------------------------"
Write-Host "Resultado: $passed de $total comprobaciones exitosas."
if ($passed -eq $total) {
    Write-Host "[SALUD: 100%] Todos los servicios operando correctamente.`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Uno o más servicios requieren atención.`n" -ForegroundColor Yellow
    exit 1
}
