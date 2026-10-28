#!/usr/bin/env bash
# ==============================================================================
# Script de Deploy Automático no Google Cloud Run
# Conexão Povos da Floresta — Cloud Controller (Archer BE220 / BE3600 Pro)
# ==============================================================================

set -euo pipefail

# Configurações padrão (substituíveis por variáveis de ambiente)
PROJECT_ID="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || echo "<GCP_PROJECT_ID>")}"
SERVICE_NAME="${SERVICE_NAME:-floresta-controller}"
REGION="${GCP_REGION:-southamerica-east1}"

echo "========================================================"
echo "   Deploy do Cloud Controller — Google Cloud Run        "
echo "========================================================"
echo " [>] Projeto GCP:     ${PROJECT_ID}"
echo " [>] Serviço:         ${SERVICE_NAME}"
echo " [>] Região:          ${REGION} (São Paulo)"
echo "========================================================"

# Verifica autenticação no gcloud
if ! gcloud auth print-access-token >/dev/null 2>&1; then
    echo "[!] Autenticação gcloud necessária. Por favor execute: gcloud auth login"
    exit 1
fi

# Define projeto ativo
gcloud config set project "${PROJECT_ID}" --quiet

# Garante que as APIs essenciais estejam habilitadas
echo "[*] Verificando e habilitando APIs necessárias no GCP..."
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="${PROJECT_ID}" --quiet

# Diretório da aplicação
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/cloudController"

if [ ! -d "${APP_DIR}" ]; then
    echo "[-] Diretório cloudController não encontrado em: ${APP_DIR}"
    exit 1
fi

echo "[*] Iniciando build e deploy no Google Cloud Run a partir de ${APP_DIR}..."
echo "    (Usando Cloud Build para compilar sem necessidade de Docker local)"

# Executa o deploy direto com build na nuvem
gcloud run deploy "${SERVICE_NAME}" \
    --source="${APP_DIR}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --platform=managed \
    --allow-unauthenticated \
    --port=8080 \
    --min-instances=1 \
    --max-instances=1 \
    --concurrency=500 \
    --no-cpu-throttling \
    --session-affinity \
    --timeout=3600 \
    --memory=512Mi \
    --cpu=1 \
    --quiet

# Obtém a URL do serviço implantado
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format='value(status.url)')

CONTROLLER_URL="${SERVICE_URL}/ws/router"

echo ""
echo "========================================================"
echo " [OK] DEPLOY CONCLUÍDO COM SUCESSO!"
echo "========================================================"
echo " 🌐 Dashboard Web (HTTPS):"
echo "    ${SERVICE_URL}"
echo ""
echo " 📡 Endpoint do Cloud Controller (HTTPS):"
echo "    ${CONTROLLER_URL}"
echo "========================================================"
echo ""
echo "Como apontar os roteadores para o novo Cloud Controller:"
echo "--------------------------------------------------------"
echo "No terminal do roteador (via serial ou SSH), execute:"
echo ""
echo "  set-inform ${CONTROLLER_URL}"
echo "  # ou via uci:"
echo "  uci set floresta_cloud.global.server_url=\"${CONTROLLER_URL}\""
echo "  uci commit floresta_cloud"
echo "  /etc/init.d/floresta_agent restart"
echo ""
echo "Em instantes o roteador aparecerá no Dashboard na nuvem!"
echo "========================================================"
