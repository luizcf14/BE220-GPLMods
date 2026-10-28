#!/bin/sh
# Portal Captivo 3000 — Renovação de Sessões (BE220 Port — iptables)
# /etc/captiveportal/renew-sessions.sh
#
# Executa a cada 5 minutos via cron.
# Para clientes conectados e ativos: renova o prazo automaticamente.
# Para clientes desconectados cujo tempo expirou: remove do firewall.

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:$PATH

SESSIONS_FILE="/tmp/captiveportal_sessions.json"

[ ! -f "$SESSIONS_FILE" ] && exit 0

SESSION_TIME=$(uci -q get captiveportal.global.session_time 2>/dev/null || echo 3600)
NOW=$(date +%s)

CONTENT=$(cat "$SESSIONS_FILE" 2>/dev/null)
[ -z "$CONTENT" ] || [ "$CONTENT" = '{"sessions":[]}' ] && exit 0

NEW_SESSIONS=""
COUNT_RENEWED=0
COUNT_EXPIRED=0

IPS=$(printf '%s' "$CONTENT" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | sort -u)

for IP in $IPS; do
	[ -z "$IP" ] && continue

	MAC=$(printf '%s' "$CONTENT"     | sed -n 's/.*"ip":"'"$IP"'".*"mac":"\([^"]*\)".*/\1/p' | head -1)
	USER=$(printf '%s' "$CONTENT"    | sed -n 's/.*"ip":"'"$IP"'".*"user":"\([^"]*\)".*/\1/p' | head -1)
	EMAIL=$(printf '%s' "$CONTENT"   | sed -n 's/.*"ip":"'"$IP"'".*"email":"\([^"]*\)".*/\1/p' | head -1)
	PROFILE=$(printf '%s' "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"profile":"\([^"]*\)".*/\1/p' | head -1)
	FWMARK=$(printf '%s' "$CONTENT"  | sed -n 's/.*"ip":"'"$IP"'".*"fwmark":\([0-9]*\).*/\1/p' | head -1)
	DL=$(printf '%s' "$CONTENT"      | sed -n 's/.*"ip":"'"$IP"'".*"dl_kbit":\([0-9]*\).*/\1/p' | head -1)
	UL=$(printf '%s' "$CONTENT"      | sed -n 's/.*"ip":"'"$IP"'".*"ul_kbit":\([0-9]*\).*/\1/p' | head -1)
	EXP=$(printf '%s' "$CONTENT"     | sed -n 's/.*"ip":"'"$IP"'".*"expires":\([0-9]*\).*/\1/p' | head -1)
	STARTED=$(printf '%s' "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"started":\([0-9]*\).*/\1/p' | head -1)

	: ${FWMARK:=1}; : ${DL:=0}; : ${UL:=0}; : ${EXP:=0}; : ${STARTED:=$NOW}

	REMAINING=$((EXP - NOW))

	# Verifica atividade (conntrack e tabela ARP)
	ACTIVE=false
	if [ -f /proc/net/nf_conntrack ]; then
		CONN_COUNT=$(grep -c "src=$IP " /proc/net/nf_conntrack 2>/dev/null || true)
		CONN_COUNT=$(echo "$CONN_COUNT" | tr -cd '0-9')
		[ -n "$CONN_COUNT" ] && [ "$CONN_COUNT" -gt 0 ] && ACTIVE=true
	fi

	if [ "$ACTIVE" = "false" ]; then
		ARP_FLAG=$(awk -v ip="$IP" '$1==ip{print $3}' /proc/net/arp 2>/dev/null | head -1)
		[ "$ARP_FLAG" = "0x2" ] && ACTIVE=true
	fi

	if [ "$ACTIVE" = "true" ]; then
		# Se ainda ativo e faltar menos de 25 min, estende automaticamente
		if [ "$REMAINING" -lt 1500 ]; then
			NEW_EXP=$((NOW + SESSION_TIME))
			# Reaviva regras iptables se necessário
			iptables -t nat -C CAPTIVE_AUTH_RETURN -s "$IP" -j ACCEPT 2>/dev/null || \
				iptables -t nat -A CAPTIVE_AUTH_RETURN -s "$IP" -j ACCEPT
			iptables -C CAPTIVE_AUTH_FWD -s "$IP" -j ACCEPT 2>/dev/null || \
				iptables -A CAPTIVE_AUTH_FWD -s "$IP" -j ACCEPT
			logger -t portal_renew "Sessão AUTO-RENOVADA: IP=$IP MAC=$MAC ($USER) +${SESSION_TIME}s"
			COUNT_RENEWED=$((COUNT_RENEWED + 1))
		else
			NEW_EXP="$EXP"
		fi

		ENTRY=$(printf '{"ip":"%s","mac":"%s","user":"%s","email":"%s","profile":"%s","fwmark":%s,"dl_kbit":%s,"ul_kbit":%s,"expires":%s,"started":%s,"remaining":%s}' \
			"$IP" "$MAC" "$USER" "$EMAIL" "$PROFILE" "$FWMARK" "$DL" "$UL" "$NEW_EXP" "$STARTED" "$((NEW_EXP - NOW))")
		[ -z "$NEW_SESSIONS" ] && NEW_SESSIONS="$ENTRY" || NEW_SESSIONS="${NEW_SESSIONS},${ENTRY}"

	else
		# Dispositivo inativo / desconectado
		if [ "$REMAINING" -le 0 ]; then
			# Remove das chains iptables
			iptables -t nat -D CAPTIVE_AUTH_RETURN -s "$IP" -j ACCEPT 2>/dev/null || true
			iptables        -D CAPTIVE_AUTH_FWD    -s "$IP" -j ACCEPT 2>/dev/null || true
			iptables -t mangle -D CAPTIVE_MANGLE_PRE  -s "$IP" -j BLOGSKIP 2>/dev/null || true
			iptables -t mangle -D CAPTIVE_MANGLE_PRE  -d "$IP" -j BLOGSKIP 2>/dev/null || true
			iptables -t mangle -D CAPTIVE_MANGLE_POST -s "$IP" -j MARK --set-mark "$FWMARK" 2>/dev/null || true
			iptables -t mangle -D CAPTIVE_MANGLE_POST -d "$IP" -j MARK --set-mark "$FWMARK" 2>/dev/null || true
			/sbin/fc flush 2>/dev/null || true
			logger -t portal_renew "Sessão EXPIRADA: IP=$IP MAC=$MAC ($USER)"
			COUNT_EXPIRED=$((COUNT_EXPIRED + 1))
		else
			# Ainda no prazo restante
			ENTRY=$(printf '{"ip":"%s","mac":"%s","user":"%s","email":"%s","profile":"%s","fwmark":%s,"dl_kbit":%s,"ul_kbit":%s,"expires":%s,"started":%s,"remaining":%s}' \
				"$IP" "$MAC" "$USER" "$EMAIL" "$PROFILE" "$FWMARK" "$DL" "$UL" "$EXP" "$STARTED" "$REMAINING")
			[ -z "$NEW_SESSIONS" ] && NEW_SESSIONS="$ENTRY" || NEW_SESSIONS="${NEW_SESSIONS},${ENTRY}"
		fi
	fi
done

printf '{"sessions":[%s]}' "$NEW_SESSIONS" > "$SESSIONS_FILE"

[ "$COUNT_RENEWED" -gt 0 ] || [ "$COUNT_EXPIRED" -gt 0 ] && \
	logger -t portal_renew "Verificação: $COUNT_RENEWED renovadas, $COUNT_EXPIRED expiradas."
