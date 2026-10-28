import os
import subprocess
import sys
import datetime

LOCAL_WEB = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt/www/webpages"
LOG_FILE = os.path.join(os.path.dirname(__file__), "router_commands.log")

def log(msg):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{now}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as lf:
            lf.write(line + "\n")
    except Exception:
        pass

def run_ssh(cmd):
    full_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "root@192.168.0.1", "sh"
    ]
    res = subprocess.run(full_cmd, input=cmd, capture_output=True, text=True)
    return res.stdout, res.stderr, res.returncode

def main():
    log("=== INICIANDO DEPLOY DA INTERFACE CAPTIVE PORTAL NO PAINEL TP-LINK ===")

    # 1. Cria diretório temporário no roteador
    out, err, code = run_ssh("mkdir -p /tmp/cp_web_update/js /tmp/cp_web_update/locale/pt_BR")
    if code != 0:
        log(f"Erro ao criar /tmp/cp_web_update: {err}")
        sys.exit(1)

    # 2. Upload dos arquivos via scp
    files = [
        ("js/update-store-5OrO5pj1.js.gz", "/tmp/cp_web_update/js/update-store-5OrO5pj1.js.gz"),
        ("js/index-ESh8tgBq.js.gz", "/tmp/cp_web_update/js/index-ESh8tgBq.js.gz"),
        ("js/index-captivePortal.js", "/tmp/cp_web_update/js/index-captivePortal.js"),
        ("js/index-captivePortal.js.gz", "/tmp/cp_web_update/js/index-captivePortal.js.gz"),
        ("locale/pt_BR/index-DRzNdMg6.js.gz", "/tmp/cp_web_update/locale/pt_BR/index-DRzNdMg6.js.gz"),
    ]

    for rel_src, dst in files:
        src = f"{LOCAL_WEB}/{rel_src}"
        scp_cmd = [
            "sshpass", "-p", "<ROOT_PASSWORD>",
            "scp", "-O", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            src, f"root@192.168.0.1:{dst}"
        ]
        res = subprocess.run(scp_cmd, capture_output=True, text=True)
        if res.returncode != 0:
            log(f"Erro no upload de {rel_src}: {res.stderr}")
            sys.exit(1)
        log(f"[OK] Upload {rel_src} -> {dst}")

    # 3. Executa montagem em RAM (overlay) e ativação no roteador
    activate_script = """
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

echo "[*] Preparando pastas em RAM..."
mkdir -p /tmp/webpages_js /tmp/webpages_locale_pt_BR

# Se ainda nao estiver montado, copia os originais
if ! grep -q "/tmp/webpages_js" /proc/mounts; then
    echo "[*] Copiando arquivos originais para RAM..."
    cp -a /www/webpages/js/* /tmp/webpages_js/ 2>/dev/null || true
fi

if ! grep -q "/tmp/webpages_locale_pt_BR" /proc/mounts; then
    cp -a /www/webpages/locale/pt_BR/* /tmp/webpages_locale_pt_BR/ 2>/dev/null || true
fi

echo "[*] Aplicando arquivos atualizados..."
cp -f /tmp/cp_web_update/js/* /tmp/webpages_js/
cp -f /tmp/cp_web_update/locale/pt_BR/* /tmp/webpages_locale_pt_BR/

# Monta sobre /www/webpages se ainda nao montado
if ! grep -q "/www/webpages/js " /proc/mounts; then
    mount --bind /tmp/webpages_js /www/webpages/js
fi

if ! grep -q "/www/webpages/locale/pt_BR " /proc/mounts; then
    mount --bind /tmp/webpages_locale_pt_BR /www/webpages/locale/pt_BR
fi

echo "[*] Reiniciando uhttpd..."
/etc/init.d/uhttpd restart

echo "DEPLOY_WEBPAGES_SUCCESS"
"""

    out, err, code = run_ssh(activate_script)
    log(f"Resultado ativação:\n{out}")
    if "DEPLOY_WEBPAGES_SUCCESS" in out:
        log("=== DEPLOY DA INTERFACE CONCLUÍDO COM SUCESSO! ===")
    else:
        log(f"Falha na ativação: {err}")

if __name__ == "__main__":
    main()
