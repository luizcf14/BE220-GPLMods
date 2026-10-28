# ==============================================================================
# Script de Deploy Automático no Google Cloud Run (PowerShell)
# Conexão Povos da Floresta — Cloud Controller (Archer BE220 / BE3600 Pro)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ProjectId = "<GCP_PROJECT_ID>",
    [string]$ServiceName = "floresta-controller",
    [string]$Region = "southamerica-east1"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   Deploy do Cloud Controller - Google Cloud Run        " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " [>] Projeto GCP:     $ProjectId"
Write-Host " [>] Servico:         $ServiceName"
Write-Host " [>] Regiao:          $Region (Sao Paulo)"
Write-Host "========================================================"

$AppDir = Join-Path $PSScriptRoot "cloudController"
if (-not (Test-Path $AppDir)) {
    Write-Error "Diretório cloudController não encontrado em: $AppDir"
    exit 1
}

Write-Host "[*] Verificando e habilitando APIs necessárias no GCP..." -ForegroundColor Yellow
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com --project=$ProjectId --quiet

Write-Host "[*] Iniciando build e deploy no Google Cloud Run..." -ForegroundColor Yellow
Write-Host "    (Cloud Build compila o container na nuvem, sem exigir Docker local)" -ForegroundColor Gray

gcloud run deploy $ServiceName `
    --source=$AppDir `
    --project=$ProjectId `
    --region=$Region `
    --platform=managed `
    --allow-unauthenticated `
    --port=8080 `
    --min-instances=1 `
    --max-instances=1 `
    --concurrency=500 `
    --no-cpu-throttling `
    --session-affinity `
    --timeout=3600 `
    --memory=512Mi `
    --cpu=1 `
    --execution-environment=gen2 `
    '--add-volume=name=floresta-data,type=cloud-storage,bucket=<GCS_BUCKET>' `
    '--add-volume-mount=volume=floresta-data,mount-path=/app/data' `
    --quiet

$ServiceUrl = (gcloud run services describe $ServiceName --project=$ProjectId --region=$Region --format="value(status.url)").Trim()
$LatestRev = (gcloud run services describe $ServiceName --project=$ProjectId --region=$Region --format="value(status.latestReadyRevisionName)").Trim()
$ErrorActionPreference = "Continue"
$AllRevs = (gcloud run revisions list --service=$ServiceName --project=$ProjectId --region=$Region --format="value(metadata.name)") -split "`r?`n" | Where-Object { $_ -and $_ -ne $LatestRev }
foreach ($OldRev in $AllRevs) {
    Write-Host "[*] Encerrando revisao antiga ($OldRev) para migrar conexoes WebSocket imediatamente..." -ForegroundColor DarkGray
    gcloud run revisions delete $OldRev --project=$ProjectId --region=$Region --quiet *> $null
}
$ErrorActionPreference = "Stop"
$ControllerUrl = $ServiceUrl + "/ws/router"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host " [OK] DEPLOY CONCLUIDO COM SUCESSO!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host " Dashboard Web (HTTPS):" -ForegroundColor White
Write-Host "    $ServiceUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host " Endpoint do Cloud Controller (HTTPS):" -ForegroundColor White
Write-Host "    $ControllerUrl" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Como apontar os roteadores para o novo Cloud Controller:" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------" -ForegroundColor Gray
Write-Host "No terminal do roteador (via serial ou SSH), execute:"
Write-Host ""
Write-Host "  set-inform $ControllerUrl" -ForegroundColor Green
Write-Host "  # ou via uci:" -ForegroundColor Gray
Write-Host "  uci set floresta_cloud.global.server_url=`"$ControllerUrl`"" -ForegroundColor Green
Write-Host "  uci commit floresta_cloud" -ForegroundColor Green
Write-Host "  /etc/init.d/floresta_agent restart" -ForegroundColor Green
Write-Host ""
Write-Host "Em instantes o roteador aparecerá no Dashboard na nuvem!" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Green
