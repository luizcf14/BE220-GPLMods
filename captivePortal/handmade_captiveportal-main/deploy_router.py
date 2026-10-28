#!/usr/bin/env python3
"""
Portal Captivo 3000 — Script de Deploy para OpenWrt 25.x
=========================================================
Instala todos os arquivos do portal captivo no roteador via SSH/SCP.

Uso:
    python deploy_router.py                # Deploy completo
    python deploy_router.py --test-only    # Apenas testa a conectividade
    python deploy_router.py --no-deploy    # Mostra o que faria, sem executar

Pré-requisitos:
    pip install paramiko
"""

import argparse
import os
import sys
import time
import stat
import json
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("❌ Dependência ausente. Execute: pip install paramiko")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configuração do roteador
# ---------------------------------------------------------------------------
ROUTER = {
    "host":     "192.168.1.1",
    "port":     22,
    "username": "root",
    "password": "",       # sem senha
    "timeout":  15,
}

# Diretório base do projeto (pasta onde este script está)
BASE_DIR = Path(__file__).parent

# ---------------------------------------------------------------------------
# Mapeamento: arquivo local → destino no roteador
# ---------------------------------------------------------------------------
FILE_MAP = [
    # nftables
    ("openwrt/etc/nftables.d/10-captive-portal.nft",
     "/etc/nftables.d/10-captive-portal.nft",           0o644),

    # Configuração UCI
    ("openwrt/etc/config/captiveportal",
     "/etc/config/captiveportal",                        0o644),

    # Serviço procd init.d
    ("openwrt/etc/init.d/captiveportal",
     "/etc/init.d/captiveportal",                        0o755),

    # CGI scripts
    ("openwrt/www/cgi-bin/portal_redirect",
     "/www/cgi-bin/portal_redirect",                     0o755),
    ("openwrt/www/cgi-bin/portal_auth",
     "/www/cgi-bin/portal_auth",                         0o755),

    # Scripts de suporte captive portal e hotplug
    ("openwrt/etc/captiveportal/refresh-whitelist.sh",
     "/etc/captiveportal/refresh-whitelist.sh",          0o755),
    ("openwrt/etc/captiveportal/renew-sessions.sh",
     "/etc/captiveportal/renew-sessions.sh",             0o755),
    ("openwrt/etc/hotplug.d/iface/99-zerotier",
     "/etc/hotplug.d/iface/99-zerotier",                 0o755),

    # CLI tool
    ("openwrt/usr/bin/portal_ctl",
     "/usr/bin/portal_ctl",                              0o755),

    # LuCI App
    ("openwrt/usr/share/rpcd/acl.d/luci-app-captiveportal.json",
     "/usr/share/rpcd/acl.d/luci-app-captiveportal.json", 0o644),
    ("openwrt/usr/share/luci/menu.d/luci-app-captiveportal.json",
     "/usr/share/luci/menu.d/luci-app-captiveportal.json", 0o644),
    ("openwrt/htdocs/luci-static/resources/view/captiveportal/config.js",
     "/htdocs/luci-static/resources/view/captiveportal/config.js", 0o644),
    ("openwrt/htdocs/luci-static/resources/view/captiveportal/whitelist.js",
     "/htdocs/luci-static/resources/view/captiveportal/whitelist.js", 0o644),
    ("openwrt/htdocs/luci-static/resources/view/captiveportal/sessions.js",
     "/htdocs/luci-static/resources/view/captiveportal/sessions.js", 0o644),

    # Frontend (portal de login do cliente)
    ("frontend/index.html",
     "/www/portal/index.html",                           0o644),
    ("frontend/style.css",
     "/www/portal/style.css",                            0o644),
    ("frontend/app.js",
     "/www/portal/app.js",                               0o644),
]

