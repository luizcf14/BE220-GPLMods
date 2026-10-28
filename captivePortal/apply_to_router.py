import subprocess
import os

SOURCE_BASE = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt"

files_to_upload = [
    # Configs
    ("etc/config/captiveportal", "/etc/config/captiveportal", "644"),
    ("etc/init.d/captiveportal", "/etc/init.d/captiveportal", "755"),
    
    # Scripts do Captive Portal
    ("etc/captiveportal/captive_redirector.lua", "/etc/captiveportal/captive_redirector.lua", "755"),
    ("etc/captiveportal/refresh-whitelist.sh", "/etc/captiveportal/refresh-whitelist.sh", "755"),
    ("etc/captiveportal/renew-sessions.sh", "/etc/captiveportal/renew-sessions.sh", "755"),
    
    # CGIs de Autenticação e APIs
    ("www/cgi-bin/portal_auth", "/www/cgi-bin/portal_auth", "755"),
    ("www/cgi-bin/captive_admin_api", "/www/cgi-bin/captive_admin_api", "755"),
    ("www/cgi-bin/captive_portal_api", "/www/cgi-bin/captive_portal_api", "755"),
    ("www/cgi-bin/portal_redirect", "/www/cgi-bin/portal_redirect", "755"),
    
    # Frontend do Portal Captivo (/captive)
    ("www/captive/app.js", "/www/captive/app.js", "644"),
    
    # Frontend do Painel TP-Link (/webpages/js)
    ("www/webpages/js/index-captivePortal.js", "/www/webpages/js/index-captivePortal.js", "644"),
    ("www/webpages/js/index-captivePortal.js.gz", "/www/webpages/js/index-captivePortal.js.gz", "644"),
    ("www/webpages/js/update-store-5OrO5pj1.js", "/www/webpages/js/update-store-5OrO5pj1.js", "644"),
    ("www/webpages/js/update-store-5OrO5pj1.js.gz", "/www/webpages/js/update-store-5OrO5pj1.js.gz", "644"),
]

def run_cmd(cmd):
    full_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "root@192.168.0.1", "sh"
    ]
    res = subprocess.run(full_cmd, input=cmd, capture_output=True, text=True)
    return res.stdout, res.stderr, res.returncode

def scp_file(local_rel, remote_path, mode):
    local_path = os.path.join(SOURCE_BASE, local_rel)
    scp_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "scp", "-O", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        local_path, f"root@192.168.0.1:{remote_path}"
    ]
    res = subprocess.run(scp_cmd, capture_output=True, text=True)
    if res.returncode == 0:
        run_cmd(f"chmod {mode} {remote_path}")
        print(f"  [OK] {local_rel} -> {remote_path}")
    else:
        print(f"  [ERR] {local_rel}: {res.stderr}")

print("=== 1. CRIANDO DIRETORIOS NECESSARIOS NO ROTEADOR ===")
run_cmd("mkdir -p /etc/config /etc/captiveportal /etc/rc.d /www/cgi-bin /www/captive /www/webpages/js /tmp/dnsmasq.d")

print("\n=== 2. SINCRONIZANDO ARQUIVOS COMPLETOS DO PORTAL CAPTIVO ===")
for local_rel, remote_path, mode in files_to_upload:
    scp_file(local_rel, remote_path, mode)

print("\n=== 3. CONFIGURANDO SERVICOS E INICIANDO O PORTAL ===")
setup_script = """
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

# Habilita no boot
ln -sf ../init.d/captiveportal /etc/rc.d/S95captiveportal 2>/dev/null || true

# Configura dnsmasq
if ! grep -q "conf-dir=/tmp/dnsmasq.d" /etc/dnsmasq.conf; then
    echo "conf-dir=/tmp/dnsmasq.d" >> /etc/dnsmasq.conf
fi

# Libera porta 2080 do uhttpd
uci delete uhttpd.captive 2>/dev/null || true
uci del_list uhttpd.main.listen_http='0.0.0.0:2080' 2>/dev/null || true
uci commit uhttpd 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# Reinicia servico captiveportal
/etc/init.d/captiveportal stop >/dev/null 2>&1 || true
sleep 1
/etc/init.d/captiveportal start

# Reinicia dnsmasq
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

echo "DEPLOY_CONCLUIDO"
"""
out, err, code = run_cmd(setup_script)
print("Resultado:", out.strip())
