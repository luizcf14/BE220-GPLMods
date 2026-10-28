#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_BIN="$SCRIPT_DIR/mtd8_rootfs1.bin"
OUTPUT_BIN="$SCRIPT_DIR/rootfs1_mod.bin"
WORK_DIR="/tmp/be220_squashfs_work"

# Credenciais de build. Para uso privado, crie 'build.local.env' (ignorado pelo git) com:
#   SSH_PUBKEY="ssh-rsa AAAA... usuario@host"
#   ROOT_PASSWORD="sua-senha"            (ou ROOT_HASH='$1$...' ja calculado)
# Sem esse arquivo, gera-se uma imagem generica: SEM chave SSH e com a senha de
# root padrao 'changeme' (TROQUE assim que acessar o roteador com 'passwd').
[ -f "$SCRIPT_DIR/build.local.env" ] && . "$SCRIPT_DIR/build.local.env"
USER_PUBKEY="${SSH_PUBKEY:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-changeme}"
if [ -z "${ROOT_HASH:-}" ]; then
    ROOT_HASH="$(openssl passwd -1 "$ROOT_PASSWORD")"
fi

echo "=============================================="
echo "  TP-Link Archer BE220 - RootFS Builder v3"
echo "  (Com Suporte a PTY + Flag Secreta -L)"
echo "=============================================="

# 1. Perguntar ao usuário sobre o Slot B (Dual-Bank vs Expandido 66MB)
if [ -n "$1" ]; then
    CHOICE="$1"
else
    echo ""
    echo "Escolha a estratégia de layout da memória Flash:"
    echo "  [1] Manter Slot B (Modo Dual-Bank Padrão - Limite 33.1 MB)"
    echo "  [2] Expandir Slot 1 para ~66 MB (Descarta Slot B para liberar espaço extra)"
    read -p "Selecione uma opção [1 ou 2] (Padrão: 1): " CHOICE
fi

if [ "$CHOICE" = "2" ]; then
    LAYOUT_MODE="EXPANDED"
    MAX_SIZE=66281472 # ~66.2 MB
    echo "[*] Modo selecionado: EXPANDIDO (~66 MB, Single-Bank Slot 1)"
else
    LAYOUT_MODE="DUAL_BANK"
    MAX_SIZE=33140736 # ~31.6 MB (Limite estrito da partição de fábrica)
    echo "[*] Modo selecionado: DUAL-BANK PADRÃO (33.1 MB, Slot A + Slot B)"
fi

# 2. Verificar ferramentas necessárias
if ! command -v mksquashfs &> /dev/null || ! command -v unsquashfs &> /dev/null; then
    echo "[!] Instalando squashfs-tools..."
    sudo apt-get update && sudo apt-get install -y squashfs-tools
fi

if [ ! -f "$ORIGINAL_BIN" ]; then
    echo "[-] ERRO: Arquivo $ORIGINAL_BIN nao encontrado!"
    exit 1
fi

# 3. Extrair no sistema ext4 nativo do Linux (obrigatorio para preservar os 459 symlinks)
echo "[*] Extraindo firmware original em $WORK_DIR..."
rm -rf "$WORK_DIR"
unsquashfs -d "$WORK_DIR" "$ORIGINAL_BIN" || [ -d "$WORK_DIR" ]

# 4. Aplicar modificações cirúrgicas
echo "[*] Aplicando modificacoes cirurgicas:"

# Patch 1: /etc/inittab -> shell root direto na serial
echo "  [+] Habilitando ash --login direto na serial (/etc/inittab)..."
sed -i 's/#ttyAMA0::askfirst:\/bin\/ash --login/ttyAMA0::askfirst:\/bin\/ash --login/' "$WORK_DIR/etc/inittab"
sed -i 's/^ttyAMA0::askfirst:\/bin\/login/#ttyAMA0::askfirst:\/bin\/login/' "$WORK_DIR/etc/inittab"

