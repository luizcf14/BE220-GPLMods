#!/bin/sh
# Portal Captivo 3000 — Refresh de Whitelist
# /etc/captiveportal/refresh-whitelist.sh
#
# Executado pelo cron a cada 2 minutos.
# Resolve os domínios do walled garden via DNS e atualiza o set
# captive_whitelist do nftables com os IPs retornados.
#
# Necessário porque CDNs (Cloudflare, AWS, etc.) rotacionam IPs,
# e a resolução feita no startup pode ficar desatualizada.
# O nftset= do dnsmasq-full faz isso automaticamente, mas quando
# apenas o dnsmasq padrão está instalado, este script substitui.

# Só roda se o set existir (portal ativo)
nft list set inet fw4 captive_whitelist > /dev/null 2>&1 || exit 0

_whitelist_domain() {
	local domain="$1"
	[ -z "$domain" ] && return

	local ips
	ips=$(nslookup "$domain" 2>/dev/null \
		| awk '/^Address: / {print $2}' \
		| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

	for ip in $ips; do
		# timeout 10m: se o cron roda a cada 2min, os IPs ficam sempre frescos.
		# CDNs que rodam IPs continuam liberados, IPs antigos expiram sozinhos.
		nft add element inet fw4 captive_whitelist "{ $ip timeout 10m }" 2>/dev/null || true
	done
}

# Lê domínios do walled garden via UCI
. /lib/functions.sh
config_load captiveportal

config_list_foreach walled_garden domain _whitelist_domain

# API URL (sempre libera o backend)
API_URL=$(uci -q get captiveportal.global.api_url)
if [ -n "$API_URL" ]; then
	api_host=$(echo "$API_URL" | sed 's|https\?://||; s|/.*||; s|:.*||')
	[ -n "$api_host" ] && _whitelist_domain "$api_host"
fi
