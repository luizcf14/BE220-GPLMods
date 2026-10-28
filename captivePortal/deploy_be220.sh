#!/bin/bash
# deploy_be220.sh — Instala o Portal Captivo 3000 no Archer BE220
#
# Uso: bash deploy_be220.sh [IP_DO_ROTEADOR]
# Padrão: 192.168.0.1

ROUTER="${1:-192.168.0.1}"
ROUTER_USER="root"
ROUTER_PASS="<ROOT_PASSWORD>"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_DIR="$SCRIPT_DIR/be220_port/openwrt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

# Executa comando remoto via SSH com senha (garantindo PATH padrão do BusyBox/OpenWrt)
ssh_cmd() {
    sshpass -p "$ROUTER_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=8 \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "$ROUTER_USER@$ROUTER" "export PATH=/sbin:/bin:/usr/sbin:/usr/bin:\$PATH; $*"
}

# Envia arquivo via SCP (usando -O para protocolo scp legado com dropbear)
scp_file() {
    sshpass -p "$ROUTER_PASS" scp -O \
        -o StrictHostKeyChecking=no \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "$1" "$ROUTER_USER@$ROUTER:$2"
}

# Envia diretório recursivo
scp_dir() {
    sshpass -p "$ROUTER_PASS" scp -O -r \
        -o StrictHostKeyChecking=no \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "$1" "$ROUTER_USER@$ROUTER:$2"
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Portal Captivo 3000 — Deploy Archer BE220       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Verifica dependência sshpass
command -v sshpass >/dev/null 2>&1 || { err "sshpass não encontrado. Instale com: sudo apt install -y sshpass"; exit 1; }

echo "Destino: root@${ROUTER}"
echo "Fonte:   ${PORT_DIR}"
echo ""

# Testa conectividade SSH
echo "─── 1. Testando conexão SSH..."
if ! ssh_cmd "echo ok" >/dev/null 2>&1; then
    err "Não foi possível conectar em $ROUTER. Verifique IP e cabo de rede."
    exit 1
fi
ok "Conectado ao roteador com sucesso!"

# Para serviço se já estiver rodando
echo ""
echo "─── 2. Parando serviço existente (se houver)..."
ssh_cmd "/etc/init.d/captiveportal stop 2>/dev/null || true"
ok "Limpeza inicial efetuada"

# Cria diretórios e prepara overlays de gravação no roteador
echo ""
echo "─── 3. Preparando diretórios e pontos de montagem no roteador..."
ssh_cmd "
mkdir -p /etc/captiveportal /etc/config /usr/bin /tmp/dnsmasq.d /tmp/cgi-bin /tmp/www_captive/admin
if ! grep -q '/www/cgi-bin' /proc/mounts; then
    cp -af /www/cgi-bin/* /tmp/cgi-bin/ 2>/dev/null || true
    mount --bind /tmp/cgi-bin /www/cgi-bin 2>/dev/null || true
fi
if ! grep -q '/www/captive' /proc/mounts; then
    cp -af /www/captive/* /tmp/www_captive/ 2>/dev/null || true
    mount --bind /tmp/www_captive /www/captive 2>/dev/null || true
fi
"
ok "Diretórios e pontos de montagem prontos"

# Envia arquivos
echo ""
echo "─── 4. Enviando arquivos portados para o roteador..."

# Script init.d
scp_file "$PORT_DIR/etc/init.d/captiveportal" "/etc/init.d/captiveportal" && \
    ssh_cmd "chmod 755 /etc/init.d/captiveportal" && \
    ok "etc/init.d/captiveportal (755)"

# CLI portal_ctl
if scp_file "$PORT_DIR/usr/bin/portal_ctl" "/usr/bin/portal_ctl" 2>/dev/null; then
    ssh_cmd "chmod 755 /usr/bin/portal_ctl"
    ok "usr/bin/portal_ctl (755)"
else
    ok "usr/bin/portal_ctl (já instalado no sistema)"
fi

# Scripts auxiliares
scp_file "$PORT_DIR/etc/captiveportal/captive_redirector.lua" "/etc/captiveportal/captive_redirector.lua" && \
    ssh_cmd "chmod 755 /etc/captiveportal/captive_redirector.lua" && \
    ok "etc/captiveportal/captive_redirector.lua (755)"

scp_file "$PORT_DIR/etc/captiveportal/refresh-whitelist.sh" "/etc/captiveportal/refresh-whitelist.sh" && \
    ssh_cmd "chmod 755 /etc/captiveportal/refresh-whitelist.sh" && \
    ok "etc/captiveportal/refresh-whitelist.sh (755)"

scp_file "$PORT_DIR/etc/captiveportal/renew-sessions.sh" "/etc/captiveportal/renew-sessions.sh" && \
    ssh_cmd "chmod 755 /etc/captiveportal/renew-sessions.sh" && \
    ok "etc/captiveportal/renew-sessions.sh (755)"

# CGI Scripts
scp_file "$PORT_DIR/www/cgi-bin/portal_auth" "/www/cgi-bin/portal_auth" && \
    ssh_cmd "chmod 755 /www/cgi-bin/portal_auth" && \
    ok "www/cgi-bin/portal_auth (755)"

scp_file "$PORT_DIR/www/cgi-bin/portal_redirect" "/www/cgi-bin/portal_redirect" && \
    ssh_cmd "chmod 755 /www/cgi-bin/portal_redirect" && \
    ok "www/cgi-bin/portal_redirect (755)"

scp_file "$PORT_DIR/www/cgi-bin/captive_portal_api" "/www/cgi-bin/captive_portal_api" && \
    ssh_cmd "chmod 755 /www/cgi-bin/captive_portal_api" && \
    ok "www/cgi-bin/captive_portal_api (755)"

scp_file "$PORT_DIR/www/cgi-bin/captive_admin_api" "/www/cgi-bin/captive_admin_api" && \
    ssh_cmd "chmod 755 /www/cgi-bin/captive_admin_api" && \
    ok "www/cgi-bin/captive_admin_api (755)"

# Frontend e Admin Dashboard
scp_file "$PORT_DIR/www/captive/index.html" "/www/captive/index.html" && ok "www/captive/index.html"
scp_file "$PORT_DIR/www/captive/app.js" "/www/captive/app.js" && ok "www/captive/app.js"
scp_file "$PORT_DIR/www/captive/style.css" "/www/captive/style.css" && ok "www/captive/style.css"
scp_file "$PORT_DIR/www/captive/blocked.html" "/www/captive/blocked.html" && ok "www/captive/blocked.html"
scp_file "$PORT_DIR/www/captive/admin/index.html" "/www/captive/admin/index.html" && ok "www/captive/admin/index.html (Painel Admin)"

# Link simbólico para /www/portal (compatibilidade)
ssh_cmd "ln -sf /www/captive /www/portal 2>/dev/null || true"

# Configuração UCI (preserva se já existir no roteador)
if ssh_cmd "[ -f /etc/config/captiveportal ]"; then
    warn "Configuração /etc/config/captiveportal existente preservada"
else
    scp_file "$PORT_DIR/etc/config/captiveportal" "/etc/config/captiveportal" && \
        ok "etc/config/captiveportal inicial criada"
fi

# Liberação da porta 2080 no uhttpd (exclusiva do captive_redirector.lua)
echo ""
echo "─── 5. Liberando porta 2080 para o captive_redirector..."
ssh_cmd "
uci delete uhttpd.captive 2>/dev/null || true
uci del_list uhttpd.main.listen_http='0.0.0.0:2080' 2>/dev/null || true
uci commit uhttpd
/etc/init.d/uhttpd restart >/dev/null 2>&1
"
ok "Porta 2080 liberada para o redirecionador dedicado"

# Habilita e inicia o serviço
echo ""
echo "─── 6. Habilitando e iniciando o Portal Captivo..."
ssh_cmd "/etc/init.d/captiveportal enable"
ssh_cmd "/etc/init.d/captiveportal start"
ok "Serviço captiveportal iniciado!"

# Verificação das chains no kernel
echo ""
echo "─── 7. Verificando firewall iptables..."
sleep 2
IPT_STATUS=$(ssh_cmd "iptables -L -n 2>/dev/null | grep -E 'CAPTIVE_FORWARD|CAPTIVE_AUTH'" || true)
if [ -n "$IPT_STATUS" ]; then
    ok "Chains CAPTIVE_FORWARD e CAPTIVE_AUTH ativas no kernel!"
else
    warn "Aviso: Verifique as regras via SSH com: iptables -L -n"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               🎉 Deploy Concluído com Sucesso!          ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  📊 Painel Admin:   http://${ROUTER}/captive/admin/       ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  🔑 Tela de Login:  http://${ROUTER}/captive/             ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  🌐 RFC 8908 API:   http://${ROUTER}/cgi-bin/captive_portal_api ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  🛠️  CLI Shell:      portal_ctl status / sessions / kick ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