# ---------------------------------------------------------------------------
# Comandos de configuração pós-deploy
# ---------------------------------------------------------------------------
SETUP_COMMANDS = [
    # Garante que a pasta de dnsmasq.d e captiveportal existem
    "mkdir -p /etc/dnsmasq.d",
    "mkdir -p /etc/captiveportal",

    # Habilita Packet Steering por padrão para todas as CPUs (processamento de pacotes multi-core)
    "uci set network.globals.packet_steering='1' 2>/dev/null || true; "
    "uci commit network 2>/dev/null || true",

    # Instala dnsmasq-full (com suporte a nftset) substituindo o dnsmasq padrão
    "dnsmasq --version 2>&1 | grep -v 'no-nftset' | grep -q 'nftset' || "
    "((opkg update >/dev/null 2>&1 && opkg remove dnsmasq >/dev/null 2>&1 && opkg install dnsmasq-full >/dev/null 2>&1) || (apk del dnsmasq >/dev/null 2>&1 && apk add dnsmasq-full >/dev/null 2>&1) && echo 'dnsmasq-full instalado')",

    # Instala tc (Traffic Control / QoS) caso ausente
    "command -v tc >/dev/null 2>&1 || "
    "((opkg update >/dev/null 2>&1 && opkg install tc >/dev/null 2>&1) || (apk add tc >/dev/null 2>&1) && echo 'tc instalado')",

    # Instala kmod-nft-offload (Flow Offloading acelerado via kernel/hardware) caso compatível/ausente
    "(opkg list-installed 2>/dev/null | grep -q kmod-nft-offload || apk list --installed 2>/dev/null | grep -q kmod-nft-offload) || "
    "((opkg update >/dev/null 2>&1 && opkg install kmod-nft-offload >/dev/null 2>&1) || (apk add kmod-nft-offload >/dev/null 2>&1) && echo 'kmod-nft-offload instalado')",

    # Instala e Configura ZeroTier para gerenciamento remoto (com verificação rigorosa de pré-existência)
    "(command -v zerotier-one >/dev/null 2>&1 || command -v zerotier-cli >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q zerotier || apk list --installed 2>/dev/null | grep -q zerotier) || "
    "((opkg update >/dev/null 2>&1 && opkg install zerotier >/dev/null 2>&1) || (apk add zerotier >/dev/null 2>&1) && echo 'ZeroTier instalado')",

    # Ajusta UCI apenas se o ID da rede ainda não estiver configurado
    "[ \"$(uci -q get zerotier.openwrt_network.id 2>/dev/null)\" = \"633e31d8a24e21ec\" ] || ("
    "uci set zerotier.global.enabled='1' && "
    "uci delete zerotier.earth 2>/dev/null || true; "
    "uci set zerotier.openwrt_network=network && "
    "uci set zerotier.openwrt_network.id='633e31d8a24e21ec' && "
    "uci commit zerotier && "
    "/etc/init.d/zerotier enable 2>/dev/null || true && "
    "/etc/init.d/zerotier restart 2>/dev/null || true); "
    # Registra a interface zt+ na configuração de rede do OpenWrt se não existir
    "(uci show network 2>/dev/null | grep -q 'network.zerotier=interface') || ("
    "uci set network.zerotier=interface && "
    "uci set network.zerotier.device='zt+' && "
    "uci set network.zerotier.proto='none' && "
    "uci commit network && "
    "reload_config 2>/dev/null || true); "
    # Desativa udhcpc na interface de rede zerotier se o OpenWrt tiver criado como dhcp
    "[ \"$(uci -q get network.zerotier.proto 2>/dev/null)\" != \"dhcp\" ] || ("
    "uci set network.zerotier.proto='none' && "
    "uci commit network && "
    "reload_config 2>/dev/null || true); "
    # Vincula o IP retornado pelo controlador ZeroTier à interface física zt+ no kernel
    "ZT_DEV=$(zerotier-cli listnetworks 2>/dev/null | awk '/OK PRIVATE/{print $8}' | head -1); "
    "ZT_IP=$(zerotier-cli listnetworks 2>/dev/null | awk '/OK PRIVATE/{print $9}' | head -1); "
    "[ -z \"$ZT_DEV\" ] || [ -z \"$ZT_IP\" ] || [ \"$ZT_DEV\" = \"OK\" ] || ip addr add \"$ZT_IP\" dev \"$ZT_DEV\" 2>/dev/null || true",

    # Regra de Firewall: verifica se a regra Inbound UDP 9993 já existe por nome ou porta 9993
    "(uci show firewall 2>/dev/null | grep -E -q 'Allow-ZeroTier-Inbound|dest_port=.?9993') || ("
    "uci add firewall rule && "
    "uci set firewall.@rule[-1].name='Allow-ZeroTier-Inbound' && "
    "uci set firewall.@rule[-1].src='*' && "
    "uci set firewall.@rule[-1].target='ACCEPT' && "
    "uci set firewall.@rule[-1].proto='udp' && "
    "uci set firewall.@rule[-1].dest_port='9993' && "
    "uci commit firewall && "
    "/etc/init.d/firewall reload 2>/dev/null || true)",

    # Zona de Firewall ZeroTier: permite Ping, SSH, LuCI, Masquerading e Forwarding bidirecional com a LAN
    "(uci show firewall 2>/dev/null | grep -q 'firewall.zerotier=zone') || ("
    "uci set firewall.zerotier=zone && "
    "uci set firewall.zerotier.name='zerotier' && "
    "uci set firewall.zerotier.input='ACCEPT' && "
    "uci set firewall.zerotier.output='ACCEPT' && "
    "uci set firewall.zerotier.forward='ACCEPT' && "
    "uci set firewall.zerotier.masq='1' && "
    "uci set firewall.zerotier.mtu_fix='1' && "
    "uci add_list firewall.zerotier.device='zt+' 2>/dev/null || uci set firewall.zerotier.network='zerotier'; "
    "uci set firewall.zerotier_forward_lan=forwarding && "
    "uci set firewall.zerotier_forward_lan.src='zerotier' && "
    "uci set firewall.zerotier_forward_lan.dest='lan'; "
    "uci set firewall.lan_forward_zerotier=forwarding && "
    "uci set firewall.lan_forward_zerotier.src='lan' && "
    "uci set firewall.lan_forward_zerotier.dest='zerotier'; "
    "uci commit firewall && "
    "/etc/init.d/firewall reload 2>/dev/null || true)",

    # Configuração Wi-Fi: Cria/Ajusta rede Wi-Fi aberta 'Povos da Floresta 2' em 2.4GHz e 5GHz associada à br-lan
    "[ ! -f /etc/config/wireless ] || ("
    "uci delete wireless.radio0.disabled 2>/dev/null || true; "
    "uci delete wireless.radio1.disabled 2>/dev/null || true; "
    "([ ! -n \"$(uci -q get wireless.default_radio0)\" ] || ("
    "uci set wireless.default_radio0.ssid='Povos da Floresta 2' && "
    "uci set wireless.default_radio0.encryption='none' && "
    "uci set wireless.default_radio0.network='lan' && "
    "uci set wireless.default_radio0.mode='ap' && "
    "uci delete wireless.default_radio0.disabled 2>/dev/null || true)); "
    "([ ! -n \"$(uci -q get wireless.default_radio1)\" ] || ("
    "uci set wireless.default_radio1.ssid='Povos da Floresta 2' && "
    "uci set wireless.default_radio1.encryption='none' && "
    "uci set wireless.default_radio1.network='lan' && "
    "uci set wireless.default_radio1.mode='ap' && "
    "uci delete wireless.default_radio1.disabled 2>/dev/null || true)); "
    "uci commit wireless && "
    "wifi reload 2>/dev/null || wifi 2>/dev/null || true)",

    # Garante que o diretório do portal existe
    "mkdir -p /www/portal",
    "mkdir -p /htdocs/luci-static/resources/view/captiveportal",

    # Auto-detecta a interface WAN real se a configurada não existir
    "CONF_WAN=$(uci -q get captiveportal.global.wan_interface 2>/dev/null); "
    "if [ -z \"$CONF_WAN\" ] || ! ip link show \"$CONF_WAN\" >/dev/null 2>&1; then "
    "AUTO_WAN=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1); "
    "if [ -n \"$AUTO_WAN\" ]; then uci set captiveportal.global.wan_interface=\"$AUTO_WAN\"; uci commit captiveportal; echo \"WAN auto-detectada: $AUTO_WAN\"; fi; "
    "fi",

    # Configura uhttpd para escutar também na porta 2080 (portal redirect)
    "grep -q '2080' /etc/config/uhttpd || "
    "uci add_list uhttpd.main.listen_http='0.0.0.0:2080' && uci commit uhttpd",

    # Habilita serviço captiveportal no boot
    "/etc/init.d/captiveportal enable",

    # Reinicia rpcd para carregar as novas ACLs do LuCI
    "/etc/init.d/rpcd restart",

    # Reinicia uhttpd para aplicar nova porta de escuta
    "/etc/init.d/uhttpd restart",
]

