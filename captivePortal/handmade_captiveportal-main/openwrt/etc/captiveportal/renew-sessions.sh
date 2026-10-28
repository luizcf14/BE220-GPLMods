#!/bin/sh
# Portal Captivo 3000 — Script de Auto-Renovação de Sessões
# /etc/captiveportal/renew-sessions.sh
#
# Executado periodicamente via cron (a cada 5 minutos).
# Verifica tráfego e atividade na LAN dos clientes autenticados.
# Se o cliente estiver ativo (conntrack / ARP), a sessão no nftables é renovada.

SESSIONS_FILE="/tmp/captiveportal_sessions.json"

# Garante que o IP atribuído pelo ZeroTier esteja vinculado à interface no kernel
[ -x /etc/hotplug.d/iface/99-zerotier ] && /etc/hotplug.d/iface/99-zerotier 2>/dev/null || true

[ ! -f "$SESSIONS_FILE" ] && exit 0

SESSION_TIME=$(uci -q get captiveportal.global.session_time 2>/dev/null || echo 3600)
NOW=$(date +%s)

# Se o arquivo estiver vazio ou inválido, ignora
CONTENT=$(cat "$SESSIONS_FILE" 2>/dev/null)
[ -z "$CONTENT" ] || [ "$CONTENT" = '{"sessions":[]}' ] && exit 0

NEW_SESSIONS=""
COUNT_RENEWED=0
COUNT_EXPIRED=0

# Extrai os IPs das sessões cadastradas
IPS=$(echo "$CONTENT" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)

for IP in $IPS; do
	[ -z "$IP" ] && continue

	# Extrai dados da sessão para este IP
	MAC=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"mac":"\([^"]*\)".*/\1/p' | head -1)
	USER=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"user":"\([^"]*\)".*/\1/p' | head -1)
	EMAIL=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"email":"\([^"]*\)".*/\1/p' | head -1)
	PROFILE=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"profile":"\([^"]*\)".*/\1/p' | head -1)
	FWMARK=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"fwmark":\([0-9]*\).*/\1/p' | head -1)
	DL=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"dl_kbit":\([0-9]*\).*/\1/p' | head -1)
	UL=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"ul_kbit":\([0-9]*\).*/\1/p' | head -1)
	EXP=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"expires":\([0-9]*\).*/\1/p' | head -1)
	STARTED=$(echo "$CONTENT" | sed -n 's/.*"ip":"'"$IP"'".*"started":\([0-9]*\).*/\1/p' | head -1)

	: ${FWMARK:=1}
	: ${DL:=0}
	: ${UL:=0}
	: ${EXP:=0}
	: ${STARTED:=$NOW}

	# -----------------------------------------------------------------------
	# Verifica atividade do IP
	# 1. Tabela conntrack do kernel (conexões ativas)
	# 2. Tabela de vizinhos IP / ARP (REACHABLE / STALE / DELAY)
	# -----------------------------------------------------------------------
	ACTIVE=false

	# Checa conntrack se a ferramenta estiver disponível
	if command -v conntrack >/dev/null 2>&1; then
		CONN_COUNT=$(conntrack -L -s "$IP" 2>/dev/null | wc -l)
		[ "$CONN_COUNT" -gt 1 ] && ACTIVE=true
	else
		# Fallback: verifica /proc/net/nf_conntrack ou /proc/net/ip_conntrack
		if [ -f /proc/net/nf_conntrack ]; then
			CONN_COUNT=$(grep -c "src=$IP " /proc/net/nf_conntrack 2>/dev/null || echo 0)
			[ "$CONN_COUNT" -gt 1 ] && ACTIVE=true
		fi
	fi

	# Se não detectou por conntrack, verifica tabela ARP / ip neigh
	if [ "$ACTIVE" = "false" ]; then
		NEIGH_STATE=$(ip neigh show "$IP" 2>/dev/null | awk '{print $NF}')
		case "$NEIGH_STATE" in
			REACHABLE|STALE|DELAY|PROBE)
				ACTIVE=true
				;;
		esac
	fi

	# -----------------------------------------------------------------------
	# Decisão de renovação
	# -----------------------------------------------------------------------
	REMAINING=$((EXP - NOW))

	if [ "$ACTIVE" = "true" ]; then
		# Se faltarem menos de 20 minutos (1200s) ou já expirou, renova no nftables
		if [ "$REMAINING" -lt 1200 ]; then
			NEW_EXP=$((NOW + SESSION_TIME))
			nft add element inet fw4 captive_authenticated "{ $IP timeout ${SESSION_TIME}s }" 2>/dev/null
			nft add element inet fw4 captive_fwmark "{ $IP : $FWMARK }" 2>/dev/null
			logger -t portal_renew "Sessão RENOVA: IP=$IP MAC=$MAC ($USER) — Dispositivo ativo na LAN (+${SESSION_TIME}s)"
			COUNT_RENEWED=$((COUNT_RENEWED + 1))
		else
			NEW_EXP="$EXP"
		fi

		# Mantém a sessão ativa no JSON
		ENTRY=$(printf '{"ip":"%s","mac":"%s","user":"%s","email":"%s","profile":"%s","fwmark":%s,"dl_kbit":%s,"ul_kbit":%s,"expires":%s,"started":%s}' \
			"$IP" "$MAC" "$USER" "$EMAIL" "$PROFILE" "$FWMARK" "$DL" "$UL" "$NEW_EXP" "$STARTED")

		if [ -z "$NEW_SESSIONS" ]; then
			NEW_SESSIONS="$ENTRY"
		else
			NEW_SESSIONS="${NEW_SESSIONS},${ENTRY}"
		fi

	else
		# Dispositivo inativo
		if [ "$REMAINING" -le 0 ]; then
			# Expirou de fato e sem atividade — limpa
			nft delete element inet fw4 captive_authenticated "{ $IP }" 2>/dev/null || true
			nft delete element inet fw4 captive_fwmark "{ $IP }" 2>/dev/null || true
			logger -t portal_renew "Sessão EXPIRADA: IP=$IP MAC=$MAC ($USER) — Inativo"
			COUNT_EXPIRED=$((COUNT_EXPIRED + 1))
		else
			# Ainda não expirou, mantém a sessão no JSON até expirar
			ENTRY=$(printf '{"ip":"%s","mac":"%s","user":"%s","email":"%s","profile":"%s","fwmark":%s,"dl_kbit":%s,"ul_kbit":%s,"expires":%s,"started":%s}' \
				"$IP" "$MAC" "$USER" "$EMAIL" "$PROFILE" "$FWMARK" "$DL" "$UL" "$EXP" "$STARTED")

			if [ -z "$NEW_SESSIONS" ]; then
				NEW_SESSIONS="$ENTRY"
			else
				NEW_SESSIONS="${NEW_SESSIONS},${ENTRY}"
			fi
		fi
	fi
done

# Salva arquivo atualizado
printf '{"sessions":[%s]}' "$NEW_SESSIONS" > "$SESSIONS_FILE"

[ "$COUNT_RENEWED" -gt 0 ] || [ "$COUNT_EXPIRED" -gt 0 ] && \
	logger -t portal_renew "Verificação concluída: $COUNT_RENEWED sessões renovadas, $COUNT_EXPIRED expiradas."
