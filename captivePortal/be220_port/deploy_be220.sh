#!/bin/bash
# deploy_be220.sh — Instala o Portal Captivo 3000 no Archer BE220
#
# Uso: bash deploy_be220.sh [IP_DO_ROTEADOR]
# Padrão: 192.168.0.1

ROUTER="${1:-192.168.0.1}"
ROUTER_USER="root"
ROUTER_PASS="<ROOT_PASSWORD>"
PORT_DIR="$(dirname "$0")/be220_port/openwrt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

# Usa sshpass para autenticação por senha
ssh_cmd() { sshpass -p "$ROUTER_PASS" ssh -o StrictHostKeyChecking=no "$ROUTER_USER@$ROUTER" "export PATH=/sbin:/bin:/usr/sbin:/usr/bin:\$PATH; $*"; }
scp_file() { sshpass -p "$ROUTER_PASS" scp -O -o StrictHostKeyChecking=no "$1" "$ROUTER_USER@$ROUTER:$2"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Portal Captivo 3000 — Deploy Archer BE220       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Verifica dependências locais
command -v sshpass >/dev/null 2>&1 || { err "sshpass não encontrado. Instale: apt install sshpass"; exit 1; }

echo "Destino: root@${ROUTER}"
echo "Fonte:   ${PORT_DIR}"
echo ""

# Testa conectividade
echo "─── Testando conexão SSH..."
ssh_cmd "echo ok" >/dev/null 2>&1 || { err "Não foi possível conectar em $ROUTER. Verifique IP e senha."; exit 1; }
ok "Conectado ao roteador"

# Verifica pré-requisitos no roteador
echo ""
echo "─── Verificando dependências no roteador..."
ssh_cmd "iptables --version" >/dev/null 2>&1 && ok "iptables: disponível" || { err "iptables não encontrado!"; exit 1; }
ssh_cmd "ls /lib/functions.sh" >/dev/null 2>&1 && ok "functions.sh: disponível" || warn "functions.sh ausente — UCI pode não funcionar"
ssh_cmd "ls /etc/init.d/uhttpd" >/dev/null 2>&1 && ok "uhttpd: disponível" || warn "uhttpd não encontrado!"
ssh_cmd "ls /proc/net/nf_conntrack" >/dev/null 2>&1 && ok "conntrack: disponível" || warn "conntrack proc ausente"

# Para serviço se já estiver rodando
echo ""
echo "─── Parando serviço existente (se houver)..."
ssh_cmd "/etc/init.d/captiveportal stop 2>/dev/null; true"
ok "Serviço parado"

# Cria diretórios no roteador
echo ""
echo "─── Criando diretórios..."
ssh_cmd "mkdir -p /etc/captiveportal /www/cgi-bin /www/captive/admin /tmp/dnsmasq.d"
ok "Diretórios criados"

# Copia arquivos
echo ""
echo "─── Copiando arquivos..."

upload() {
    local src="$1" dst="$2" mode="${3:-644}"
    if [ -f "$PORT_DIR/$src" ]; then
        scp_file "$PORT_DIR/$src" "$dst" && \
            ssh_cmd "chmod $mode $dst" && \
            ok "$src → $dst" || \
            err "Falha ao enviar $src"
    else
        warn "AVISO: $PORT_DIR/$src não encontrado"
    fi
}

# init.d
upload "etc/init.d/captiveportal"         "/etc/init.d/captiveportal"             755

# CGI scripts
upload "www/cgi-bin/portal_auth"          "/www/cgi-bin/portal_auth"              755
upload "www/cgi-bin/portal_redirect"      "/www/cgi-bin/portal_redirect"          755
upload "www/cgi-bin/captive_portal_api"   "/www/cgi-bin/captive_portal_api"       755
upload "www/cgi-bin/captive_admin_api"    "/www/cgi-bin/captive_admin_api"        755

# Admin panel
upload "www/captive/admin/index.html"     "/www/captive/admin/index.html"         644

# Captiveportal scripts
upload "etc/captiveportal/captive_redirector.lua" "/etc/captiveportal/captive_redirector.lua" 755
upload "etc/captiveportal/refresh-whitelist.sh"  "/etc/captiveportal/refresh-whitelist.sh" 755
upload "etc/captiveportal/renew-sessions.sh"     "/etc/captiveportal/renew-sessions.sh"    755

# Config UCI (só instala se não existir ainda)
ssh_cmd "[ -f /etc/config/captiveportal ]" && \
    warn "Config UCI já existe — não sobrescrevendo. Edite /etc/config/captiveportal manualmente." || \
    upload "etc/config/captiveportal" "/etc/config/captiveportal" 644

# Garante que uhttpd não escuta na porta 2080 (reservada para captive_redirector.lua)
echo ""
echo "─── Liberando porta 2080 para o captive_redirector..."
ssh_cmd "
uci delete uhttpd.captive 2>/dev/null || true
uci del_list uhttpd.main.listen_http='0.0.0.0:2080' 2>/dev/null || true
uci commit uhttpd
/etc/init.d/uhttpd restart >/dev/null 2>&1
echo ok
" && ok "Porta 2080 liberada para o redirecionador dedicado" || warn "Aviso ao configurar uhttpd"

# Habilita serviço no boot
echo ""
echo "─── Habilitando serviço no boot..."
ssh_cmd "/etc/init.d/captiveportal enable" && ok "Serviço habilitado no boot" || warn "Falha ao habilitar"

# Inicia serviço
echo ""
echo "─── Iniciando Portal Captivo..."
ssh_cmd "/etc/init.d/captiveportal start" && ok "Serviço iniciado!" || err "Falha ao iniciar serviço"

# Verificação final
echo ""
echo "─── Verificação final..."
sleep 2
CHAINS=$(ssh_cmd "iptables -L -n 2>/dev/null | grep -c CAPTIVE_" 2>/dev/null || echo 0)
if [ "${CHAINS:-0}" -gt 0 ]; then
    ok "Chains iptables ativas ($CHAINS encontradas)"
else
    warn "Chains iptables não detectadas — verifique com: ssh root@$ROUTER 'iptables -L -n | grep CAPTIVE'"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              Deploy Concluído! 🚀                ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Painel Admin: http://${ROUTER}/captive/admin/   ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Portal Login: http://${ROUTER}/captive/          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  CAPPORT API:  http://${ROUTER}/cgi-bin/          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                captive_portal_api                ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Edite a config UCI no roteador:"
echo -e "  ${YELLOW}ssh root@${ROUTER} 'vi /etc/config/captiveportal'${NC}"
echo ""