# ---------------------------------------------------------------------------
# Helpers de output colorido
# ---------------------------------------------------------------------------
class C:
    RESET  = "\033[0m"
    GREEN  = "\033[32m"
    YELLOW = "\033[33m"
    RED    = "\033[31m"
    CYAN   = "\033[36m"
    BOLD   = "\033[1m"
    DIM    = "\033[2m"

def ok(msg):   print(f"  {C.GREEN}✓{C.RESET} {msg}")
def warn(msg): print(f"  {C.YELLOW}⚠{C.RESET} {msg}")
def err(msg):  print(f"  {C.RED}✗{C.RESET} {msg}")
def info(msg): print(f"  {C.CYAN}→{C.RESET} {msg}")
def step(msg): print(f"\n{C.BOLD}{msg}{C.RESET}")
def dim(msg):  print(f"  {C.DIM}{msg}{C.RESET}")

# ---------------------------------------------------------------------------
# Conexão SSH
# ---------------------------------------------------------------------------
def connect():
    step("Conectando ao roteador...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=ROUTER["host"],
            port=ROUTER["port"],
            username=ROUTER["username"],
            password=ROUTER["password"] or None,
            allow_agent=True,
            look_for_keys=True,
            timeout=ROUTER["timeout"],
        )
        ok(f"Conectado a {ROUTER['host']} como {ROUTER['username']}")
        return client
    except Exception as e:
        err(f"Falha na conexão SSH: {e}")
        sys.exit(1)

