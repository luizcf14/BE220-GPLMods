import subprocess

script = """
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

echo "=== 1. REDIRECTOR LUA PROCESS ==="
ps | grep captive_redirector

echo "=== 2. LISTENING PORTS (2080, 80, 443) ==="
netstat -tlpn | grep -E "2080|80|443"

echo "=== 3. DNS RESOLUTION ==="
nslookup roteador.conexaopovosdafloresta.org.br 127.0.0.1

echo "=== 4. DHCP OPTION 114 IN WHITELIST ==="
cat /tmp/dnsmasq.d/captive-whitelist.conf

echo "=== 5. CAPPORT API RFC 8908 (LOCAL) ==="
REQUEST_METHOD=GET REMOTE_ADDR=192.168.0.50 /www/cgi-bin/captive_portal_api
"""

full_cmd = [
    "sshpass", "-p", "<ROOT_PASSWORD>",
    "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
    "root@192.168.0.1", "sh"
]

res = subprocess.run(full_cmd, input=script, capture_output=True, text=True)
print("STDOUT:\n" + res.stdout)
if res.stderr:
    print("STDERR:\n" + res.stderr)
