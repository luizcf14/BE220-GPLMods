#!/bin/bash
# =============================================================================
# Portal Captivo 3000 — Script de Deploy
# =============================================================================
#
# Uso:
#   ./deploy.sh [IP_DO_ROTEADOR]
#
# Exemplo:
#   ./deploy.sh 192.168.1.1
#
# O script irá:
#   1. Enviar todos os arquivos ao roteador via SCP (SSH)
#   2. Ajustar permissões
#   3. Habilitar e iniciar o serviço captiveportal
#   4. Recarregar o firewall (fw4) para incluir as regras nftables
#
# Pré-requisitos no roteador:
#   - OpenWrt 23+ com fw4/nftables
#   - Pacotes: uclient-fetch, dnsmasq-full, tc, kmod-sched-core, kmod-sched-htb
#   - SSH habilitado e chave pública configurada (ou senha root disponível)
#
# Instalar dependências no roteador (executar uma vez):
#   opkg update
#   opkg install uclient-fetch dnsmasq-full tc kmod-sched-core kmod-sched-htb kmod-sched-fq-codel
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
ROUTER_IP="${1:-192.168.1.1}"
ROUTER_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
SCP_OPTS="-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="${SCRIPT_DIR}/openwrt"
FRONTEND_DIR="${SCRIPT_DIR}/frontend"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()     { echo -e "${CYAN}[deploy]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗] ERRO:${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

ssh_cmd()  { ssh  ${SSH_OPTS} "${ROUTER_USER}@${ROUTER_IP}" "$@"; }
# tr -d '\r' converte CRLF (Windows) → LF (Linux) antes de enviar.
# Sem isso, arquivos editados no Windows causam erros silenciosos em nft, sh e BusyBox.
scp_file() { cat "$1" | tr -d '\r' | ssh ${SSH_OPTS} "${ROUTER_USER}@${ROUTER_IP}" "cat > '$2'"; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Portal Captivo 3000 — Deploy           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
log "Roteador alvo: ${BOLD}${ROUTER_IP}${NC}"
log "Diretório fonte: ${SCRIPT_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Verifica conectividade
# ---------------------------------------------------------------------------
log "Verificando conectividade SSH com ${ROUTER_IP}..."
if ! ssh_cmd "echo ok" >/dev/null 2>&1; then
    die "Não foi possível conectar via SSH em ${ROUTER_IP}. Verifique a chave SSH e se o roteador está acessível."
fi
success "SSH conectado."

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Etapa 1 — Verifica dependências (opcional)
# ---------------------------------------------------------------------------
log "Verificando dependências e aceleradores no roteador..."
ssh_cmd "
    # Habilita Packet Steering por padrão em todas as CPUs (processamento multi-core de pacotes)
    uci set network.globals.packet_steering='1' 2>/dev/null || true
    uci commit network 2>/dev/null || true

    if ! dnsmasq --version 2>&1 | grep -v 'no-nftset' | grep -q 'nftset'; then
        echo '  Instalando dnsmasq-full (suporte a nftset)...'
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            opkg remove dnsmasq >/dev/null 2>&1
            opkg install dnsmasq-full >/dev/null 2>&1 && echo '  ✓ dnsmasq-full (instalado)' || echo '  ○ dnsmasq-full (instalação falhou - mantendo dnsmasq padrão)'
        elif command -v apk >/dev/null 2>&1; then
            apk del dnsmasq >/dev/null 2>&1
            apk add dnsmasq-full >/dev/null 2>&1 && echo '  ✓ dnsmasq-full (instalado)' || echo '  ○ dnsmasq-full (instalação falhou)'
        fi
    else
        echo '  ✓ dnsmasq-full (já instalado com suporte a nftset)'
    fi

    if ! command -v tc >/dev/null 2>&1; then
        echo '  Instalando tc (Traffic Control / QoS)...'
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            opkg install tc kmod-sched-core kmod-sched-htb >/dev/null 2>&1 && echo '  ✓ tc (instalado)' || echo '  ○ tc (instalação falhou)'
        elif command -v apk >/dev/null 2>&1; then
            apk add tc >/dev/null 2>&1 && echo '  ✓ tc (instalado)' || echo '  ○ tc (instalação falhou)'
        fi
    else
        echo '  ✓ tc (já instalado)'
    fi

    # Verifica e instala kmod-nft-offload se compatível com o roteador/kernel
    if ! (opkg list-installed 2>/dev/null | grep -q 'kmod-nft-offload' || apk list --installed 2>/dev/null | grep -q 'kmod-nft-offload'); then
        echo '  Verificando disponibilidade do kmod-nft-offload...'
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            opkg install kmod-nft-offload >/dev/null 2>&1 && echo '  ✓ kmod-nft-offload (instalado)' || echo '  ○ kmod-nft-offload (não disponível para esta versão de kernel/hardware)'
        elif command -v apk >/dev/null 2>&1; then
            apk add kmod-nft-offload >/dev/null 2>&1 && echo '  ✓ kmod-nft-offload (instalado)' || echo '  ○ kmod-nft-offload (não disponível para esta versão de kernel/hardware)'
        fi
    else
        echo '  ✓ kmod-nft-offload (já instalado)'
    fi
" && success "Dependências verificadas."

# ---------------------------------------------------------------------------
# Etapa 2 — Cria estrutura de diretórios no roteador
# ---------------------------------------------------------------------------
log "Criando estrutura de diretórios no roteador..."
ssh_cmd "
    mkdir -p /etc/config
    mkdir -p /etc/init.d
    mkdir -p /etc/captiveportal
    mkdir -p /etc/nftables.d
    mkdir -p /tmp/dnsmasq.d
    mkdir -p /www/cgi-bin
    mkdir -p /www/portal
    mkdir -p /www/luci-static/resources/view/captiveportal
    mkdir -p /usr/bin
    mkdir -p /usr/share/luci/menu.d
    mkdir -p /usr/share/rpcd/acl.d
"
success "Diretórios criados."

# ---------------------------------------------------------------------------
# Etapa 2 — Envia arquivos de configuração e scripts
# ---------------------------------------------------------------------------
log "Enviando arquivo de configuração UCI..."
scp_file "${OPENWRT_DIR}/etc/config/captiveportal"            "/etc/config/captiveportal"
ssh_cmd "
    # Auto-detecta a interface WAN real do roteador e ajusta no UCI se o dispositivo não existir
    CONF_WAN=\$(uci -q get captiveportal.global.wan_interface)
    if [ -z \"\$CONF_WAN\" ] || ! ip link show \"\$CONF_WAN\" >/dev/null 2>&1; then
        AUTO_WAN=\$(ip route show default 2>/dev/null | awk '/default/ {print \$5}' | head -n1)
        if [ -n \"\$AUTO_WAN\" ]; then
            uci set captiveportal.global.wan_interface=\"\$AUTO_WAN\"
            uci commit captiveportal
            echo \"  [i] Interface WAN auto-detectada no roteador: \$AUTO_WAN\"
        fi
    fi
"
success "  /etc/config/captiveportal"

log "Enviando template nftables e scripts..."
ssh_cmd "mkdir -p /etc/hotplug.d/iface"
scp_file "${OPENWRT_DIR}/etc/captiveportal/10-captive-portal.nft.tpl" "/etc/captiveportal/10-captive-portal.nft.tpl"
scp_file "${OPENWRT_DIR}/etc/captiveportal/refresh-whitelist.sh"      "/etc/captiveportal/refresh-whitelist.sh"
scp_file "${OPENWRT_DIR}/etc/captiveportal/renew-sessions.sh"          "/etc/captiveportal/renew-sessions.sh"
scp_file "${OPENWRT_DIR}/etc/hotplug.d/iface/99-zerotier"              "/etc/hotplug.d/iface/99-zerotier"
success "  /etc/captiveportal/10-captive-portal.nft.tpl"
success "  /etc/captiveportal/refresh-whitelist.sh (cron refresh CDN IPs)"
success "  /etc/captiveportal/renew-sessions.sh (cron auto-renovação de sessão)"
success "  /etc/hotplug.d/iface/99-zerotier (hotplug bind IP ZeroTier)"

log "Configurando ZeroTier (gerenciamento remoto)..."
ssh_cmd "
    # 1. Verifica se pacote ZeroTier já está instalado
    if command -v zerotier-one >/dev/null 2>&1 || command -v zerotier-cli >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q zerotier || apk list --installed 2>/dev/null | grep -q zerotier; then
        echo '  ✓ ZeroTier já instalado no roteador'
    else
        echo '  Instalando ZeroTier...'
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            opkg install zerotier >/dev/null 2>&1 && echo '  ✓ ZeroTier (instalado)' || echo '  ○ ZeroTier (instalação falhou)'
        elif command -v apk >/dev/null 2>&1; then
            apk add zerotier >/dev/null 2>&1 && echo '  ✓ ZeroTier (instalado)' || echo '  ○ ZeroTier (instalação falhou)'
        fi
    fi

    # 2. Verifica se a rede ZeroTier já está configurada
    CURRENT_ID=\$(uci -q get zerotier.openwrt_network.id)
    if [ \"\$CURRENT_ID\" = \"633e31d8a24e21ec\" ]; then
        echo '  ✓ Rede ZeroTier (633e31d8a24e21ec) já configurada'
    else
        uci set zerotier.global.enabled='1'
        uci delete zerotier.earth 2>/dev/null || true
        uci set zerotier.openwrt_network=network
        uci set zerotier.openwrt_network.id='633e31d8a24e21ec'
        uci commit zerotier
        /etc/init.d/zerotier enable 2>/dev/null || true
        /etc/init.d/zerotier restart 2>/dev/null || true
        echo '  ✓ Rede ZeroTier configurada'
    fi

    # Registra a interface zerotier no /etc/config/network se não existir
    if ! uci show network 2>/dev/null | grep -q 'network.zerotier=interface'; then
        uci set network.zerotier=interface
        uci set network.zerotier.device='zt+'
        uci set network.zerotier.proto='none'
        uci commit network
        reload_config 2>/dev/null || true
    fi

    # Garante que netifd não trave a interface rodando udhcpc em modo DHCP
    if [ \"\$(uci -q get network.zerotier.proto 2>/dev/null)\" = \"dhcp\" ]; then
        uci set network.zerotier.proto='none'
        uci commit network
        reload_config 2>/dev/null || true
    fi

    # Vincula o IP atribuído pelo controlador ZeroTier à interface no kernel Linux
    ZT_DEV=\$(zerotier-cli listnetworks 2>/dev/null | awk '/OK PRIVATE/{print \$8}' | head -1)
    ZT_IP=\$(zerotier-cli listnetworks 2>/dev/null | awk '/OK PRIVATE/{print \$9}' | head -1)
    if [ -n \"\$ZT_DEV\" ] && [ -n \"\$ZT_IP\" ] && [ \"\$ZT_DEV\" != \"OK\" ]; then
        ip addr add \"\$ZT_IP\" dev \"\$ZT_DEV\" 2>/dev/null || true
    fi

    # 3. Verifica se regra de firewall já existe (por nome ou por porta 9993)
    if uci show firewall 2>/dev/null | grep -E -q 'Allow-ZeroTier-Inbound|dest_port=.?9993'; then
        echo '  ✓ Regra de firewall ZeroTier Inbound (UDP 9993) já existe'
    else
        uci add firewall rule
        uci set firewall.@rule[-1].name='Allow-ZeroTier-Inbound'
        uci set firewall.@rule[-1].src='*'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].dest_port='9993'
        uci commit firewall
        /etc/init.d/firewall reload 2>/dev/null || true
        echo '  ✓ Regra de firewall Allow-ZeroTier-Inbound criada'
    fi

    # 4. Verifica se a zona de firewall do ZeroTier (zt+) já foi criada
    if uci show firewall 2>/dev/null | grep -q 'firewall.zerotier=zone'; then
        echo '  ✓ Zona de firewall zerotier (zt+) já existe'
    else
        uci set firewall.zerotier=zone
        uci set firewall.zerotier.name='zerotier'
        uci set firewall.zerotier.input='ACCEPT'
        uci set firewall.zerotier.output='ACCEPT'
        uci set firewall.zerotier.forward='ACCEPT'
        uci set firewall.zerotier.masq='1'
        uci set firewall.zerotier.mtu_fix='1'
        uci add_list firewall.zerotier.device='zt+' 2>/dev/null || uci set firewall.zerotier.network='zerotier'
        uci set firewall.zerotier_forward_lan=forwarding
        uci set firewall.zerotier_forward_lan.src='zerotier'
        uci set firewall.zerotier_forward_lan.dest='lan'
        uci set firewall.lan_forward_zerotier=forwarding
        uci set firewall.lan_forward_zerotier.src='lan'
        uci set firewall.lan_forward_zerotier.dest='zerotier'
        uci commit firewall
        /etc/init.d/firewall reload 2>/dev/null || true
        echo '  ✓ Zona de firewall zerotier (zt+) e forwarding com a LAN criados'
    fi
" && success "ZeroTier e zonas de firewall verificadas."

log "Configurando Wi-Fi aberto (Povos da Floresta 2)..."
ssh_cmd "
    if [ -f /etc/config/wireless ]; then
        uci delete wireless.radio0.disabled 2>/dev/null || true
        uci delete wireless.radio1.disabled 2>/dev/null || true

        if uci -q get wireless.default_radio0 >/dev/null; then
            uci set wireless.default_radio0.ssid='Povos da Floresta 2'
            uci set wireless.default_radio0.encryption='none'
            uci set wireless.default_radio0.network='lan'
            uci set wireless.default_radio0.mode='ap'
            uci delete wireless.default_radio0.disabled 2>/dev/null || true
        fi

        if uci -q get wireless.default_radio1 >/dev/null; then
            uci set wireless.default_radio1.ssid='Povos da Floresta 2'
            uci set wireless.default_radio1.encryption='none'
            uci set wireless.default_radio1.network='lan'
            uci set wireless.default_radio1.mode='ap'
            uci delete wireless.default_radio1.disabled 2>/dev/null || true
        fi

        uci commit wireless
        wifi reload 2>/dev/null || wifi 2>/dev/null || true
    fi
" && success "Wi-Fi 'Povos da Floresta 2' (2.4GHz & 5GHz, aberto) configurado na interface lan."

log "Enviando serviço init.d..."
scp_file "${OPENWRT_DIR}/etc/init.d/captiveportal"             "/etc/init.d/captiveportal"
success "  /etc/init.d/captiveportal"

log "Enviando CGI scripts..."
scp_file "${OPENWRT_DIR}/www/cgi-bin/portal_redirect"          "/www/cgi-bin/portal_redirect"
scp_file "${OPENWRT_DIR}/www/cgi-bin/portal_auth"              "/www/cgi-bin/portal_auth"
scp_file "${OPENWRT_DIR}/www/cgi-bin/captive_portal_api"       "/www/cgi-bin/captive_portal_api"
success "  /www/cgi-bin/portal_redirect"
success "  /www/cgi-bin/portal_auth"
success "  /www/cgi-bin/captive_portal_api (RFC 8908 CAPPORT)"

log "Enviando portal_ctl..."
scp_file "${OPENWRT_DIR}/usr/bin/portal_ctl"                   "/usr/bin/portal_ctl"
success "  /usr/bin/portal_ctl"

# ---------------------------------------------------------------------------
# Etapa 3 — Frontend (tela de login do cliente)
# ---------------------------------------------------------------------------
log "Enviando frontend (tela de login e bloqueio)..."
scp_file "${FRONTEND_DIR}/index.html"   "/www/portal/index.html"
scp_file "${FRONTEND_DIR}/style.css"    "/www/portal/style.css"
scp_file "${FRONTEND_DIR}/app.js"       "/www/portal/app.js"
scp_file "${FRONTEND_DIR}/blocked.html"   "/www/portal/blocked.html"
success "  /www/portal/ (index.html, style.css, app.js, blocked.html)"

# ---------------------------------------------------------------------------
# Etapa 4 — Integração LuCI (opcional, requer luci instalado)
# ---------------------------------------------------------------------------
log "Enviando integração LuCI..."
if ssh_cmd "[ -d /usr/share/luci ]" 2>/dev/null; then
    scp_file "${OPENWRT_DIR}/usr/share/luci/menu.d/luci-app-captiveportal.json" \
             "/usr/share/luci/menu.d/luci-app-captiveportal.json"
    scp_file "${OPENWRT_DIR}/usr/share/rpcd/acl.d/luci-app-captiveportal.json" \
             "/usr/share/rpcd/acl.d/luci-app-captiveportal.json"

    # Views JavaScript
    scp_file "${OPENWRT_DIR}/htdocs/luci-static/resources/view/captiveportal/config.js" \
             "/www/luci-static/resources/view/captiveportal/config.js"
    scp_file "${OPENWRT_DIR}/htdocs/luci-static/resources/view/captiveportal/sessions.js" \
             "/www/luci-static/resources/view/captiveportal/sessions.js"
    scp_file "${OPENWRT_DIR}/htdocs/luci-static/resources/view/captiveportal/whitelist.js" \
             "/www/luci-static/resources/view/captiveportal/whitelist.js"
    scp_file "${OPENWRT_DIR}/htdocs/luci-static/resources/view/captiveportal/blacklist.js" \
             "/www/luci-static/resources/view/captiveportal/blacklist.js"
    ssh_cmd "/etc/init.d/rpcd restart >/dev/null 2>&1 || true"
    success "  LuCI views e ACLs enviados (rpcd recarregado)."
else
    warn "LuCI não detectado — pulando arquivos LuCI (opcional)."
fi

# ---------------------------------------------------------------------------
# Etapa 5 — Permissões
# ---------------------------------------------------------------------------
log "Ajustando permissões..."
ssh_cmd "
    # Scripts executáveis
    chmod 755 /etc/init.d/captiveportal
    chmod 755 /etc/captiveportal/refresh-whitelist.sh
    chmod 755 /etc/captiveportal/renew-sessions.sh
    chmod 755 /etc/hotplug.d/iface/99-zerotier
    chmod 755 /www/cgi-bin/portal_redirect
    chmod 755 /www/cgi-bin/portal_auth
    chmod 755 /www/cgi-bin/captive_portal_api
    chmod 755 /usr/bin/portal_ctl

    # Arquivos de configuração (somente root)
    chmod 600 /etc/config/captiveportal
    chmod 644 /etc/captiveportal/10-captive-portal.nft.tpl

    # Frontend (leitura pública via uhttpd)
    chmod 644 /www/portal/index.html
    chmod 644 /www/portal/style.css
    chmod 644 /www/portal/app.js
    chmod 644 /www/portal/blocked.html
"
success "Permissões ajustadas."

# ---------------------------------------------------------------------------
# Etapa 6 — Configura uhttpd para escutar também na porta 2080
#           (porta do portal captivo — intercepta HTTP não autenticado)
# ---------------------------------------------------------------------------
log "Configurando uhttpd para porta 2080 (portal captivo)..."
ssh_cmd "
    # Adiciona listener na porta 2080 se não existir
    if ! uci show uhttpd.main.listen_http 2>/dev/null | grep -q '2080'; then
        uci add_list uhttpd.main.listen_http='0.0.0.0:2080'
        echo 'Porta 2080 adicionada ao uhttpd'
    else
        echo 'Porta 2080 já configurada no uhttpd'
    fi

    # Configura error_page para chamar portal_redirect em qualquer 404.
    # Sem isso: quando nftables redireciona http://msftconnecttest.com/connecttest.txt
    # para a porta 2080, o uhttpd busca /www/connecttest.txt, não encontra → 404.
    # Com error_page: o 404 chama portal_redirect → 302 para o portal de login.
    # Isso é o que dispara o pop-up automático no Windows, iOS e Android.
    uci set uhttpd.main.error_page='/cgi-bin/portal_redirect'

    uci commit uhttpd
    echo 'uhttpd configurado: porta 2080 + error_page'
"
success "uhttpd configurado."

# ---------------------------------------------------------------------------
# Etapa 7 — Habilita e inicia o serviço captiveportal
# ---------------------------------------------------------------------------
log "Habilitando serviço captiveportal no boot..."
ssh_cmd "/etc/init.d/captiveportal enable"
success "Serviço habilitado."

log "Iniciando serviço captiveportal..."
# Limpa artefatos de versões anteriores que podem causar deadlock no dnsmasq
ssh_cmd "
    rm -f /etc/nftables.d/10-captive-portal.nft
    rm -f /etc/dnsmasq.d/captive-whitelist.conf
    mkdir -p /tmp/dnsmasq.d
    /etc/init.d/captiveportal restart >/dev/null 2>&1
" \
    && success "Serviço iniciado." \
    || warn "Serviço com aviso no start — verifique com: ssh root@${ROUTER_IP} 'logread | grep captiveportal'"

# ---------------------------------------------------------------------------
# Etapa 8 — Recarrega o firewall DEPOIS do captiveportal
#           (fw4 carrega o include UCI registrado acima)
# ---------------------------------------------------------------------------
log "Recarregando firewall (fw4)..."
ssh_cmd "
    if [ -f /etc/init.d/firewall ]; then
        /etc/init.d/firewall reload 2>/dev/null && echo 'fw4 recarregado'
    fi
" && success "Firewall recarregado (include captiveportal_nft registrado)." \
  || warn "Não foi possível recarregar o firewall — faça manualmente: service firewall reload"

# ---------------------------------------------------------------------------
# Etapa 9 — Reinicia uhttpd para aplicar novo listener
# ---------------------------------------------------------------------------
log "Reiniciando uhttpd..."
ssh_cmd "/etc/init.d/uhttpd restart 2>/dev/null" && success "uhttpd reiniciado." || \
    warn "Não foi possível reiniciar uhttpd — faça manualmente."

# ---------------------------------------------------------------------------
# Verificação final
# ---------------------------------------------------------------------------
echo ""
log "Verificação pós-deploy..."
echo ""

# Verifica sets e mapas nftables
NFT_CHECK=$(ssh_cmd "nft list table inet fw4 2>/dev/null | grep -E 'set captive_|map captive_' | wc -l" 2>/dev/null || echo "0")
if [ "${NFT_CHECK}" -ge 3 ]; then
    success "nftables: ${NFT_CHECK} objetos captive (sets e maps) ativos"
else
    warn "nftables: sets captive não detectados — diagnóstico:"
    echo ""
    # Mostra erro real do nft e logs do captiveportal
    ssh_cmd "
        echo '  --- Erro nft (se houver) ---'
        cat /tmp/captive_nft_err 2>/dev/null || echo '  (sem arquivo de erro)'
        echo '  --- Últimas linhas do log captiveportal ---'
        logread 2>/dev/null | grep captiveportal | tail -10 || echo '  (sem logs)'
        echo '  --- Arquivo nft gerado ---'
        head -5 /etc/nftables.d/10-captive-portal.nft 2>/dev/null || echo '  (arquivo não gerado)'
    "
    echo ""
    warn "Execute manualmente: ssh root@${ROUTER_IP} 'service captiveportal restart; logread | grep captive'"
fi

# Verifica se portal_ctl funciona
if ssh_cmd "portal_ctl help" >/dev/null 2>&1; then
    success "portal_ctl: OK"
else
    warn "portal_ctl: não respondeu — verifique a permissão de execução"
fi

# ---------------------------------------------------------------------------
# Sumário final
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Deploy concluído com sucesso!               ${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo ""
# Busca o IP ativo do ZeroTier
CURRENT_ZT_IP=$(ssh_cmd "zerotier-cli listnetworks 2>/dev/null | awk '/OK PRIVATE/{print \$9}' | cut -d'/' -f1" 2>/dev/null || echo "")

echo -e "  Portal de login:  ${CYAN}http://${ROUTER_IP}/portal/${NC}"
echo -e "  LuCI (admin):     ${CYAN}http://${ROUTER_IP}/cgi-bin/luci/admin/services/captiveportal${NC}"
if [ -n "${CURRENT_ZT_IP}" ]; then
    echo -e "  ZeroTier (IP):    ${GREEN}${CURRENT_ZT_IP}${NC} (ping: ping ${CURRENT_ZT_IP})"
fi
echo ""
echo -e "  Próximos passos:"
echo -e "  1. Conecte um dispositivo na LAN do roteador"
echo -e "  2. Tente acessar qualquer site HTTP (ex: http://example.com)"
echo -e "  3. Você deve ser redirecionado para o portal de login"
echo -e "  4. Faça login com suas credenciais do backend Laravel"
echo ""
echo -e "  Logs em tempo real:"
echo -e "  ${YELLOW}ssh root@${ROUTER_IP} 'logread -f | grep captive'${NC}"
echo ""
echo -e "  Gerenciamento:"
echo -e "  ${YELLOW}ssh root@${ROUTER_IP} 'portal_ctl status'${NC}"
echo -e "  ${YELLOW}ssh root@${ROUTER_IP} 'portal_ctl sessions'${NC}"
echo ""

log "Reiniciando o roteador para aplicar todas as alterações..."
ssh_cmd "reboot" 2>/dev/null || true
success "Comando de reboot enviado ao roteador."
echo ""
