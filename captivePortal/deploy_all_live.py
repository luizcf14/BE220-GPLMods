import os
import subprocess
import sys

SOURCE_BASE = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt"

def run_ssh(cmd):
    full_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "root@192.168.0.1", "sh"
    ]
    res = subprocess.run(full_cmd, input=cmd, capture_output=True, text=True)
    return res.stdout, res.stderr, res.returncode

def scp(local_rel, remote_path):
    local_path = os.path.join(SOURCE_BASE, local_rel)
    cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "scp", "-O", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        local_path, f"root@192.168.0.1:{remote_path}"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode

def main():
    print("=== 1. PREPARANDO PASTAS E BIND MOUNTS EM RAM NO ROTEADOR ===")
    prep_script = """
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

mkdir -p /tmp/cgi-bin /tmp/captive /tmp/webpages_js /tmp/webpages_locale_pt_BR /tmp/cp_upload
mkdir -p /etc/config /etc/captiveportal /tmp/dnsmasq.d

# Se /www/cgi-bin nao estiver em RAM, copia e monta
if ! grep -q "/www/cgi-bin " /proc/mounts; then
    cp -a /www/cgi-bin/* /tmp/cgi-bin/ 2>/dev/null || true
    mount --bind /tmp/cgi-bin /www/cgi-bin
fi

# Se /www/captive nao estiver em RAM, copia e monta
if ! grep -q "/www/captive " /proc/mounts; then
    cp -a /www/captive/* /tmp/captive/ 2>/dev/null || true
    mount --bind /tmp/captive /www/captive
fi

# Se /www/webpages/js nao estiver em RAM, copia e monta
if ! grep -q "/www/webpages/js " /proc/mounts; then
    cp -a /www/webpages/js/* /tmp/webpages_js/ 2>/dev/null || true
    mount --bind /tmp/webpages_js /www/webpages/js
fi

# Se /www/webpages/locale/pt_BR nao estiver em RAM, copia e monta
if ! grep -q "/www/webpages/locale/pt_BR " /proc/mounts; then
    cp -a /www/webpages/locale/pt_BR/* /tmp/webpages_locale_pt_BR/ 2>/dev/null || true
    mount --bind /tmp/webpages_locale_pt_BR /www/webpages/locale/pt_BR
fi

echo "MOUNTS_READY"
"""
    out, err, code = run_ssh(prep_script)
    print(out.strip())

    print("\n=== 2. ENVIANDO TODOS OS ARQUIVOS ATUALIZADOS ===")
    files = [
        # /etc
        ("etc/config/captiveportal", "/etc/config/captiveportal", "644"),
        ("etc/init.d/captiveportal", "/etc/init.d/captiveportal", "755"),
        ("etc/captiveportal/captive_redirector.lua", "/etc/captiveportal/captive_redirector.lua", "755"),
        ("etc/captiveportal/refresh-whitelist.sh", "/etc/captiveportal/refresh-whitelist.sh", "755"),
        ("etc/captiveportal/renew-sessions.sh", "/etc/captiveportal/renew-sessions.sh", "755"),
        
        # /www/cgi-bin (montado em RAM)
        ("www/cgi-bin/portal_auth", "/www/cgi-bin/portal_auth", "755"),
        ("www/cgi-bin/captive_admin_api", "/www/cgi-bin/captive_admin_api", "755"),
        ("www/cgi-bin/captive_portal_api", "/www/cgi-bin/captive_portal_api", "755"),
        ("www/cgi-bin/portal_redirect", "/www/cgi-bin/portal_redirect", "755"),
        
        # /www/captive (montado em RAM)
        ("www/captive/app.js", "/www/captive/app.js", "644"),
        
        # /www/webpages (montado em RAM)
        ("www/webpages/js/index-ESh8tgBq.js", "/www/webpages/js/index-ESh8tgBq.js", "644"),
        ("www/webpages/js/index-ESh8tgBq.js.gz", "/www/webpages/js/index-ESh8tgBq.js.gz", "644"),
        ("www/webpages/js/index-1YOMGISy.js", "/www/webpages/js/index-1YOMGISy.js", "644"),
        ("www/webpages/js/index-captivePortal.js", "/www/webpages/js/index-captivePortal.js", "644"),
        ("www/webpages/js/index-captivePortal.js.gz", "/www/webpages/js/index-captivePortal.js.gz", "644"),
        ("www/webpages/js/update-store-5OrO5pj1.js", "/www/webpages/js/update-store-5OrO5pj1.js", "644"),
        ("www/webpages/js/update-store-5OrO5pj1.js.gz", "/www/webpages/js/update-store-5OrO5pj1.js.gz", "644"),
        ("www/webpages/locale/pt_BR/index-DRzNdMg6.js.gz", "/www/webpages/locale/pt_BR/index-DRzNdMg6.js.gz", "644"),
    ]

    for rel, remote, mode in files:
        tmp_dst = f"/tmp/cp_upload/{os.path.basename(remote)}"
        rc = scp(rel, tmp_dst)
        if rc == 0:
            run_ssh(f"cp -f {tmp_dst} {remote} && chmod {mode} {remote}")
            print(f"  [OK] {rel} -> {remote}")
        else:
            print(f"  [ERR] {rel}")

    print("\n=== 3. INICIANDO O SERVICO DO PORTAL E CONFIGURACOES ===")
    start_script = """
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

# Habilita link no boot
ln -sf ../init.d/captiveportal /etc/rc.d/S95captiveportal 2>/dev/null || true

# Configura dnsmasq
if ! grep -q "conf-dir=/tmp/dnsmasq.d" /etc/dnsmasq.conf; then
    echo "conf-dir=/tmp/dnsmasq.d" >> /etc/dnsmasq.conf
fi

# Inicializa persistência em /data e /user_data1 (UBIFS NAND)
mkdir -p /data/captiveportal /user_data1/captiveportal 2>/dev/null || true
if [ -s /etc/config/captiveportal ] && [ ! -s /data/captiveportal/captiveportal ]; then
    cp -f /etc/config/captiveportal /data/captiveportal/captiveportal 2>/dev/null || true
    cp -f /etc/config/captiveportal /user_data1/captiveportal/captiveportal 2>/dev/null || true
    sync 2>/dev/null || true
fi

# Libera porta 2080 do uhttpd
uci delete uhttpd.captive 2>/dev/null || true
uci del_list uhttpd.main.listen_http='0.0.0.0:2080' 2>/dev/null || true
uci commit uhttpd 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# Inicia o portal captivo
/etc/init.d/captiveportal stop >/dev/null 2>&1 || true
sleep 1
/etc/init.d/captiveportal start

# Reinicia dnsmasq
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

# Executa primeira checagem de whitelist
/etc/captiveportal/refresh-whitelist.sh >/dev/null 2>&1 &

echo "SERVICO_ATIVO"
"""
    out2, err2, code2 = run_ssh(start_script)
    print("Resultado:", out2.strip())
    print("\n=== DEPLOY COMPLETO CONCLUIDO ===")

if __name__ == "__main__":
    main()
