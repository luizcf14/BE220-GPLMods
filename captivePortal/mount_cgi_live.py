import subprocess
import os

SOURCE_BASE = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt"

def run_cmd(cmd):
    full_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "root@192.168.0.1", "sh"
    ]
    res = subprocess.run(full_cmd, input=cmd, capture_output=True, text=True)
    return res.stdout, res.stderr, res.returncode

def upload_to_tmp(local_rel, tmp_dest, mode):
    local_path = os.path.join(SOURCE_BASE, local_rel)
    with open(local_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    script = f"""
cat << 'FILE_EOF' > {tmp_dest}
{content}
FILE_EOF
chmod {mode} {tmp_dest}
"""
    run_cmd(script)

print("=== CRIANDO /tmp/cgi-bin E APLICANDO BIND MOUNT ===")

setup_cgi = """
mkdir -p /tmp/cgi-bin
# Copia tudo que ja esta em /www/cgi-bin (incluindo luci original)
cp -af /www/cgi-bin/* /tmp/cgi-bin/
"""
run_cmd(setup_cgi)

# Agora envia as versoes atualizadas de captive_portal_api e portal_redirect
upload_to_tmp("www/cgi-bin/captive_portal_api", "/tmp/cgi-bin/captive_portal_api", "755")
upload_to_tmp("www/cgi-bin/portal_redirect", "/tmp/cgi-bin/portal_redirect", "755")

# Monta bind de /tmp/cgi-bin sobre /www/cgi-bin
mount_cmd = """
umount /www/cgi-bin 2>/dev/null || true
mount --bind /tmp/cgi-bin /www/cgi-bin
echo "BIND MOUNT CGI-BIN: OK"
"""
out, err, code = run_cmd(mount_cmd)
print("STDOUT:", out)

# Testar chamada ao captive_portal_api
test_cmd = """
REQUEST_METHOD=GET REMOTE_ADDR=192.168.0.50 /www/cgi-bin/captive_portal_api
"""
out, err, code = run_cmd(test_cmd)
print("\n=== RESPOSTA DA CAPPORT API ===")
print(out)
