#!/bin/sh
# Portal Captivo 3000 — Refresh Whitelist (BE220 Port — iptables)
# /etc/captiveportal/refresh-whitelist.sh
# Resolve domínios do walled garden e adiciona IPs nas chains iptables

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

# Verifica se o portal captivo está ativo
iptables -C FORWARD -j CAPTIVE_FORWARD >/dev/null 2>&1 || exit 0

_whitelist_ip() {
	local ip="$1"
	[ -z "$ip" ] && return
	# Adiciona na chain NAT CAPTIVE_WARDEN (evita REDIRECT)
	iptables -t nat -C CAPTIVE_WARDEN -d "$ip" -j ACCEPT >/dev/null 2>&1 || \
		iptables -t nat -A CAPTIVE_WARDEN -d "$ip" -j ACCEPT
	# Adiciona na chain FILTER CAPTIVE_WARDEN_FWD (permite tráfego WAN)
	iptables -C CAPTIVE_WARDEN_FWD -d "$ip" -j ACCEPT >/dev/null 2>&1 || \
		iptables -A CAPTIVE_WARDEN_FWD -d "$ip" -j ACCEPT
}

_whitelist_domain() {
	local domain="$1"
	[ -z "$domain" ] && return
	domain=$(echo "$domain" | sed 's/^\*\.//')

	# Se for endereço IPv4 direto (ex: IP do roteador), libera diretamente sem nslookup
	if echo "$domain" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
		_whitelist_ip "$domain"
		logger -t captive_whitelist "IP liberado direto: $domain"
		return
	fi

	# Extrai IPs reais da resposta do nslookup do BusyBox
	local ips
	ips=$(nslookup "$domain" 2>/dev/null | sed -e '1,/Name:/d' -n -e 's/^Address [0-9]*: \([0-9.]*\).*/\1/p')

	for ip in $ips; do
		_whitelist_ip "$ip"
		logger -t captive_whitelist "IP liberado: $domain -> $ip"
	done
}

. /lib/functions.sh
config_load captiveportal

# Domínios e IPs configurados no UCI
config_list_foreach walled_garden domain _whitelist_domain

# Host da api_url configurada
API_URL=$(uci -q get captiveportal.global.api_url)
if [ -n "$API_URL" ]; then
	api_host=$(echo "$API_URL" | sed 's|https\?://||; s|/.*||; s|:.*||')
	[ -n "$api_host" ] && _whitelist_domain "$api_host"
fi

# Garante especificamente os domínios essenciais de autenticação
_whitelist_domain "apidev.conexaopovosdafloresta.org.br"
_whitelist_domain "conexaopovosdafloresta.org.br"
_whitelist_domain "api.conexaopovosdafloresta.org.br"
_whitelist_domain "example.com"
_whitelist_domain "portal.example.com"
_whitelist_domain "www.example.com"

# Garante SEMPRE o IP ativo do roteador (e IPs conhecidos) como exceção no portal captivo
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
[ -z "$LAN_IP" ] && LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null)
[ -n "$LAN_IP" ] && _whitelist_ip "$LAN_IP"
_whitelist_ip "192.168.0.1"
_whitelist_ip "192.168.12.1"
_whitelist_ip "127.0.0.1"
for lip in $(ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1); do
	_whitelist_ip "$lip"
done