# Patch 2: /etc/shadow e /etc/passwd -> senha do root e shell do admin
echo "  [+] Gravando hash nativo no /etc/shadow e /etc/passwd..."
sed -i "s|^root:[^:]*:|root:$ROOT_HASH:|" "$WORK_DIR/etc/shadow"
sed -i "s|^root:[^:]*:|root:$ROOT_HASH:|" "$WORK_DIR/etc/passwd"
sed -i 's|/bin/false|/bin/ash|g' "$WORK_DIR/etc/passwd"

# Patch 3: /etc/config/accountmgnt -> suporte a svr_auth_uci() proprietario da TP-Link
echo "  [+] Adicionando root no /etc/config/accountmgnt (cloud_account)..."
cat << EOF >> "$WORK_DIR/etc/config/accountmgnt"

config cloud_account 'root'
	option username 'root'
	option shadow '$ROOT_HASH'
EOF

# Patch 4: Injetar chave publica SSH do usuario
if [ -n "$USER_PUBKEY" ]; then
    echo "  [+] Gravando chave SSH RSA em /etc/dropbear e /root/.ssh..."
    mkdir -p "$WORK_DIR/etc/dropbear"
    mkdir -p "$WORK_DIR/root/.ssh"
    echo "$USER_PUBKEY" > "$WORK_DIR/etc/dropbear/authorized_keys"
    echo "$USER_PUBKEY" > "$WORK_DIR/root/.ssh/authorized_keys"
    chmod 700 "$WORK_DIR/etc/dropbear" "$WORK_DIR/root/.ssh"
    chmod 600 "$WORK_DIR/etc/dropbear/authorized_keys" "$WORK_DIR/root/.ssh/authorized_keys"
else
    echo "  [i] SSH_PUBKEY nao definida: imagem sem chave SSH (login por senha)."
fi

# Patch 5: Ajustar link simbolico do /dev/ptmx para devpts
echo "  [+] Criando link simbolico /dev/ptmx -> pts/ptmx..."
rm -f "$WORK_DIR/dev/ptmx"
ln -s pts/ptmx "$WORK_DIR/dev/ptmx"

# Patch 6: S99zzzzboot_done -> O ponto de partida do SSH no boot
echo "  [+] Inserindo inicializador completo em /etc/rc.d/S99zzzzboot_done..."
sed -i '/touch \/tmp\/dut_bootdone/a \    mkdir -p /var/dropbear /dev/pts\n    rm -f /var/dropbear/fail_count\n    mount -o remount,mode=666,ptmxmode=666 /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts -o mode=666,ptmxmode=666 2>/dev/null || true\n    rm -f /dev/ptmx\n    ln -sf pts/ptmx /dev/ptmx\n    chmod 666 /dev/pts/ptmx /dev/ptmx 2>/dev/null || true\n    /usr/sbin/dropbear -p 22 -L -B &' "$WORK_DIR/etc/rc.d/S99zzzzboot_done"

# Patch 7: /etc/rc.local (backup) + correção do vazamento de dnsproxy_deamon.sh no /etc/init.d/dnsmasq
echo "  [+] Atualizando /etc/rc.local e corrigindo pgrep dnsproxy em /etc/init.d/dnsmasq..."
sed -i '/exit 0/i mkdir -p /var/dropbear\nrm -f /var/dropbear/fail_count\nmount -o remount,mode=666,ptmxmode=666 /dev/pts 2>/dev/null || true\nrm -f /dev/ptmx\nln -sf pts/ptmx /dev/ptmx\n/usr/sbin/dropbear -p 22 -L -B &\n[ -x /etc/init.d/floresta_agent ] && /etc/init.d/floresta_agent start &\n' "$WORK_DIR/etc/rc.local"
sed -i 's/pgrep "dnsproxy"/pgrep -f "dnsproxy_deamon"/g' "$WORK_DIR/etc/init.d/dnsmasq" 2>/dev/null || true

# Patch 8: Criar ponto de montagem /opt para Entware/pacotes
echo "  [+] Criando ponto de montagem /opt..."
mkdir -p "$WORK_DIR/opt"

