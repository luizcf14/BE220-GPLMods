import pexpect
import os
import sys
import time

ROUTER_IP = "192.168.0.1"
USER = "root"
PASS = "<ROOT_PASSWORD>"

BASE_DIR = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt"

print("==================================================")
print("  Deploy Portal Captivo 3000 -> Archer BE220")
print("==================================================")

# 1. Empacotar arquivos do portal em tar.gz em memoria/tmp
tar_file = "/tmp/captive_be220.tar.gz"
cmd_tar = f'tar -czf "{tar_file}" -C "{BASE_DIR}" etc www usr'
print(f"[*] Empacotando arquivos de {BASE_DIR}...")
res = os.system(cmd_tar)
if res != 0:
    print("[-] Erro ao empacotar arquivos!")
    sys.exit(1)
print(f"[+] Pacote gerado com sucesso ({os.path.getsize(tar_file)} bytes)")

# 2. Conectar via SSH e extrair na raiz do roteador
print(f"[*] Conectando em {USER}@{ROUTER_IP}...")
ssh_child = pexpect.spawn(
    f'ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no {USER}@{ROUTER_IP}',
    timeout=20, encoding='utf-8'
)

ssh_child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT])
ssh_child.sendline(PASS)
ssh_child.expect([r'#\s*$', r'\$\s*$'], timeout=10)
print("[+] Conectado com sucesso ao shell do roteador!")

# Parar servico anterior
ssh_child.sendline('/etc/init.d/captiveportal stop 2>/dev/null; true')
ssh_child.expect([r'#\s*$', r'\$\s*$'], timeout=10)

# Criar diretorios
ssh_child.sendline('mkdir -p /etc/captiveportal /www/cgi-bin /www/captive/admin /tmp/dnsmasq.d /usr/bin')
ssh_child.expect([r'#\s*$', r'\$\s*$'], timeout=10)

# 3. Enviar arquivo via SCP com pexpect
print("[*] Enviando pacote via SCP...")
scp_child = pexpect.spawn(
    f'scp -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no "{tar_file}" {USER}@{ROUTER_IP}:/tmp/captive_be220.tar.gz',
    timeout=30, encoding='utf-8'
)
scp_child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT])
scp_child.sendline(PASS)
scp_child.expect(pexpect.EOF, timeout=30)
print("[+] Arquivo transferido para /tmp/captive_be220.tar.gz")

# 4. Extrair e dar permissoes
print("[*] Extraindo e configurando permissoes...")
setup_cmds = [
    "tar -xzf /tmp/captive_be220.tar.gz -C /",
    "chmod 755 /etc/init.d/captiveportal",
    "chmod 755 /usr/bin/portal_ctl",
    "chmod 755 /etc/captiveportal/*.sh",
    "chmod 755 /www/cgi-bin/portal_* /www/cgi-bin/captive_*",
    "ln -sf /www/captive /www/portal 2>/dev/null || true",
    "rm -f /tmp/captive_be220.tar.gz",
    
    # Configurar uhttpd porta 2080
    "uci delete uhttpd.captive 2>/dev/null || true",
    "uci set uhttpd.captive=uhttpd",
    "uci set uhttpd.captive.listen_http='0.0.0.0:2080'",
    "uci set uhttpd.captive.home='/www'",
    "uci set uhttpd.captive.cgi_prefix='/cgi-bin'",
    "uci set uhttpd.captive.script_timeout='60'",
    "uci set uhttpd.captive.network_timeout='30'",
    "uci set uhttpd.captive.tcp_keepalive='1'",
    "uci set uhttpd.captive.no_dirlists='1'",
    "uci set uhttpd.captive.error_page='/cgi-bin/portal_redirect'",
    "uci commit uhttpd",
    "/etc/init.d/uhttpd restart >/dev/null 2>&1",
    
    # Iniciar servico
    "/etc/init.d/captiveportal start"
]

for cmd in setup_cmds:
    ssh_child.sendline(cmd)
    ssh_child.expect([r'#\s*$', r'\$\s*$'], timeout=15)

print("[+] Arquivos instalados e servico iniciado!")

# 5. Checar status
ssh_child.sendline('portal_ctl status')
ssh_child.expect([r'#\s*$', r'\$\s*$'], timeout=15)
print("\n" + ssh_child.before.strip())

ssh_child.sendline('exit')
ssh_child.close()
print("\n[OK] Deploy finalizado com sucesso!")