def run(client, cmd, silent=False):
    """Executa um comando SSH e retorna (stdout, stderr, exit_code)."""
    stdin, stdout, stderr = client.exec_command(cmd, timeout=30)
    out = stdout.read().decode("utf-8", errors="replace").strip()
    er  = stderr.read().decode("utf-8", errors="replace").strip()
    code = stdout.channel.recv_exit_status()
    if not silent:
        if out: dim(f"    {out[:200]}")
        if er and code != 0: dim(f"    STDERR: {er[:200]}")
    return out, er, code

# ---------------------------------------------------------------------------
# Verificação do roteador
# ---------------------------------------------------------------------------
def verify_router(client):
    step("Verificando ambiente do roteador...")

    out, _, code = run(client, "cat /etc/openwrt_release | grep DISTRIB_RELEASE")
    if code == 0:
        ok(f"OpenWrt: {out}")
    else:
        warn("Não foi possível ler a versão do OpenWrt")

    out, _, _ = run(client, "ubus call system info | grep -o '\"memory\":[^}]*}'", silent=True)
    if out:
        ok(f"Memória: {out[:80]}")

    # Verifica nft
    _, _, code = run(client, "which nft", silent=True)
    if code == 0:
        ok("nftables (nft) disponível")
    else:
        err("nft não encontrado! O sistema precisa de nftables.")
        sys.exit(1)

    # Verifica uclient-fetch
    _, _, code = run(client, "which uclient-fetch", silent=True)
    if code == 0:
        ok("uclient-fetch disponível (necessário para validar tokens Sanctum)")
    else:
        warn("uclient-fetch não encontrado — tentando instalar...")
        run(client, "apk add uclient-fetch")

    # Verifica tc
    _, _, code = run(client, "which tc", silent=True)
    if code == 0:
        ok("tc (traffic control) disponível")
    else:
        warn("tc não encontrado — tentando instalar...")
        run(client, "apk add tc")