# Patch 9: Injetar logos e favicon customizados de squashfs-root se existirem
LOGO_DIR="$SCRIPT_DIR/squashfs-root/www/webpages/assets/logo"
if [ -d "$LOGO_DIR" ]; then
    echo "  [+] Injetando logos e favicon customizados em /www/webpages/assets/logo/..."
    mkdir -p "$WORK_DIR/www/webpages/assets/logo"
    [ -f "$LOGO_DIR/brand-logo-outlined-qkjYr55g.png" ] && cp -f "$LOGO_DIR/brand-logo-outlined-qkjYr55g.png" "$WORK_DIR/www/webpages/assets/logo/"
    [ -f "$LOGO_DIR/brand-logo-default-BNCCI12k.png" ] && cp -f "$LOGO_DIR/brand-logo-default-BNCCI12k.png" "$WORK_DIR/www/webpages/assets/logo/"
    [ -f "$LOGO_DIR/favicon-BdPBwb-B.ico" ] && cp -f "$LOGO_DIR/favicon-BdPBwb-B.ico" "$WORK_DIR/www/webpages/assets/logo/"
fi

# Patch 10: Limpeza profunda e otimização de espaço (Slimming)
echo "  [+] Executando limpeza de bloatware e modulos pesados:"
# 10.1 Avira HomeShield & Sentinel
echo "      - Removendo Avira HomeShield/Sentinel..."
rm -rf "$WORK_DIR/usr/lib/avira" "$WORK_DIR/usr/bin/avira" "$WORK_DIR/etc/init.d/avira"* "$WORK_DIR/etc/rc.d/S"*avira* 2>/dev/null || true

# 10.2 DPI Engine (Ipoque PACE2)
echo "      - Removendo motor DPI / PACE2..."
rm -rf "$WORK_DIR/usr/lib/dpi" "$WORK_DIR/etc/init.d/app-dpi" "$WORK_DIR/etc/init.d/app-classifier" "$WORK_DIR/etc/rc.d/S"*app-* 2>/dev/null || true

# 10.3 Metadados do OPKG
echo "      - Removendo listas de pacotes OPKG info..."
rm -rf "$WORK_DIR/usr/lib/opkg/info" 2>/dev/null || true

# 10.4 Idiomas desnecessários (manter pt_BR)
echo "      - Removendo 25 idiomas estrangeiros do WebUI (mantendo pt_BR)..."
find "$WORK_DIR/www/webpages/locale" -mindepth 1 -maxdepth 1 ! -name "pt_BR" -exec rm -rf {} + 2>/dev/null || true

# 10.5 Zoneinfo desnecessário
echo "      - Otimizando base de fusos horarios (zoneinfo)..."
find "$WORK_DIR/usr/share/zoneinfo" -mindepth 1 -maxdepth 1 ! -name "America" ! -name "UTC" ! -name "Brazil" ! -name "zone.tab" ! -name "iso3166.tab" -exec rm -rf {} + 2>/dev/null || true

# 10.6 Tuxera NTFS & IPsec legado
echo "      - Removendo drivers Tuxera e IPsec legado..."
rm -rf "$WORK_DIR/lib/modules/tuxera-fs" "$WORK_DIR/usr/lib/ipsec" 2>/dev/null || true

# 10.7 Multimídia / Codecs DLNA ffmpeg
echo "      - Removendo codecs multimidia e servidor DLNA..."
rm -rf "$WORK_DIR/usr/lib/libavcodec"* "$WORK_DIR/usr/lib/libavformat"* "$WORK_DIR/usr/lib/libavutil"* "$WORK_DIR/usr/lib/libavdevice"* 2>/dev/null || true
rm -rf "$WORK_DIR/usr/lib/libvorbis"* "$WORK_DIR/usr/lib/libogg"* "$WORK_DIR/usr/lib/libflac"* "$WORK_DIR/usr/lib/libid3tag"* "$WORK_DIR/usr/lib/libexif"* 2>/dev/null || true
rm -rf "$WORK_DIR/usr/sbin/minidlna" "$WORK_DIR/etc/init.d/minidlna" "$WORK_DIR/etc/rc.d/S"*minidlna* 2>/dev/null || true
rm -rf "$WORK_DIR/usr/sbin/afpd" "$WORK_DIR/usr/sbin/cnid"* "$WORK_DIR/etc/init.d/afpd" "$WORK_DIR/etc/rc.d/S"*afpd* 2>/dev/null || true

