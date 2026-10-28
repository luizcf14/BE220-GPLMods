#!/bin/bash
# =============================================================================
# Portal Captivo 3000 — Script de Remoção (Undeploy)
# =============================================================================
#
# Uso:
#   ./undeploy.sh [IP_DO_ROTEADOR] [--remove-pkgs]
#
# Exemplos:
#   ./undeploy.sh 192.168.1.1               # remove arquivos e regras
#   ./undeploy.sh 192.168.1.1 --remove-pkgs # também desinstala os pacotes opkg
#
# O script irá:
#   1. Parar e desabilitar o serviço captiveportal
#   2. Remover regras nftables (chains e sets do portal)
#   3. Remover classes tc/HTB
#   4. Remover configuração dnsmasq do walled garden
#   5. Remover porta 2080 do uhttpd
#   6. Remover todos os arquivos instalados
#   7. (Opcional) Desinstalar pacotes opkg — use --remove-pkgs
#
# ATENÇÃO: O roteador permanece funcional após a remoção.
#   O tráfego LAN → WAN voltará a fluir sem restrições.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parâmetros
# ---------------------------------------------------------------------------
ROUTER_IP="${1:-192.168.1.1}"
REMOVE_PKGS=false
for arg in "$@"; do
    [ "$arg" = "--remove-pkgs" ] && REMOVE_PKGS=true
done

