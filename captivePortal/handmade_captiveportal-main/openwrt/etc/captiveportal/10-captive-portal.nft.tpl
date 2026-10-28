#!/usr/sbin/nft -f
# Portal Captivo 3000 — nftables rules
# OpenWrt 23+ / fw4 / inet fw4 table
#
# Este arquivo é idempotente: funciona tanto aplicado diretamente
# via `nft -f` quanto como include do fw4 (após flush ruleset).
# Usa "add" em vez de declaração inline para não conflitar com
# objetos já existentes na tabela inet fw4.
#
# Placeholders substituídos em runtime pelo /etc/init.d/captiveportal:
#   __LAN_IF__    → captiveportal.global.lan_interface  (ex: br-lan)
#   __WAN_IF__    → captiveportal.global.wan_interface  (ex: eth0.2)
#   __ROUTER_IP__ → captiveportal.global.router_ip      (ex: 192.168.1.1)

# Garante que a tabela existe (noop se fw4 já criou)
add table inet fw4

# -------------------------------------------------------------------------
# Walled Garden: IPs de domínios liberados antes do login
# -------------------------------------------------------------------------
add set inet fw4 captive_whitelist {
    type ipv4_addr
    flags dynamic, timeout
    timeout 24h
    comment "Walled Garden — IPs resolvidos (auto)"
}

# -------------------------------------------------------------------------
# Clientes Autenticados: IPs com acesso liberado após login
# -------------------------------------------------------------------------
add set inet fw4 captive_authenticated {
    type ipv4_addr
    flags dynamic, timeout
    comment "IPs autenticados com timeout de sessão"
}

# -------------------------------------------------------------------------
# Verdict Map de fwmark por Perfil
# -------------------------------------------------------------------------
add map inet fw4 captive_fwmark {
    type ipv4_addr : mark
    flags dynamic
    comment "IP autenticado → fwmark do perfil de banda"
}

# -------------------------------------------------------------------------
# Chain: Prerouting (NAT) — Redirecionamento HTTP do Portal
# -------------------------------------------------------------------------
add chain inet fw4 captive_prerouting {
    type nat hook prerouting priority dstnat - 5; policy accept;
}

flush chain inet fw4 captive_prerouting

add rule inet fw4 captive_prerouting iifname != "__LAN_IF__" return comment "Só aplica para tráfego vindo da LAN"
add rule inet fw4 captive_prerouting ip daddr __ROUTER_IP__ return comment "Roteador sempre acessível"
add rule inet fw4 captive_prerouting udp dport 53 redirect to :53 comment "Força DNS pelo dnsmasq local"
add rule inet fw4 captive_prerouting tcp dport 53 redirect to :53 comment "Força DNS pelo dnsmasq local (TCP)"
add rule inet fw4 captive_prerouting ip daddr @captive_whitelist return comment "Walled garden liberado"
add rule inet fw4 captive_prerouting ip saddr @captive_authenticated return comment "Clientes autenticados passam"
add rule inet fw4 captive_prerouting tcp dport 80 redirect to :2080 comment "Redireciona HTTP para portal"

# -------------------------------------------------------------------------
# Chain: Forward — Bloqueia tráfego de não autenticados para a WAN
# -------------------------------------------------------------------------
add chain inet fw4 captive_forward {
    type filter hook forward priority filter - 5; policy accept;
}

flush chain inet fw4 captive_forward

add rule inet fw4 captive_forward iifname != "__LAN_IF__" return comment "Só aplica LAN"
add rule inet fw4 captive_forward oifname != "__WAN_IF__" return comment "Só aplica para WAN"
add rule inet fw4 captive_forward ct state established,related accept comment "Conexões estabelecidas passam"
add rule inet fw4 captive_forward ip daddr __ROUTER_IP__ return comment "Roteador acessível"
add rule inet fw4 captive_forward ip daddr @captive_whitelist return comment "Walled garden liberado"
add rule inet fw4 captive_forward ip saddr @captive_authenticated return comment "Clientes autenticados passam"
add rule inet fw4 captive_forward drop comment "Bloqueia não autenticados"

# -------------------------------------------------------------------------
# Chain: Mangle Forward — Aplica fwmark do perfil nos pacotes autenticados
# -------------------------------------------------------------------------
add chain inet fw4 captive_mangle {
    type filter hook forward priority mangle - 5; policy accept;
}

flush chain inet fw4 captive_mangle

add rule inet fw4 captive_mangle iifname "__LAN_IF__" oifname "__WAN_IF__" ip saddr @captive_authenticated meta mark set ip saddr map @captive_fwmark comment "Aplica fwmark do perfil"
