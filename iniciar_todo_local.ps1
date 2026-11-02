# ==============================================================================
# Academic — Lanzador Unificado Local (Sin necesidad de Docker ni PostgreSQL)
# ==============================================================================
# Levanta automáticamente:
#   1. academic-api en http://localhost:8000 (Swagger en http://localhost:8000/docs)
#   2. academic-rag en http://localhost:8001 (Swagger en http://localhost:8001/docs)
# Y opcionalmente inicia el conector de WhatsApp QR (http://localhost:3005).
# ==============================================================================

param(
    [switch]$ConWhatsApp,
    [switch]$EjecutarPrueba
)

$ErrorActionPreference = "Stop"
$RootGitHub = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$ApiDir = Join-Path $RootGitHub "proyecto 1\academic-api"
$BotDir = Join-Path $RootGitHub "proyecto 2\academic-bot"
$PlatDir = Join-Path $RootGitHub "proyecto 4\academic-platform"
$RagDir = Join-Path $RootGitHub "proyecto 5\academic-rag"

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " 🎓 INICIANDO ECOSISTEMA ACADEMIC EN MODO LOCAL UNIFICADO" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

# Configurar SQLite local si el usuario no definió DATABASE_URL de PostgreSQL
if (-not $env:DATABASE_URL) {
    $dbPath = (Join-Path $ApiDir "academic_local.db") -replace "\\", "/"
    $env:DATABASE_URL = "sqlite:///$dbPath"
}

Write-Host "[1/2] Levantando academic-api en http://localhost:8000 ..." -ForegroundColor Green
Start-Process -FilePath "$ApiDir\.venv\Scripts\python.exe" `
    -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000" `
    -WorkingDirectory $ApiDir

Write-Host "[2/2] Levantando academic-rag en http://localhost:8001 ..." -ForegroundColor Green
Start-Process -FilePath "$RagDir\.venv\Scripts\python.exe" `
    -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001" `
    -WorkingDirectory $RagDir

Start-Sleep -Seconds 3
Write-Host ""
Write-Host "✅ Servicios activos:" -ForegroundColor Green
Write-Host "   • API Principal (Swagger): http://localhost:8000/docs"
Write-Host "   • Servicio RAG (Swagger):  http://localhost:8001/docs"

if ($EjecutarPrueba) {
    Write-Host ""
    Write-Host "🧪 Ejecutando prueba de integración de punta a punta..." -ForegroundColor Yellow
    & "$ApiDir\.venv\Scripts\python.exe" "$PlatDir\scripts\prueba_integracion.py" --api http://127.0.0.1:8000 --rag http://127.0.0.1:8001
}

if ($ConWhatsApp) {
    Write-Host ""
    Write-Host "📱 Iniciando conector de WhatsApp por Código QR..." -ForegroundColor Cyan
    & "$BotDir\iniciar_whatsapp.ps1"
}