# ---------------------------------------------------------------------------
# Deploy dos arquivos
# ---------------------------------------------------------------------------
def deploy_files(client, dry_run=False):
    step("Enviando arquivos para o roteador...")

    sftp = client.open_sftp()
    errors = []

    for local_rel, remote_path, permissions in FILE_MAP:
        local_path = BASE_DIR / local_rel
        remote_dir = str(Path(remote_path).parent)

        if not local_path.exists():
            warn(f"Arquivo local não encontrado (pulando): {local_rel}")
            continue

        if dry_run:
            info(f"[DRY-RUN] {local_rel} → {remote_path}")
            continue

        try:
            # Cria diretório remoto se necessário
            run(client, f"mkdir -p {remote_dir}", silent=True)

            # Envia arquivo
            sftp.put(str(local_path), remote_path)

            # Define permissões
            sftp.chmod(remote_path, permissions)

            ok(f"{local_rel} → {remote_path}")
        except Exception as e:
            err(f"Erro ao enviar {local_rel}: {e}")
            errors.append(local_rel)

    sftp.close()

    if errors:
        warn(f"{len(errors)} arquivo(s) com erro: {', '.join(errors)}")
    else:
        ok(f"Todos os {len(FILE_MAP)} arquivos enviados com sucesso.")

    return len(errors) == 0

# ---------------------------------------------------------------------------
# Comandos pós-deploy
# ---------------------------------------------------------------------------
def run_setup(client, dry_run=False):
    step("Executando configuração pós-deploy...")

    for cmd in SETUP_COMMANDS:
        if dry_run:
            info(f"[DRY-RUN] {cmd[:80]}...")
            continue

        info(f"Executando: {cmd[:80]}...")
        out, er, code = run(client, cmd)
        if code == 0:
            ok("OK")
        else:
            warn(f"Comando retornou código {code}")

# ---------------------------------------------------------------------------
# Inicia o serviço
# ---------------------------------------------------------------------------
def start_service(client, dry_run=False):
    step("Iniciando o serviço Portal Captivo...")

    if dry_run:
        info("[DRY-RUN] service captiveportal start")
        return

    out, er, code = run(client, "service captiveportal start 2>&1")
    if code == 0:
        ok("Serviço iniciado com sucesso!")
    else:
        warn(f"Serviço retornou código {code}. Verifique os logs: logread | grep captiveportal")