# 10.8 Otimização de Ilustrações e Imagens WebUI (Substituição por 1x1 transparente)
echo "      - Otimizando ilustracoes e imagens de banners do WebUI..."
TINY_PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
TARGET_IMGS=(
    "third-vpn"
    "more-features"
    "usb-time-step"
    "ofdma"
    "mu-mimo"
    "illustration-safari"
    "illustration-google"
    "alexa"
    "google-assistant"
    "google-play"
    "app-store"
    "security-pause"
    "security-blocked"
    "unsafe-website"
    "time-up"
    "dual-nat-fix"
    "antivirus"
    "speed-test-bg"
    "splash-"
)
for PATTERN in "${TARGET_IMGS[@]}"; do
    find "$WORK_DIR/www/webpages/assets" -type f -name "*${PATTERN}*" 2>/dev/null | while read -r FILE; do
        echo "$TINY_PNG" | base64 -d > "$FILE"
    done
done

# Patch 11: Injetar htop nativo ARMEL e bibliotecas ncurses compativeis
if [ -f "$SCRIPT_DIR/htop" ]; then
    echo "  [+] Injetando htop nativo (ARMEL glibc 2.32) em /usr/bin/htop..."
    cp -f "$SCRIPT_DIR/htop" "$WORK_DIR/usr/bin/htop"
    chmod 755 "$WORK_DIR/usr/bin/htop"
    
    # Injetar bibliotecas ncurses/tinfo com symbol versioning oficial
    if [ -d "$SCRIPT_DIR/ncurses_libs" ]; then
        echo "  [+] Injetando bibliotecas libncursesw6 e libtinfo6 em /usr/lib..."
        cp -f "$SCRIPT_DIR/ncurses_libs/"*.so* "$WORK_DIR/usr/lib/" 2>/dev/null || true
    fi
    
    ln -sf libncursesw.so.6.2 "$WORK_DIR/usr/lib/libncursesw.so.6" 2>/dev/null || true
    ln -sf libtinfo.so.6.2 "$WORK_DIR/usr/lib/libtinfo.so.6" 2>/dev/null || true
    ln -sf libncursesw.so.6.2 "$WORK_DIR/usr/lib/libncurses.so.6" 2>/dev/null || true
    ln -sf libncursesw.so.6.2 "$WORK_DIR/usr/lib/libncurses.so" 2>/dev/null || true
    
    # Garantir variaveis de ambiente no /etc/profile para sessões SSH e serial
    echo "export TERMINFO=/usr/share/terminfo" >> "$WORK_DIR/etc/profile"
    echo "export TERM=xterm-256color" >> "$WORK_DIR/etc/profile"
    
    # Wrappers de compatibilidade para administradores Linux (nano, sudo, su)
    echo "  [+] Injetando wrappers de compatibilidade (nano, sudo, su)..."
    ln -sf /bin/vi "$WORK_DIR/usr/bin/nano"
    cat << 'EOF' > "$WORK_DIR/bin/sudo"
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec "$@"
EOF
    chmod +x "$WORK_DIR/bin/sudo"

    cat << 'EOF' > "$WORK_DIR/bin/su"
