import pexpect
import os
import sys
import time

ROUTER_IP = "192.168.0.1"
USER = "root"
PASS = "<ROOT_PASSWORD>"

BASE_DIR = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt"

print("================================================================")
print("  Subindo Portal Captivo 3000 em Memória RAM (Live Test)")
print("  Roteador: TP-Link Archer BE220 (192.168.0.1)")
print("================================================================")

# 1. Empacotar arquivos
tar_file = "/tmp/captive_live_full.tar.gz"
print(f"[*] Empacotando arquivos de {BASE_DIR}...")
os.system(f'tar -czf "{tar_file}" -C "{BASE_DIR}" etc www usr')
print(f"[+] Pacote gerado ({os.path.getsize(tar_file)} bytes)")

# 2. Enviar via SCP
print(f"[*] Enviando pacote para o roteador via SCP...")
scp_child = pexpect.spawn(
    f'scp -o StrictHostKeyChecking=no -o PasswordAuthentication=yes "{tar_file}" {USER}@{ROUTER_IP}:/tmp/captive_live_full.tar.gz',
    timeout=20, encoding='utf-8'
)
scp_child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT])
scp_child.sendline(PASS)
scp_child.expect(pexpect.EOF, timeout=20)
print("[+] Arquivo transferido com sucesso!")

# 3. SSH para configurar e iniciar
print("[*] Conectando via SSH para montar em RAM e iniciar os serviços...")
ssh_child = pexpect.spawn(f'ssh -o StrictHostKeyChecking=no {USER}@{ROUTER_IP}', timeout=15, encoding='utf-8')
ssh_child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT])
ssh_child.sendline(PASS)
ssh_child.expect(r'#')

setup_cmds = [
    # Criar pastas na RAM
    "mkdir -p /tmp/captive_ext /tmp/www_captive/admin /tmp/cgi-bin /tmp/bin /etc/captiveportal /tmp/dnsmasq.d",
    "tar -xzf /tmp/captive_live_full.tar.gz -C /tmp/captive_ext",
    
    # Copiar /etc (ramfs nativo gravavel)
    "cp -af /tmp/captive_ext/etc/* /etc/ 2>/dev/null || true",
    
    # Copiar arquivos do frontend e admin para a RAM
    "cp -af /tmp/captive_ext/www/captive/* /tmp/www_captive/ 2>/dev/null || true",
    "cp -af /tmp/captive_ext/www/cgi-bin/* /tmp/cgi-bin/ 2>/dev/null || true",
    
    # Criar pontos de montagem e montar binds sobre /www
    "mkdir -p /www/captive /www/cgi-bin",
    "umount /www/captive 2>/dev/null || true",
    "umount /www/cgi-bin 2>/dev/null || true",
    "mount --bind /tmp/www_captive /www/captive",
    "mount --bind /tmp/cgi-bin /www/cgi-bin",
    "ln -sf /tmp/www_captive /www/portal 2>/dev/null || true",
    
    # Colocar portal_ctl no PATH
    "cp -f /tmp/captive_ext/usr/bin/portal_ctl /tmp/bin/portal_ctl",
    "cp -f /tmp/captive_ext/usr/bin/portal_ctl /bin/portal_ctl 2>/dev/null || true",
    "chmod 755 /tmp/bin/portal_ctl /tmp/cgi-bin/* /etc/captiveportal/*.sh /etc/init.d/captiveportal",
    "export PATH=/tmp/bin:$PATH",
    
    # Configurar uhttpd para escutar na 2080
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
    
    # Reiniciar serviço captiveportal
    "/etc/init.d/captiveportal stop 2>/dev/null || true",
    "/etc/init.d/captiveportal start",
    
    # Limpar pacote temporario
    "rm -rf /tmp/captive_ext /tmp/captive_live_full.tar.gz"
]

for cmd in setup_cmds:
    ssh_child.sendline(cmd)
    ssh_child.expect(r'#', timeout=12)

print("[+] Serviços configurados e ativos!")

# 4. Status final
ssh_child.sendline('/tmp/bin/portal_ctl status')
ssh_child.expect(r'#', timeout=10)
print("\n" + ssh_child.before.strip())

ssh_child.sendline('exit')
ssh_child.close()

print("\n================================================================")
print("  PRONTO PARA TESTAR NO NAVEGADOR!")
print("  1. Painel Admin:   http://192.168.0.1/captive/admin/")
print("  2. Tela de Login:  http://192.168.0.1/captive/")
print("================================================================")