# ---------------------------------------------------------------------------
# Validações pós-deploy
# ---------------------------------------------------------------------------
def validate(client):
    step("Validando instalação...")
    passed = 0
    failed = 0

    checks = [
        ("Arquivo nftables",      "test -f /etc/nftables.d/10-captive-portal.nft"),
        ("Config UCI",            "uci show captiveportal.global.api_url"),
        ("Init.d executável",     "test -x /etc/init.d/captiveportal"),
        ("CGI portal_redirect",   "test -x /www/cgi-bin/portal_redirect"),
        ("CGI portal_auth",       "test -x /www/cgi-bin/portal_auth"),
        ("portal_ctl CLI",        "test -x /usr/bin/portal_ctl"),
        ("Frontend index.html",   "test -f /www/portal/index.html"),
        ("LuCI menu.d",           "test -f /usr/share/luci/menu.d/luci-app-captiveportal.json"),
        ("LuCI ACL",              "test -f /usr/share/rpcd/acl.d/luci-app-captiveportal.json"),
        ("uhttpd na porta 2080",  "uci show uhttpd | grep -q 2080"),
        ("dnsmasq rodando",       "pidof dnsmasq"),
    ]

    for label, cmd in checks:
        _, _, code = run(client, cmd, silent=True)
        if code == 0:
            ok(label)
            passed += 1
        else:
            err(f"{label} — FALHOU")
            failed += 1

    print()
    if failed == 0:
        print(f"  {C.GREEN}{C.BOLD}✓ Todos os {passed} testes passaram!{C.RESET}")
    else:
        print(f"  {C.YELLOW}{C.BOLD}⚠ {passed} OK, {failed} com falha.{C.RESET}")

    # Testa nftables
    out, _, code = run(client, "nft list sets inet 2>/dev/null | grep -E 'captive'", silent=True)
    if out:
        ok(f"Sets nftables registrados:\n    {out}")
    else:
        warn("Sets nftables não encontrados — o serviço pode não ter iniciado ainda.")

    return failed == 0

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Portal Captivo 3000 — Deploy para OpenWrt via SSH"
    )
    parser.add_argument("--test-only", action="store_true",
                        help="Apenas testa a conectividade SSH e o ambiente")
    parser.add_argument("--dry-run", action="store_true",
                        help="Mostra o que faria, sem executar nada no roteador")
    parser.add_argument("--no-start", action="store_true",
                        help="Não inicia o serviço após o deploy")
    parser.add_argument("--no-reboot", action="store_true",
                        help="Não reinicia o roteador ao final do deploy")
    parser.add_argument("--host", default=ROUTER["host"],
                        help=f"IP do roteador (padrão: {ROUTER['host']})")
    args = parser.parse_args()

    ROUTER["host"] = args.host

    print(f"\n{C.BOLD}{C.CYAN}═══════════════════════════════════════════{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  Portal Captivo 3000 — Deploy Script{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}═══════════════════════════════════════════{C.RESET}")
    print(f"  Roteador: {ROUTER['host']}:{ROUTER['port']}")
    print(f"  Usuário:  {ROUTER['username']}")
    if args.dry_run:
        print(f"  Modo:     {C.YELLOW}DRY-RUN (nenhuma alteração será feita){C.RESET}")

    client = connect()

    try:
        verify_router(client)

        if args.test_only:
            step("Modo --test-only: conectividade OK.")
            return

        deploy_files(client, dry_run=args.dry_run)
        run_setup(client, dry_run=args.dry_run)

        if not args.no_start:
            start_service(client, dry_run=args.dry_run)

        if not args.dry_run:
            time.sleep(2)  # Aguarda serviço iniciar
            all_ok = validate(client)

            print()
            if all_ok:
                print(f"{C.BOLD}{C.GREEN}🎉 Deploy concluído com sucesso!{C.RESET}")
                print(f"\n  Acesse o LuCI em: {C.CYAN}http://{ROUTER['host']}{C.RESET}")
                print(f"  Menu: {C.CYAN}Services → Captive Portal{C.RESET}")
                print(f"\n  Gerenciamento via CLI no roteador:")
                print(f"  {C.DIM}ssh root@{ROUTER['host']} portal_ctl status{C.RESET}")

                if not args.no_reboot:
                    step("Reiniciando o roteador para aplicar todas as alterações...")
                    run(client, "reboot", silent=True)
                    ok("Comando de reboot enviado ao roteador.")
            else:
                print(f"{C.BOLD}{C.YELLOW}⚠ Deploy com avisos. Verifique os itens acima.{C.RESET}")
                print(f"  Logs: {C.DIM}ssh root@{ROUTER['host']} logread | grep captiveportal{C.RESET}")
        else:
            print(f"\n{C.BOLD}{C.YELLOW}[DRY-RUN] Nenhuma alteração foi feita no roteador.{C.RESET}")

    finally:
        client.close()


if __name__ == "__main__":
    main()