#!/bin/sh
if [ $# -eq 0 ] || [ "$1" = "root" ] || [ "$1" = "-" ]; then
    echo "[!] Você já está conectado como root!"
    exit 0
else
    exec "$@"
fi
EOF
    chmod +x "$WORK_DIR/bin/su"
fi

# Patch 12: Injetar Portal Captivo 3000 nativo (com Painel Admin)
CAPTIVE_SRC="$SCRIPT_DIR/captivePortal/be220_port/openwrt"
if [ -d "$CAPTIVE_SRC" ]; then
    echo "  [+] Injetando Portal Captivo 3000 + Painel Admin no RootFS..."
    mkdir -p "$WORK_DIR/etc/captiveportal" "$WORK_DIR/www/captive/admin" "$WORK_DIR/www/cgi-bin" "$WORK_DIR/usr/bin"
    cp -af "$CAPTIVE_SRC/etc/"* "$WORK_DIR/etc/" 2>/dev/null || true
    cp -af "$CAPTIVE_SRC/www/"* "$WORK_DIR/www/" 2>/dev/null || true
    cp -af "$CAPTIVE_SRC/usr/"* "$WORK_DIR/usr/" 2>/dev/null || true
    # Salvar cópia imutável fora de /etc/config (pois o loadconfig da TP-Link no S10boot executa 'rm -rf /etc/config')
    cp -f "$CAPTIVE_SRC/etc/config/captiveportal" "$WORK_DIR/etc/captiveportal/captiveportal.default" 2>/dev/null || true
    cp -f "$CAPTIVE_SRC/etc/config/floresta_cloud" "$WORK_DIR/etc/captiveportal/floresta_cloud.default" 2>/dev/null || true
    
    chmod 755 "$WORK_DIR/etc/init.d/captiveportal" 2>/dev/null || true
    chmod 755 "$WORK_DIR/usr/bin/portal_ctl" 2>/dev/null || true
    chmod 755 "$WORK_DIR/etc/captiveportal/"* 2>/dev/null || true
    chmod 755 "$WORK_DIR/www/cgi-bin/"* 2>/dev/null || true
    chmod 644 "$WORK_DIR/www/"*.html "$WORK_DIR/www/"*.txt "$WORK_DIR/www/generate_204" 2>/dev/null || true
    chmod -R a+r "$WORK_DIR/www/captive" "$WORK_DIR/www/webpages" 2>/dev/null || true
    find "$WORK_DIR/www/captive" "$WORK_DIR/www/webpages" -type d -exec chmod 755 {} + 2>/dev/null || true
    
    # Criar atalho /www/portal -> /www/captive
    ln -sf /www/captive "$WORK_DIR/www/portal" 2>/dev/null || true

    # Garantir que o dnsmasq carregue o Walled Garden dinâmico de /tmp/dnsmasq.d
    if [ -f "$WORK_DIR/etc/dnsmasq.conf" ]; then
        if ! grep -q "conf-dir=/tmp/dnsmasq.d" "$WORK_DIR/etc/dnsmasq.conf"; then
            echo "conf-dir=/tmp/dnsmasq.d" >> "$WORK_DIR/etc/dnsmasq.conf"
            echo "  [+] dnsmasq: conf-dir=/tmp/dnsmasq.d habilitado no /etc/dnsmasq.conf"
        fi
    fi

    # Garantir que uhttpd NÃO escute na 2080 (a porta 2080 é exclusiva do captive_redirector.lua)
    if [ -f "$WORK_DIR/etc/config/uhttpd" ]; then
        sed -i "/0.0.0.0:2080/d" "$WORK_DIR/etc/config/uhttpd" 2>/dev/null || true
        # Aumenta network_timeout para 15s (evita reset SSL uhttpd durante carga pesada de chunks JS)
        sed -i "s/network_timeout .*/network_timeout '15'/" "$WORK_DIR/etc/config/uhttpd" 2>/dev/null || true
        # Remove instância captive separada se existir (compatibilidade com imagens antigas)
        sed -i '/^$/N; /config uhttpd '\''captive'\''/,/^config/{ /^config uhttpd '\''captive'\''/d; /^[[:space:]]*option/d; /^[[:space:]]*list/d }' \
            "$WORK_DIR/etc/config/uhttpd" 2>/dev/null || true
    fi

    # Habilitar no boot do roteador via symlink S95 em rc.d
    mkdir -p "$WORK_DIR/etc/rc.d"
    ln -sf ../init.d/captiveportal "$WORK_DIR/etc/rc.d/S95captiveportal" 2>/dev/null || true
    echo "  [+] captiveportal habilitado no boot via S95captiveportal"

    # Habilitar Cloud Controller Agent (UniFi-style) e set-inform
    chmod 755 "$WORK_DIR/usr/bin/floresta_agent.lua" 2>/dev/null || true
    chmod 755 "$WORK_DIR/usr/bin/set-inform" 2>/dev/null || true
    chmod 755 "$WORK_DIR/etc/init.d/floresta_agent" 2>/dev/null || true
    ln -sf /usr/bin/set-inform "$WORK_DIR/usr/bin/set-controller" 2>/dev/null || true
    ln -sf ../init.d/floresta_agent "$WORK_DIR/etc/rc.d/S96floresta_agent" 2>/dev/null || true

    echo "  [+] floresta_agent habilitado no boot via S96floresta_agent"
fi

# Patch 13: Injetar Hook no Ponto de Entrada do LuCI (/www/cgi-bin/luci)
echo "  [+] Injetando hook de resolucao de MAC/ARP no /www/cgi-bin/luci..."
cat << 'EOF' > "$WORK_DIR/www/cgi-bin/luci"
#!/usr/bin/lua
require "luci.cacheloader"

local cached_router_mac = nil
local function get_router_mac()
    if cached_router_mac then return cached_router_mac end
    local mac = nil
    local gf = io.popen("/sbin/getfirm MAC 2>/dev/null")
    if gf then
        mac = gf:read("*l")
        gf:close()
        if mac and mac ~= "" and not string.find(mac, "00-0A-EB") and not string.find(mac, "00-FF-00") then
            mac = string.gsub(mac, "%s+", "")
        else
            mac = nil
        end
    end
    if not mac or mac == "" then
        local f = io.open("/sys/class/net/br-lan/address", "r")
        if f then mac = f:read("*l"); f:close() end
    end
    if not mac or mac == "" then
        local f = io.open("/proc/environment/ethaddr", "r")
        if f then mac = f:read("*l"); f:close() end
    end
    cached_router_mac = mac or "00:00:00:00:00:00"
    return cached_router_mac
end

local cached_router_ip = nil
local function get_router_ip()
    if cached_router_ip then return cached_router_ip end
    local ip = nil
    local p = io.popen("ip -4 addr show br-lan 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2")
    if p then
        ip = p:read("*l")
        p:close()
    end
    if not ip or ip == "" then
        local p2 = io.popen("uci -q get network.lan.ipaddr 2>/dev/null")
        if p2 then
            ip = p2:read("*l")
            p2:close()
        end
    end
    if not ip or ip == "" then ip = "192.168.0.1" end
    cached_router_ip = string.gsub(ip, "%s+", "")
    return cached_router_ip
end

local sys = require "luci.sys"
if sys and sys.net and sys.net.arptable then
    local orig_arptable = sys.net.arptable
    sys.net.arptable = function()
        local tbl = orig_arptable() or {}
        local r_ip = get_router_ip()
        local has_lan_ip = false
        for _, v in ipairs(tbl) do
            if v["IP address"] == r_ip then
                has_lan_ip = true
                break
            end
        end
        if not has_lan_ip then
            local mac = string.lower(string.gsub(get_router_mac(), "-", ":"))
            table.insert(tbl, {
                ["IP address"] = r_ip,
                ["HW address"] = mac,
                ["Device"] = "br-lan",
                ["Flags"] = "0x2",
                ["HW type"] = "0x1"
            })
        end
        return tbl
    end
end

pcall(function()
    local ct = require "luci.model.checktypes"
    local cm = require "luci.model.client_mgmt"
    if cm and cm.get_mac_by_ip then
        local orig_cm_get = cm.get_mac_by_ip
        cm.get_mac_by_ip = function(ip)
            local r_ip = get_router_ip()
            if ip == r_ip or ip == "127.0.0.1" then
                return string.upper(string.gsub(get_router_mac(), ":", "-"))
            end
            local res = orig_cm_get(ip)
            if not res and (ip == r_ip or ip == "127.0.0.1") then
                return string.upper(string.gsub(get_router_mac(), ":", "-"))
            end
            return res
        end
    end
end)

require "luci.sgi.cgi"
luci.dispatcher.indexcache = "/tmp/luci-indexcache"
luci.sgi.cgi.run()
EOF
chmod 755 "$WORK_DIR/www/cgi-bin/luci"

# Patch 14: Configurar administração Web para suportar HTTP por padrão
if [ -f "$WORK_DIR/etc/config/administration" ]; then
    echo "  [+] Configurando administration.local.https_enable='off'..."
    sed -i "s/option https_enable 'on'/option https_enable 'off'/" "$WORK_DIR/etc/config/administration" 2>/dev/null || true
fi

# Patch 15: Injetar fix definitivo de criptografia no WebUI (isHttps = false)
if [ -f "$SCRIPT_DIR/web_deploy/update-store-5OrO5pj1.js.gz" ]; then
    echo "  [+] Injetando patch de login HTTPS em /www/webpages/js/update-store-5OrO5pj1.js.gz..."
    cp -f "$SCRIPT_DIR/web_deploy/update-store-5OrO5pj1.js.gz" "$WORK_DIR/www/webpages/js/update-store-5OrO5pj1.js.gz"
fi

# Patch 16: Injetar Fallback Universal de Wi-Fi (wlan_remodel_reloadfiles.lua + wifix_profile.ini.1)
if [ -f "$SCRIPT_DIR/squashfs-root/etc/wlan/wlan_remodel_reloadfiles.lua" ]; then
    echo "  [+] Injetando fallback universal de modelo/regiao em /etc/wlan/wlan_remodel_reloadfiles.lua..."
    cp -f "$SCRIPT_DIR/squashfs-root/etc/wlan/wlan_remodel_reloadfiles.lua" "$WORK_DIR/etc/wlan/wlan_remodel_reloadfiles.lua"
    chmod 644 "$WORK_DIR/etc/wlan/wlan_remodel_reloadfiles.lua"
fi
if [ -f "$SCRIPT_DIR/squashfs-root/etc/wlan/wifix_profile.ini.1" ]; then
    cp -f "$SCRIPT_DIR/squashfs-root/etc/wlan/wifix_profile.ini.1" "$WORK_DIR/etc/wlan/wifix_profile.ini.1"
fi
if [ -f "$SCRIPT_DIR/squashfs-root/sbin/is_cal" ]; then
    echo "  [+] Garantindo protecao contra modo de calibracao travado em /sbin/is_cal..."
    cp -f "$SCRIPT_DIR/squashfs-root/sbin/is_cal" "$WORK_DIR/sbin/is_cal"
    chmod 755 "$WORK_DIR/sbin/is_cal"
fi

# Patch 17: Carimbo de Versao/Data da Build e comando 'versao' / 'floresta-version' / 'build-info'
BUILD_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
BUILD_ID_STAMP="$(date '+%Y%m%d-%H%M%S')"
echo "  [+] Gravando metadados da build ($BUILD_ID_STAMP) em /etc/floresta_build_info e comando 'versao'..."
cat <<EOF > "$WORK_DIR/etc/floresta_build_info"
BUILD_VERSION="2.6.0-floresta"
BUILD_DATE="$BUILD_TIMESTAMP"
BUILD_ID="$BUILD_ID_STAMP"
EOF
if [ -f "$SCRIPT_DIR/squashfs-root/usr/bin/floresta-version" ]; then
    cp -f "$SCRIPT_DIR/squashfs-root/usr/bin/floresta-version" "$WORK_DIR/usr/bin/floresta-version"
    sed -i 's/\r$//' "$WORK_DIR/usr/bin/floresta-version" 2>/dev/null || true
    chmod 755 "$WORK_DIR/usr/bin/floresta-version"
    ln -sf /usr/bin/floresta-version "$WORK_DIR/usr/bin/versao"
    ln -sf /usr/bin/floresta-version "$WORK_DIR/usr/bin/build-info"
fi
if [ -f "$WORK_DIR/etc/banner" ]; then
    echo " [Floresta Build: 77.0.1-floresta | ID: $BUILD_ID_STAMP | Data: $BUILD_TIMESTAMP]" >> "$WORK_DIR/etc/banner"
    echo " Digite 'versao' ou 'build-info' para ver detalhes do firmware e Wi-Fi." >> "$WORK_DIR/etc/banner"
    echo "" >> "$WORK_DIR/etc/banner"
fi

# Patch 16: Forçar versão de firmware 77.0.1 Build 20991231 rel.99999 e bloquear OTA oficial da TP-Link
echo "  [+] Configurando versao 77.0.1 Build 20991231 rel.99999 e bloqueio de OTA TP-Link..."
if [ -d "$WORK_DIR/etc/partition_config" ]; then
    printf 'soft_ver:77.0.1 Build 20991231 rel.99999\nfw_id:2201DC33F42936D3DC3E01E2D05EA6E2\n\n' > "$WORK_DIR/etc/partition_config/soft-version"
fi
if [ -f "$WORK_DIR/etc/config/auto_upgrade" ]; then
    sed -i "s/option enable 'on'/option enable 'off'/g" "$WORK_DIR/etc/config/auto_upgrade" 2>/dev/null || true
fi
if [ -f "$WORK_DIR/etc/hosts" ] && ! grep -q "ota-download.tplinkcloud.com" "$WORK_DIR/etc/hosts"; then
    echo "0.0.0.0 ota-download.tplinkcloud.com" >> "$WORK_DIR/etc/hosts"
fi



# 5. Recompactar com os parametros exatos do hardware Broadcom
echo "[*] Recompactando com parametros oficiais (XZ, bloco 1048576, root-owned)..."
rm -f "$OUTPUT_BIN"
mksquashfs "$WORK_DIR" "$OUTPUT_BIN" \
    -comp xz \
    -b 1048576 \
    -noappend \
    -root-owned

# Limpar diretorio temporario
rm -rf "$WORK_DIR"

# 6. Validar imagem final
FILESIZE=$(stat -c%s "$OUTPUT_BIN")
FILESIZE_HEX=$(printf "0x%x" "$FILESIZE")
SYMLINKS=$(unsquashfs -s "$OUTPUT_BIN" | grep "Number of symbolic links" | awk '{print $NF}')
INODES=$(unsquashfs -s "$OUTPUT_BIN" | grep "Number of inodes" | awk '{print $NF}')

echo ""
echo "=============================================="
echo " [OK] Sucesso na Compilação!"
echo " Arquivo gerado: $OUTPUT_BIN"
echo " Tamanho:        $FILESIZE bytes ($FILESIZE_HEX)"
echo " Limite máximo:  $MAX_SIZE bytes"
echo " Inodes:         $INODES"
echo " Symlinks:       $SYMLINKS (preservados!)"
echo "=============================================="

if [ "$FILESIZE" -gt "$MAX_SIZE" ]; then
    echo ""
    echo "[-] ATENÇÃO: A imagem gerada ($FILESIZE bytes) ULTRAPASSOU o limite ($MAX_SIZE bytes)!"
    echo "    O U-Boot irá recusar a gravação com 'size > volume size! Aborting!'."
    exit 1
fi

echo ""
echo "COMANDOS PARA O U-BOOT:"
echo "----------------------------------------------"
echo "setenv ipaddr 192.168.12.1"
echo "setenv serverip 192.168.12.2"
echo "setenv netmask 255.255.255.0"
echo "ping 192.168.12.2"
echo ""

if [ "$LAYOUT_MODE" = "EXPANDED" ]; then
    echo "# Configuração do Modo Expandido (Single-Bank ~66 MB):"
    echo "# 1. Fixar bootloader no Slot 1:"
    echo "setenv boot_image 1"
    echo "setenv committed_image 1"
    echo ""
    echo "# 2. Recriar volume rootfs1 com espaço expandido:"
    echo "ubi part image"
    echo "ubi remove rootfs2"
    echo "ubi remove rootfs1"
    echo "ubi create rootfs1 0x4000000 dynamic"
    echo ""
    echo "# 3. Baixar e gravar:"
    echo "tftpboot 0x05000000 rootfs1_mod.bin"
    echo "ubi write 0x05000000 rootfs1 $FILESIZE_HEX"
else
    echo "# Configuração do Modo Dual-Bank Padrão (33 MB):"
    echo "ubi part image"
    echo "tftpboot 0x05000000 rootfs1_mod.bin"
    echo "ubi write 0x05000000 rootfs1 $FILESIZE_HEX"
    echo "ubi write 0x05000000 rootfs2 $FILESIZE_HEX"
fi

echo "setenv bootcmd \"test_mode enable; sdk boot_img\""
echo "saveenv"
echo "reset"
echo "----------------------------------------------"