ROUTER_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()     { echo -e "${CYAN}[undeploy]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗] ERRO:${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

ssh_cmd() { ssh ${SSH_OPTS} "${ROUTER_USER}@${ROUTER_IP}" "$@"; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Portal Captivo 3000 — Remoção (Undeploy) ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
log "Roteador alvo: ${BOLD}${ROUTER_IP}${NC}"
$REMOVE_PKGS && warn "Modo --remove-pkgs: pacotes opkg também serão removidos."
echo ""

# ---------------------------------------------------------------------------
# Confirmação
# ---------------------------------------------------------------------------
echo -e "${YELLOW}Esta operação irá remover o Portal Captivo 3000 do roteador ${ROUTER_IP}.${NC}"
echo -e "${YELLOW}O tráfego LAN → WAN voltará a fluir sem restrições.${NC}"
echo ""
read -r -p "Confirmar remoção? [s/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Operação cancelada."
    exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Verifica conectividade
# ---------------------------------------------------------------------------
log "Verificando conectividade SSH com ${ROUTER_IP}..."
if ! ssh_cmd "echo ok" >/dev/null 2>&1; then
    die "Não foi possível conectar via SSH em ${ROUTER_IP}."
fi
success "SSH conectado."

# ---------------------------------------------------------------------------
# Etapa 1 — Para e desabilita o serviço
# ---------------------------------------------------------------------------
log "Parando serviço captiveportal..."
ssh_cmd "
    if [ -f /etc/init.d/captiveportal ]; then
        /etc/init.d/captiveportal stop  2>/dev/null || true
        /etc/init.d/captiveportal disable 2>/dev/null || true
        echo 'Serviço parado e desabilitado.'
    else
        echo 'Serviço não encontrado — pulando.'
    fi
" && success "Serviço parado." || warn "Serviço já estava inativo."

# ---------------------------------------------------------------------------
# Etapa 2 — Remove regras nftables manualmente (caso o stop não tenha feito)
# ---------------------------------------------------------------------------
log "Removendo regras nftables do portal..."
ssh_cmd "
    nft flush set  inet fw4 captive_authenticated 2>/dev/null || true
    nft flush set  inet fw4 captive_whitelist      2>/dev/null || true
    nft flush map  inet fw4 captive_fwmark         2>/dev/null || true
    nft delete chain inet fw4 captive_prerouting   2>/dev/null || true
    nft delete chain inet fw4 captive_forward      2>/dev/null || true
    nft delete chain inet fw4 captive_mangle       2>/dev/null || true
    nft delete set  inet fw4 captive_authenticated 2>/dev/null || true
    nft delete set  inet fw4 captive_whitelist     2>/dev/null || true
    nft delete map  inet fw4 captive_fwmark        2>/dev/null || true
    echo 'Regras nftables removidas.'
" && success "Regras nftables removidas." || warn "Algumas regras nftables podem já ter sido removidas."

# ---------------------------------------------------------------------------
# Etapa 3 — Remove classes tc/HTB
# ---------------------------------------------------------------------------
log "Removendo classes tc/HTB..."
ssh_cmd "
    WAN_IF=\$(uci -q get captiveportal.global.wan_interface 2>/dev/null || echo 'eth0.2')
    if command -v tc >/dev/null 2>&1; then
        tc qdisc del dev \"\$WAN_IF\" root 2>/dev/null || true
        echo \"Classes tc removidas da interface \$WAN_IF.\"
    else
        echo 'tc não encontrado — pulando.'
    fi
" && success "Classes tc/HTB removidas." || warn "tc não encontrado ou já removido."

# ---------------------------------------------------------------------------
# Etapa 4 — Remove configuração dnsmasq do walled garden
# ---------------------------------------------------------------------------
log "Removendo walled garden do dnsmasq..."
ssh_cmd "
    rm -f /etc/dnsmasq.d/captive-whitelist.conf
    if [ -f /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        echo 'dnsmasq reiniciado.'
    fi
" && success "Walled garden removido." || warn "Arquivo de walled garden não encontrado."

# ---------------------------------------------------------------------------
# Etapa 5 — Remove porta 2080 do uhttpd
# ---------------------------------------------------------------------------
log "Removendo porta 2080 do uhttpd..."
ssh_cmd "
    if uci show uhttpd.main.listen_http 2>/dev/null | grep -q '2080'; then
        uci del_list uhttpd.main.listen_http='0.0.0.0:2080' 2>/dev/null || true
        uci commit uhttpd
        /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
        echo 'Porta 2080 removida do uhttpd.'
    else
        echo 'Porta 2080 não estava configurada no uhttpd.'
    fi
" && success "uhttpd restaurado." || warn "Não foi possível remover a porta 2080 do uhttpd."

# ---------------------------------------------------------------------------
# Etapa 6 — Remove arquivos instalados
# ---------------------------------------------------------------------------
log "Removendo arquivos do portal..."
ssh_cmd "
    # Serviço e config
    rm -f /etc/init.d/captiveportal
    rm -f /etc/config/captiveportal
    rm -f /etc/captiveportal/10-captive-portal.nft.tpl
    rmdir /etc/captiveportal 2>/dev/null || true
    rm -f /etc/nftables.d/10-captive-portal.nft
    rm -f /tmp/captive-portal-active.nft
    rm -f /tmp/captiveportal_sessions.json
    rm -f /tmp/captive_nft_err
    rm -f /tmp/portal_auth_err

    # CGI scripts
    rm -f /www/cgi-bin/portal_redirect
    rm -f /www/cgi-bin/portal_auth

    # CLI
    rm -f /usr/bin/portal_ctl

    # Frontend
    rm -rf /www/portal/

    # LuCI (se existir)
    rm -f /usr/share/luci/menu.d/luci-app-captiveportal.json
    rm -f /usr/share/rpcd/acl.d/luci-app-captiveportal.json
    rm -f /www/luci-static/resources/view/captiveportal/config.js
    rm -f /www/luci-static/resources/view/captiveportal/sessions.js
    rm -f /www/luci-static/resources/view/captiveportal/whitelist.js
    rmdir /www/luci-static/resources/view/captiveportal 2>/dev/null || true

    echo 'Arquivos removidos.'
" && success "Arquivos removidos." || warn "Alguns arquivos podem não ter sido encontrados."

# ---------------------------------------------------------------------------
# Etapa 7 — Remove pacotes apk (somente com --remove-pkgs)
# ---------------------------------------------------------------------------
if $REMOVE_PKGS; then
    log "Removendo pacotes..."
    ssh_cmd "
        _remove() {
            local pkg=\"\$1\"
            if apk info -e \"\$pkg\" 2>/dev/null; then
                echo \"  Removendo \$pkg...\"
                apk del \"\$pkg\" >/dev/null 2>&1 && echo \"  ✓ \$pkg removido\" || echo \"  ! falhou: \$pkg\"
            else
                echo \"  ✓ \$pkg (não estava instalado)\"
            fi
        }

        _remove kmod-sched-fq-codel
        _remove kmod-sched-htb
        _remove kmod-sched-core
        _remove tc

        # Restaura dnsmasq padrão se dnsmasq-full for removido
        if apk info -e dnsmasq-full 2>/dev/null; then
            echo '  Restaurando dnsmasq padrão...'
            apk del dnsmasq-full >/dev/null 2>&1 || true
            apk add dnsmasq >/dev/null 2>&1 && echo '  ✓ dnsmasq restaurado' || echo '  ! falhou ao restaurar dnsmasq'
        fi
    " && success "Pacotes removidos." || warn "Falha ao remover alguns pacotes."
else
    warn "Pacotes mantidos (use --remove-pkgs para removê-los)."
fi

# ---------------------------------------------------------------------------
# Etapa 8 — Recarrega o firewall para limpar estado
# ---------------------------------------------------------------------------
log "Recarregando firewall..."
ssh_cmd "
    [ -f /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1 || true
" && success "Firewall recarregado." || warn "Não foi possível recarregar o firewall."

# ---------------------------------------------------------------------------
# Verificação final
# ---------------------------------------------------------------------------
echo ""
log "Verificação pós-remoção..."
echo ""

CHAINS_LEFT=$(ssh_cmd "nft list ruleset 2>/dev/null | grep -E 'chain captive_|set captive_' | wc -l" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')
: ${CHAINS_LEFT:=0}
if [ "${CHAINS_LEFT}" -eq 0 ]; then
    success "nftables: nenhuma chain/set captive restante (tráfego livre)"
else
    warn "nftables: ${CHAINS_LEFT} objeto(s) captive ainda presente(s) — verifique manualmente"
fi

FILES_LEFT=$(ssh_cmd "ls /etc/init.d/captiveportal /www/cgi-bin/portal_auth /usr/bin/portal_ctl 2>/dev/null | wc -l" 2>/dev/null || echo "0")
if [ "${FILES_LEFT}" -eq 0 ]; then
    success "Arquivos: nenhum arquivo do portal restante"
else
    warn "Arquivos: ${FILES_LEFT} arquivo(s) não removido(s)"
fi

# ---------------------------------------------------------------------------
# Sumário final
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Remoção concluída!                          ${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  O Portal Captivo 3000 foi removido do roteador ${BOLD}${ROUTER_IP}${NC}."
echo -e "  O tráfego LAN → WAN volta a fluir sem restrições."
echo ""
if ! $REMOVE_PKGS; then
    echo -e "  Para remover também os pacotes opkg instalados:"
    echo -e "  ${YELLOW}./undeploy.sh ${ROUTER_IP} --remove-pkgs${NC}"
    echo ""
fi
