import pexpect

child = pexpect.spawn('ssh -o StrictHostKeyChecking=no root@192.168.0.1', timeout=15, encoding='utf-8')
child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT])
child.sendline('<ROOT_PASSWORD>')
child.expect(r'#')

setup = '''
# 1. Preparar /tmp/cgi-bin com o luci ORIGINAL + scripts do portal
mkdir -p /tmp/cgi-bin
# Copiar o luci original
cp -f /www/cgi-bin/luci /tmp/cgi-bin/luci
chmod 755 /tmp/cgi-bin/luci

# Copiar scripts do portal captivo
cp -f /tmp/www_captive/../cgi-bin/* /tmp/cgi-bin/ 2>/dev/null || true
chmod 755 /tmp/cgi-bin/*

# 2. Fazer bind mount de /tmp/cgi-bin sobre /www/cgi-bin
umount /www/cgi-bin 2>/dev/null || true
mount --bind /tmp/cgi-bin /www/cgi-bin

# 3. Preparar /www/tmp/captive (que e ramfs nativo gravavel!)
mkdir -p /www/tmp/captive/admin
cp -af /tmp/www_captive/* /www/tmp/captive/ 2>/dev/null || true

# 4. Criar links para /captive e /portal se possivel, ou uhttpd alias
rm -rf /tmp/www_captive_full
mkdir -p /tmp/www_captive_full
# Copiar /www mantendo tudo
cp -af /www/* /tmp/www_captive_full/ 2>/dev/null || true
# Manter o cgi-bin completo (com luci!)
cp -af /tmp/cgi-bin/* /tmp/www_captive_full/cgi-bin/
# Adicionar pastas captive e portal
mkdir -p /tmp/www_captive_full/captive /tmp/www_captive_full/portal
cp -af /tmp/www_captive/* /tmp/www_captive_full/captive/
cp -af /tmp/www_captive/* /tmp/www_captive_full/portal/

# Montar bind do www completo sobre /www
mount --bind /tmp/www_captive_full /www

# Manter o ramfs original do /www/tmp ativo
mount --bind /tmp/www_captive_full/tmp /www/tmp 2>/dev/null || true

# Reiniciar uhttpd
/etc/init.d/uhttpd restart >/dev/null 2>&1
'''

for line in setup.strip().split('\n'):
    if line.strip() and not line.strip().startswith('#'):
        child.sendline(line.strip())
        child.expect(r'#', timeout=8)

child.sendline('ls -la /www/cgi-bin; ls -la /www/captive; ls -la /www/webpages | head -5')
child.expect(r'#', timeout=10)
print("=== CONTEUDO DE /www/cgi-bin e /www/captive ===")
print(child.before.strip())

child.sendline('exit')
child.close()
