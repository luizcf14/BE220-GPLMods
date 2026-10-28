#!/usr/bin/env lua
-- ============================================================================
-- Conexão Povos da Floresta — Agente de Nuvem (Estilo UniFi / WebSockets)
-- TP-Link Archer BE220 (OpenWrt / Broadcom BCM6764)
--
-- Recursos:
-- 1. Conexão de saída (Outbound WebSocket) atravessando CGNAT, Starlink e 4G.
-- 2. Telemetria periódica (CPU, RAM, sessões ativas do Portal, QoS, IP WAN).
-- 3. Execução de comandos remotos em tempo real (QoS, kick de clientes, reboot).
-- 4. Console interativo Web SSH (PTY / ash tunelado via WebSocket).
-- ============================================================================

io.stdout:setvbuf("no")
local socket = require("socket")
local json = require("luci.json")
local nixio = require("nixio")

-- Ignora SIGPIPE (evita que SSL_write do OpenSSL mate o processo Lua quando o socket remoto sofre reset/outage)
pcall(function() nixio.signal(13, "ign") end)
pcall(function() nixio.signal("pipe", "ign") end)

-- Configurações padrão (podem ser sobrescritas por /etc/config/floresta_cloud)
local CONFIG = {
    server_host = "<CONTROLLER_HOST>",
    server_port = 443,
    server_path = "/ws/router",
    use_ssl = true,
    device_name = "Archer BE220",
    telemetry_interval = 10 -- segundos (atualização rápida de telemetria)
}

-- Lê configurações do UCI se disponível (com suporte a URL completa ou host/port)
local function load_uci_config()
    -- Restaura configuração persistente de /data ou /user_data1 sobre o ramfs /etc/config
    local data_file = io.open("/data/etc/config/floresta_cloud", "r")
    if data_file then
        local content = data_file:read("*a")
        data_file:close()
        if content and #content > 10 then
            os.execute("cp -f /data/etc/config/floresta_cloud /etc/config/floresta_cloud 2>/dev/null")
        end
    else
        local user_data_file = io.open("/user_data1/etc/config/floresta_cloud", "r")
        if user_data_file then
            local content = user_data_file:read("*a")
            user_data_file:close()
            if content and #content > 10 then
                os.execute("cp -f /user_data1/etc/config/floresta_cloud /etc/config/floresta_cloud 2>/dev/null")
            end
        end
    end

    local uf = io.popen("/sbin/uci -q get floresta_cloud.global.server_url 2>/dev/null")
    if uf then
        local url = uf:read("*l")
        uf:close()
        if url and url ~= "" then
            CONFIG.server_url = url
            local proto, host_port, path = string.match(url, "^(%a+)://([^/]+)(/?.*)")
            if proto and host_port then
                CONFIG.use_ssl = (proto == "https" or proto == "wss")
                local h, p = string.match(host_port, "^([^:]+):?(%d*)$")
                if h and h ~= "" then CONFIG.server_host = h end
                if p and p ~= "" then CONFIG.server_port = tonumber(p)
                else CONFIG.server_port = CONFIG.use_ssl and 443 or 80 end
                if path and path ~= "" and path ~= "/" then CONFIG.server_path = path end
            end
        end
    end

    local f = io.popen("/sbin/uci -q get floresta_cloud.global.server_host 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val and val ~= "" then CONFIG.server_host = val end
    end
    f = io.popen("/sbin/uci -q get floresta_cloud.global.server_port 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val and tonumber(val) then CONFIG.server_port = tonumber(val) end
    end
    f = io.popen("/sbin/uci -q get floresta_cloud.global.server_path 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val and val ~= "" then CONFIG.server_path = val end
    end
    f = io.popen("/sbin/uci -q get floresta_cloud.global.use_ssl 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val == "1" or val == "true" then CONFIG.use_ssl = true
        elseif val == "0" or val == "false" then CONFIG.use_ssl = false end
    end
    f = io.popen("/sbin/uci -q get floresta_cloud.global.device_name 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val and val ~= "" then CONFIG.device_name = val end
    end
    f = io.popen("/sbin/uci -q get floresta_cloud.global.adopted 2>/dev/null")
    if f then
        local val = f:read("*l")
        f:close()
        if val == "1" or val == "true" then CONFIG.adopted = "1"
        else CONFIG.adopted = "0" end
    end
    -- AUTO-CORREÇÃO & DETECÇÃO INTELIGENTE DE PROTOCOLO:
    -- Se o host for Cloud Run (*.run.app) ou tiver porta 443 ou url com https/wss,
    -- FORÇA SEMPRE SSL (WSS) e porta 443, garantindo conexão ininterrupta.
    local is_cloud_run = CONFIG.server_host and string.find(CONFIG.server_host, "%.run%.app")
    if is_cloud_run or CONFIG.server_port == 443 or (CONFIG.server_url and (string.find(CONFIG.server_url, "wss://") or string.find(CONFIG.server_url, "https://"))) then
        CONFIG.use_ssl = true
        CONFIG.server_port = 443
    elseif CONFIG.use_ssl and (not CONFIG.server_port or CONFIG.server_port == 80) then
        CONFIG.server_port = 443
    end
    if not CONFIG.server_path or CONFIG.server_path == "" or CONFIG.server_path == "/" then
        CONFIG.server_path = "/ws/router"
    end
end

load_uci_config()

-- Obtém MAC Address canônico do hardware (via getfirm MAC oficial TP-Link ou interfaces)
local function get_device_mac()
    -- 0. Se já temos MAC gravado no UCI, usa ele para garantir persistência 100% idêntica
    local pf = io.popen("/sbin/uci -q get floresta_cloud.global.mac 2>/dev/null")
    if pf then
        local cm = pf:read("*l")
        pf:close()
        if cm and cm ~= "" and cm ~= "00:00:00:00:00:00" and not string.find(cm, "00:FF:00") and not string.find(cm, "00:0A:EB") then
            return string.upper(string.gsub(string.gsub(cm, "%s+", ""), "-", ":"))
        end
    end

    local mac = nil

    -- Tenta até 10 vezes aguardando drivers de rede subirem durante o boot
    for attempt = 1, 10 do
        -- 1. Método Oficial TP-Link
        local gf = io.popen("/sbin/getfirm MAC 2>/dev/null")
        if gf then
            mac = gf:read("*l")
            gf:close()
            if mac and mac ~= "" and not string.find(mac, "00-0A-EB") and not string.find(mac, "00-FF-00") then
                mac = string.gsub(mac, "%s+", "")
                mac = string.gsub(mac, "-", ":")
            else
                mac = nil
            end
        end

        -- 2. Fallback: br-lan (LAN MAC principal do sistema)
        if not mac or mac == "" then
            local f = io.open("/sys/class/net/br-lan/address", "r")
            if f then
                mac = f:read("*l")
                f:close()
                if mac and (mac == "00:00:00:00:00:00" or string.find(mac, "00:0a:eb") or string.find(mac, "00:ff:00")) then
                    mac = nil
                end
            end
        end

        -- 3. Fallback: ethaddr gravado pelo kernel
        if not mac or mac == "" then
            local f = io.open("/proc/environment/ethaddr", "r")
            if f then
                mac = f:read("*l")
                f:close()
            end
        end

        -- 4. Fallback: UCI network
        if not mac or mac == "" then
            local pfu = io.popen("/sbin/uci -q get network.lan.macaddr 2>/dev/null")
            if pfu then mac = pfu:read("*l"); pfu:close() end
        end

        if mac and mac ~= "" and mac ~= "00:00:00:00:00:00" then
            break
        end

        os.execute("sleep 1")
    end

    -- 5. Fallback: eth0
    if not mac or mac == "" then
        local f = io.open("/sys/class/net/eth0/address", "r")
        if f then
            mac = f:read("*l")
            f:close()
        end
    end

    if not mac or mac == "" then
        mac = "00:00:00:00:00:00"
    end

    local clean_mac = string.upper(string.gsub(string.gsub(mac, "%s+", ""), "-", ":"))
    if clean_mac ~= "00:00:00:00:00:00" then
        os.execute(string.format("/sbin/uci set floresta_cloud.global.mac='%s' 2>/dev/null", clean_mac))
        os.execute("/sbin/uci commit floresta_cloud 2>/dev/null")
        os.execute("mkdir -p /data/etc/config && cp /etc/config/floresta_cloud /data/etc/config/ 2>/dev/null")
        os.execute("mkdir -p /user_data1/etc/config && cp /etc/config/floresta_cloud /user_data1/etc/config/ 2>/dev/null")
        os.execute("sync")
    end
    return clean_mac
end

local DEVICE_MAC = get_device_mac()

-- Funções utilitárias de WebSocket RFC 6455
local function ws_encode(payload, opcode)
    opcode = opcode or 1 -- 1 = text
    local len = #payload
    local h1 = string.char(128 + opcode) -- FIN = 1
    local h2
    local extra_len = ""

    if len < 126 then
        h2 = 128 + len -- MASK bit = 1
    elseif len <= 65535 then
        h2 = 128 + 126
        extra_len = string.char(math.floor(len / 256), len % 256)
    else
        h2 = 128 + 127
        -- Simplificado para pacotes < 4GB
        extra_len = string.char(0, 0, 0, 0,
            math.floor(len / 16777216) % 256,
            math.floor(len / 65536) % 256,
            math.floor(len / 256) % 256,
            len % 256)
    end

    -- 4 bytes de máscara aleatórios
    local m1 = math.random(0, 255)
    local m2 = math.random(0, 255)
    local m3 = math.random(0, 255)
    local m4 = math.random(0, 255)
    local mask = { m1, m2, m3, m4 }
    local mask_str = string.char(m1, m2, m3, m4)

    local masked_bytes = {}
    for i = 1, len do
        local b = string.byte(payload, i)
        local m = mask[((i - 1) % 4) + 1]
        -- XOR bitwise em Lua puro
        local xor_val = 0
        local p = 1
        for _ = 1, 8 do
            local b_bit = b % 2
            local m_bit = m % 2
            if b_bit ~= m_bit then xor_val = xor_val + p end
            b = math.floor(b / 2)
            m = math.floor(m / 2)
            p = p * 2
        end
        masked_bytes[i] = string.char(xor_val)
    end

    return h1 .. string.char(h2) .. extra_len .. mask_str .. table.concat(masked_bytes)
end

-- Gerenciador de upload ativo declarado previamente para uso em ws_decode e no loop principal
local active_upload = nil

-- Envio seguro de frame WebSocket com loop de retransmissão para evitar perda de dados por buffer saturado
local function safe_ws_send(sock, payload, opcode)
    if not sock then return false, "no socket" end
    local frame = ws_encode(payload, opcode)
    local total = #frame
    local sent = 0
    local retries = 0

    while sent < total and retries < 50 do
        local n, err, last_sent = sock:send(frame, sent + 1)
        if n then
            sent = n
        elseif last_sent then
            sent = last_sent
        end

        if sent >= total then
            return true
        end

        if err == "closed" then
            return false, "closed"
        end

        retries = retries + 1
        socket.sleep(0.002) -- 2ms para descarregar o buffer do socket
    end

    return (sent >= total), (sent < total and "send timeout" or nil)
end

-- Decodifica frame WebSocket vindo do servidor (servidor -> cliente NÃO é mascarado)
local function ws_decode(sock)
    sock:settimeout(active_upload and 0.002 or 0.05)
    local b1_str, err = sock:receive(1)
    if not b1_str then return nil, err end

    -- Frame detectado: timeout de 10s para ler o cabeçalho e payload completos
    sock:settimeout(10)

    local b2_str = sock:receive(1)
    if not b2_str then
        sock:settimeout(0.05)
        return nil, "incomplete header"
    end

    local b1 = string.byte(b1_str)
    local b2 = string.byte(b2_str)
    local opcode = b1 % 16
    local masked = (b2 >= 128)
    local len = b2 % 128

    if len == 126 then
        local lbytes = sock:receive(2)
        if not lbytes then sock:settimeout(0.05); return nil, "incomplete len" end
        len = string.byte(lbytes, 1) * 256 + string.byte(lbytes, 2)
    elseif len == 127 then
        local lbytes = sock:receive(8)
        if not lbytes then sock:settimeout(0.05); return nil, "incomplete len64" end
        local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(lbytes, 1, 8)
        len = (((((((b1 * 256 + b2) * 256 + b3) * 256 + b4) * 256 + b5) * 256 + b6) * 256 + b7) * 256 + b8)
    end

    local mask = nil
    if masked then
        local mbytes = sock:receive(4)
        if not mbytes then sock:settimeout(0.05); return nil, "incomplete mask" end
        mask = { string.byte(mbytes, 1), string.byte(mbytes, 2), string.byte(mbytes, 3), string.byte(mbytes, 4) }
    end

    local payload = ""
    if len > 0 then
        local chunks = {}
        local received = 0
        local wait_retries = 0
        while received < len do
            local to_read = len - received
            local chunk, rerr, part = sock:receive(to_read)
            local data = chunk or part
            if data and #data > 0 then
                table.insert(chunks, data)
                received = received + #data
                wait_retries = 0
            else
                wait_retries = wait_retries + 1
                if wait_retries > 100 then
                    sock:settimeout(0.05)
                    return nil, "incomplete payload timeout"
                end
                socket.sleep(0.02)
            end
            if received >= len then break end
            if rerr and rerr ~= "timeout" and rerr ~= "wantread" then
                sock:settimeout(0.05)
                return nil, "incomplete payload: " .. tostring(rerr)
            end
        end
        payload = table.concat(chunks)

        if masked and mask then
            local unmasked = {}
            for i = 1, len do
                local b = string.byte(payload, i)
                local m = mask[((i - 1) % 4) + 1]
                local x = 0
                local p = 1
                for _ = 1, 8 do
                    if (b % 2) ~= (m % 2) then x = x + p end
                    b = math.floor(b / 2)
                    m = math.floor(m / 2)
                    p = p * 2
                end
                unmasked[i] = string.char(x)
            end
            payload = table.concat(unmasked)
        end
    end

    sock:settimeout(active_upload and 0.002 or 0.05)
    return { opcode = opcode, payload = payload }
end

-- Obtém o IP da interface LAN de forma dinâmica (respeita alteração de IP pelo usuário)
local function get_lan_ip()
    local ucf = io.popen("/sbin/uci -q get network.lan.ipaddr 2>/dev/null")
    if ucf then
        local lip = ucf:read("*l")
        ucf:close()
        if lip and lip ~= "" then return lip end
    end
    local ifc = io.popen("/sbin/ifconfig br-lan 2>/dev/null | awk -F'[: ]+' '/inet addr:/ {print $4}'")
    if ifc then
        local lip = ifc:read("*l")
        ifc:close()
        if lip and lip ~= "" then return lip end
    end
    local ipf = io.popen("/sbin/ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1")
    if ipf then
        local lip = ipf:read("*l")
        ipf:close()
        if lip and lip ~= "" then return lip end
    end
    return "192.168.0.1"
end

-- Coleta telemetria em tempo real do roteador
local function collect_telemetry()
    -- Atualiza device_name caso tenha sido alterado dinamicamente
    local dnf = io.popen("/sbin/uci -q get floresta_cloud.global.device_name 2>/dev/null")
    if dnf then
        local dname = dnf:read("*l")
        dnf:close()
        if dname and dname ~= "" then CONFIG.device_name = dname end
    end

    -- Atualiza status de adoção do hardware caso tenha sido alterado
    local adf = io.popen("/sbin/uci -q get floresta_cloud.global.adopted 2>/dev/null")
    if adf then
        local aval = adf:read("*l")
        adf:close()
        if aval == "1" or aval == "true" then CONFIG.adopted = "1"
        elseif aval == "0" or aval == "false" then CONFIG.adopted = "0" end
    end
    local is_ad = (CONFIG.adopted == "1" or CONFIG.adopted == true or CONFIG.adopted == "true")

    local t = {
        mac = DEVICE_MAC,
        name = CONFIG.device_name,
        adopted = is_ad,
        timestamp = os.time(),
        loadavg = { 0.1, 0.1, 0.1 },
        mem_free_mb = 256,
        uptime = "—",
        wan_ip = "—",
        lan_ip = get_lan_ip(),
        qos_enabled = true,
        auth_count = 0,
        sessions = {}
    }

    -- Loadavg
    local lf = io.open("/proc/loadavg", "r")
    if lf then
        local line = lf:read("*l")
        lf:close()
        if line then
            local l1, l2, l3 = string.match(line, "(%S+)%s+(%S+)%s+(%S+)")
            if l1 and l2 and l3 then
                t.loadavg = { tonumber(l1), tonumber(l2), tonumber(l3) }
            end
        end
    end

    -- Memória RAM livre
    local mf = io.open("/proc/meminfo", "r")
    if mf then
        local free_kb = 0
        local buf_kb = 0
        local cached_kb = 0
        for mline in mf:lines() do
            local k, v = string.match(mline, "([^:]+):%s+(%d+)")
            if k == "MemFree" then free_kb = tonumber(v) or 0
            elseif k == "Buffers" then buf_kb = tonumber(v) or 0
            elseif k == "Cached" then cached_kb = tonumber(v) or 0 end
        end
        mf:close()
        t.mem_free_mb = math.floor((free_kb + buf_kb + cached_kb) / 1024)
    end

    -- Uptime formatado
    local uf = io.open("/proc/uptime", "r")
    if uf then
        local line = uf:read("*l")
        uf:close()
        if line then
            local sec = tonumber(string.match(line, "(%d+)")) or 0
            local d = math.floor(sec / 86400)
            local h = math.floor((sec % 86400) / 3600)
            local m = math.floor((sec % 3600) / 60)
            if d > 0 then t.uptime = string.format("%dd %dh %dm", d, h, m)
            else t.uptime = string.format("%dh %dm", h, m) end
        end
    end

    -- QoS status
    local qf = io.popen("/sbin/uci -q get captiveportal.global.enable_qos 2>/dev/null")
    if qf then
        local qval = qf:read("*l")
        qf:close()
        t.qos_enabled = (qval ~= "0")
    end

    -- Versão do Firmware / Build ID e Slot Ativo
    local b_ver = "2.6.0-floresta"
    local b_id = nil
    local bf = io.open("/etc/floresta_build_info", "r") or io.open("/data/floresta_build_info", "r")
    if bf then
        for bline in bf:lines() do
            local v = string.match(bline, '^BUILD_VERSION="([^"]+)"')
            if v then b_ver = v end
            local id = string.match(bline, '^BUILD_ID="([^"]+)"')
            if id then b_id = id end
        end
        bf:close()
    end
    local slot_str = nil
    local cmdf = io.open("/proc/cmdline", "r")
    if cmdf then
        local cmdline = cmdf:read("*a") or ""
        cmdf:close()
        if string.find(cmdline, "ubiblock0_4", 1, true) then
            slot_str = "Slot 1"
        elseif string.find(cmdline, "ubiblock0_6", 1, true) then
            slot_str = "Slot 2"
        end
    end
    if b_id and b_id ~= "" and b_id ~= "N/A" then
        t.fw_version = string.format("%s (%s)", b_ver, b_id)
        t.build_id = b_id
    else
        t.fw_version = b_ver
    end
    if slot_str then
        t.boot_slot = slot_str
    end

    -- Sessões ativas do Portal Captivo + Dispositivos conectados na LAN/Wi-Fi (br-lan)
    local session_list = {}
    local seen_ip = {}
    local seen_mac = {}

    local sf = io.open("/tmp/captiveportal_sessions.json", "r")
    if sf then
        local raw = sf:read("*a")
        sf:close()
        if raw and raw ~= "" then
            local ok, parsed = pcall(json.decode, raw)
            if ok and type(parsed) == "table" then
                local list = (type(parsed.sessions) == "table") and parsed.sessions or parsed
                for _, s in ipairs(list) do
                    if type(s) == "table" and s.ip then
                        table.insert(session_list, s)
                        seen_ip[s.ip] = true
                        if s.mac then seen_mac[string.lower(s.mac)] = true end
                    end
                end
            end
        end
    end

    -- Mapa de nomes DHCP (/tmp/dhcp.leases)
    local dhcp_names = {}
    local df = io.open("/tmp/dhcp.leases", "r")
    if df then
        for dline in df:lines() do
            local _, dmac, dip, dhost = string.match(dline, "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if dmac and dhost and dhost ~= "*" then
                dhcp_names[string.lower(dmac)] = dhost
            end
            if dip and dhost and dhost ~= "*" then
                dhcp_names[dip] = dhost
            end
        end
        df:close()
    end

    -- Dispositivos ativos na bridge LAN/Wi-Fi (/proc/net/arp com flag 0x2 em br-lan)
    local arpf = io.open("/proc/net/arp", "r")
    if arpf then
        for aline in arpf:lines() do
            local aip, _, aflags, amac, _, adev = string.match(aline, "^(%d+%.%d+%.%d+%.%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if aip and aflags == "0x2" and adev == "br-lan" and amac and amac ~= "00:00:00:00:00:00" then
                local lmac = string.lower(amac)
                if not seen_ip[aip] and not seen_mac[lmac] then
                    seen_ip[aip] = true
                    seen_mac[lmac] = true
                    local hname = dhcp_names[lmac] or dhcp_names[aip] or "Dispositivo Conectado"
                    table.insert(session_list, {
                        ip = aip,
                        mac = lmac,
                        user = hname,
                        profile = "LAN / Wi-Fi"
                    })
                end
            end
        end
        arpf:close()
    end

    t.sessions = session_list
    t.auth_count = #session_list

    return t
end

-- ============================================================================
-- MECANISMO DE BLOQUEIO DNS (DNS SINKHOLE COM PROTEÇÃO DE WHITELIST)
-- ============================================================================
local function get_captive_whitelist()
    local wl = {}
    -- 1. Domínios do Walled Garden do Portal Captivo
    local f = io.popen("/sbin/uci -q get captiveportal.walled_garden.domain 2>/dev/null")
    if f then
        local raw = f:read("*a")
        f:close()
        if raw then
            for d in raw:gmatch("%S+") do
                local clean = d:lower():gsub("^%*%.", ""):gsub("^https?://", ""):gsub("/.*$", ""):gsub("%s+", "")
                if #clean > 0 then wl[clean] = true end
            end
        end
    end
    -- 2. Host da API do Portal Captivo
    local fa = io.popen("/sbin/uci -q get captiveportal.global.api_url 2>/dev/null")
    if fa then
        local url = fa:read("*l")
        fa:close()
        if url and #url > 0 then
            local clean = url:lower():gsub("^https?://", ""):gsub("/.*$", ""):gsub(":.*$", ""):gsub("%s+", "")
            if #clean > 0 then wl[clean] = true end
        end
    end
    -- 3. Host do Cloud Controller (garante que o agente nunca bloqueie a própria conexão com a nuvem)
    local fc = io.popen("/sbin/uci -q get floresta_cloud.global.server_url 2>/dev/null")
    if fc then
        local url = fc:read("*l")
        fc:close()
        if url and #url > 0 then
            local clean = url:lower():gsub("^wss?://", ""):gsub("^https?://", ""):gsub("/.*$", ""):gsub(":.*$", ""):gsub("%s+", "")
            if #clean > 0 then wl[clean] = true end
        end
    end
    if CONFIG.server_host and #CONFIG.server_host > 0 then
        wl[CONFIG.server_host:lower()] = true
    end
    return wl
end

local function is_whitelisted(domain, whitelist)
    local d = domain:lower()
    if whitelist[d] then return true end
    for wld, _ in pairs(whitelist) do
        if d == wld or d:sub(-(#wld + 1)) == "." .. wld or wld:sub(-(#d + 1)) == "." .. d then
            return true
        end
    end
    return false
end

local function apply_dns_blocklist(domains)
    local whitelist = get_captive_whitelist()
    local blocked_entries = {}
    local blocked_domains = {}
    local skipped_whitelist = 0

    if type(domains) == "table" then
        for _, raw in ipairs(domains) do
            if type(raw) == "string" then
                local d = raw:lower():gsub("^https?://", ""):gsub("^www%.", ""):gsub("/.*$", ""):gsub(":.*$", ""):gsub("%s+", "")
                if #d > 2 and d:find("%.") then
                    if is_whitelisted(d, whitelist) then
                        skipped_whitelist = skipped_whitelist + 1
                        print("[DNS-Block] IGNORADO: '" .. d .. "' protegido pela Whitelist do Portal Captivo")
                    else
                        if not blocked_domains[d] then
                            blocked_domains[d] = true
                            table.insert(blocked_entries, string.format("address=/%s/0.0.0.0\naddress=/%s/::\n", d, d))
                        end
                    end
                end
            end
        end
    end

    -- Verifica se o conteúdo de /tmp/dns_blocklist.conf mudou antes de reiniciar o dnsmasq
    local content = "# Floresta DNS Blocklist (Gerado pelo Cloud Controller)\n" .. table.concat(blocked_entries, "")
    local old_content = nil
    local rf = io.open("/tmp/dns_blocklist.conf", "r")
    if rf then
        old_content = rf:read("*a")
        rf:close()
    end

    -- Garante que /etc/dnsmasq.conf inclua o arquivo
    local dm_check = io.open("/etc/dnsmasq.conf", "r")
    local needs_include = true
    if dm_check then
        local dmc = dm_check:read("*a")
        dm_check:close()
        if dmc and dmc:find("dns_blocklist.conf") then
            needs_include = false
        end
    end
    if needs_include then
        local dm_app = io.open("/etc/dnsmasq.conf", "a")
        if dm_app then
            dm_app:write("\n# Floresta Cloud DNS Sinkhole\nconf-file=/tmp/dns_blocklist.conf\n")
            dm_app:close()
        end
    end

    if old_content ~= content or needs_include then
        local f = io.open("/tmp/dns_blocklist.conf", "w")
        if f then
            f:write(content)
            f:close()
        end

        -- Persiste em /data/etc/dns_blocklist.conf para resiliência offline
        os.execute("mkdir -p /data/etc && cp /tmp/dns_blocklist.conf /data/etc/dns_blocklist.conf 2>/dev/null && sync")

        -- Evita acúmulo de processos dnsproxy_deamon.sh antes de reiniciar o dnsmasq
        os.execute("for p in $(pgrep -f dnsproxy_deamon.sh 2>/dev/null); do kill -9 $p 2>/dev/null; done")
        os.execute("/etc/init.d/dnsmasq restart 2>/dev/null")
    end

    local count = 0
    for _ in pairs(blocked_domains) do count = count + 1 end

    return {
        ok = true,
        count = count,
        skipped_whitelist = skipped_whitelist,
        message = string.format("Bloqueio DNS atualizado: %d domínios ativos (%d protegidos pela whitelist)", count, skipped_whitelist)
    }
end

-- Trata execução de comandos remotos vindos da Cloud
local function handle_command(cmd)
    local action = cmd.action
    local params = cmd.params or {}
    local res = { ok = false, error = "Ação não suportada" }

    if action == "qos_toggle" or action == "qos_set" then
        local state = params.enabled
        if state ~= nil then
            state = tostring(state)
        else
            state = ""
        end
        local cmd_str = string.format("curl -k -s -d 'action=qos_toggle&enabled=%s' http://127.0.0.1/cgi-bin/captive_admin_api 2>/dev/null", state)
        local f = io.popen(cmd_str)
        if f then
            local out = f:read("*a")
            f:close()
            local ok, parsed = pcall(json.decode, out)
            if ok and type(parsed) == "table" then res = parsed else res = { ok = true, raw = out } end
        end
    elseif action == "kick" then
        local ip = params.ip or ""
        if ip ~= "" then
            local cmd_str = string.format("curl -k -s -d 'action=kick&ip=%s' http://127.0.0.1/cgi-bin/captive_admin_api 2>/dev/null", ip)
            local f = io.popen(cmd_str)
            if f then
                local out = f:read("*a")
                f:close()
                res = { ok = true, message = "Cliente desconectado" }
            end
        end
    elseif action == "reboot" then
        os.execute("reboot &")
        res = { ok = true, message = "Roteador reiniciando..." }
    elseif action == "dns_block_update" then
        local domains = params.domains or {}
        res = apply_dns_blocklist(domains)
    elseif action == "dns_block_get" then
        local list = {}
        local f = io.open("/tmp/dns_blocklist.conf", "r")
        if not f then f = io.open("/data/etc/dns_blocklist.conf", "r") end
        if f then
            for line in f:lines() do
                local d = line:match("^address=/(.-)/0%.0%.0%.0")
                if d then table.insert(list, d) end
            end
            f:close()
        end
        res = { ok = true, domains = list }
    end

    return res
end

-- ============================================================================
-- SESSÃO DE TERMINAL REMOTO (Web SSH)
-- ============================================================================
local active_term = nil

local function stop_terminal(term_id)
    local pid_file = "/tmp/floresta_term_" .. tostring(term_id) .. ".pid"
    local f = io.open(pid_file, "r")
    if f then
        local pid = f:read("*a")
        f:close()
        if pid and #pid > 0 then
            os.execute("kill -9 " .. pid:gsub("%s+", "") .. " 2>/dev/null")
        end
        os.remove(pid_file)
    end
    if active_term and tostring(active_term.id) == tostring(term_id) then
        if active_term.in_fd then pcall(function() active_term.in_fd:close() end) end
        if active_term.out_fd then pcall(function() active_term.out_fd:close() end) end
        if active_term.pid then
            os.execute("kill -9 " .. tostring(active_term.pid) .. " 2>/dev/null")
        end
        os.remove(active_term.in_fifo or "")
        os.remove(active_term.out_fifo or "")
        if active_term.env_file then os.remove(active_term.env_file) end
        active_term = nil
    end
end

local function start_terminal(sock, term_id)
    if active_term then
        stop_terminal(active_term.id)
    end
    -- Termina processos órfãos anteriores ligados a FIFOs de terminal
    os.execute("for p in $(pgrep -f floresta_term_in 2>/dev/null); do kill -9 $p 2>/dev/null; done")

    local in_fifo = "/tmp/floresta_term_in_" .. term_id
    local out_fifo = "/tmp/floresta_term_out_" .. term_id
    local pid_file = "/tmp/floresta_term_" .. term_id .. ".pid"
    os.execute(string.format("rm -f %s %s %s && mkfifo %s %s", in_fifo, out_fifo, pid_file, in_fifo, out_fifo))

    -- 1. Abre FIFOs de forma não-bloqueante ANTES de disparar o shell
    local in_fd = nixio.open(in_fifo, nixio.open_flags("rdwr", "nonblock"))
    local out_fd = nixio.open(out_fifo, nixio.open_flags("rdwr", "nonblock"))

    -- 2. Prepara wrappers de compatibilidade em /tmp/bin (sudo, nano, su)
    os.execute("mkdir -p /tmp/bin")
    local f_sudo = io.open("/tmp/bin/sudo", "w")
    if f_sudo then
        f_sudo:write("#!/bin/sh\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin:/tmp/bin\nexec \"$@\"\n")
        f_sudo:close()
        os.execute("chmod +x /tmp/bin/sudo")
    end
    local f_nano = io.open("/tmp/bin/nano", "w")
    if f_nano then
        f_nano:write("#!/bin/sh\nexec /bin/vi \"$@\"\n")
        f_nano:close()
        os.execute("chmod +x /tmp/bin/nano")
    end
    local f_su = io.open("/tmp/bin/su", "w")
    if f_su then
        f_su:write("#!/bin/sh\nif [ $# -eq 0 ] || [ \"$1\" = \"root\" ] || [ \"$1\" = \"-\" ]; then\n  echo \"[!] Você já está conectado como root!\"\nelse\n  exec \"$@\"\nfi\n")
        f_su:close()
        os.execute("chmod +x /tmp/bin/su")
    end

    -- 3. Cria script de inicialização do ambiente interativo de root
    local esc = string.char(27)
    local env_file = "/tmp/floresta_env_" .. term_id .. ".sh"
    local f_env = io.open(env_file, "w")
    if f_env then
        f_env:write("export USER=root\n")
        f_env:write("export HOME=/root\n")
        f_env:write("export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/tmp/bin\n")
        f_env:write("export TERMINFO=/usr/share/terminfo\n")
        f_env:write("export TERM=xterm-256color\n")
        f_env:write("[ -f /etc/profile ] && . /etc/profile\n")
        f_env:write("export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/tmp/bin\n")
        f_env:write("alias sudo=\"\"\n")
        f_env:write("alias nano=vi\n")
        f_env:write("alias su=\"echo '[!] Você já está conectado como root!'\"\n")
        f_env:write(string.format("export PS1='%s[1;32mroot@BE220%s:%s[1;34m\\w%s# '\n", esc, esc, esc, esc))
        f_env:write("cd /root\n")
        f_env:close()
    end

    -- 4. Inicia /bin/ash em modo login (-l) interativo (-i) conectado aos FIFOs
    local ash_cmd = string.format("ENV=%s /bin/ash -l -i < %s > %s 2>&1 & echo $! > %s",
        env_file, in_fifo, out_fifo, pid_file)
    os.execute(ash_cmd)

    local ash_pid = nil
    local pf = io.open(pid_file, "r")
    if pf then
        ash_pid = tonumber(pf:read("*l"))
        pf:close()
    end

    active_term = {
        id = term_id,
        pid = ash_pid,
        in_fd = in_fd,
        out_fd = out_fd,
        in_fifo = in_fifo,
        out_fifo = out_fifo,
        env_file = env_file
    }

    -- Envia banner inicial
    local telem = collect_telemetry()
    local cur_name = CONFIG.device_name or "Archer BE220"
    local welcome = "\r\n" .. esc .. "[1;32m========================================================" .. esc .. "[0m\r\n" ..
                    esc .. "[1;36m   Conexao Povos da Floresta - Console Seguro BE220     " .. esc .. "[0m\r\n" ..
                    esc .. "[1;33m   Dispositivo: " .. cur_name .. " (" .. DEVICE_MAC .. ")" .. esc .. "[0m\r\n" ..
                    esc .. "[1;33m   Uptime: " .. (telem.uptime or "—") .. esc .. "[0m\r\n" ..
                    esc .. "[1;32m========================================================" .. esc .. "[0m\r\n\r\n"

    -- Envia banner inicial (base64 — server.php faz base64_decode em todos os term_output)
    safe_ws_send(sock, json.encode({
        type = "term_output",
        term_id = term_id,
        data = nixio.bin.b64encode(welcome)
    }), 1)
end

-- ============================================================================
-- GERENCIADOR DE UPLOAD DE ARQUIVOS (DIRETO PARA /tmp)
-- ============================================================================

local function sanitize_filename(filename)
    if not filename or type(filename) ~= "string" then return "uploaded_file.bin" end
    -- Remove caminhos e barras
    local clean = filename:match("([^/\\]+)$") or filename
    -- Permite apenas caracteres seguros: letras, números, '.', '_', '-'
    clean = clean:gsub("[^%w%._%-]", "_")
    if #clean == 0 or clean:sub(1,1) == "." then
        clean = "upload_" .. tostring(os.time()) .. ".bin"
    end
    return clean
end

local function handle_file_upload_start(sock, msg)
    local upload_id = msg.upload_id or tostring(os.time())
    local term_id = msg.term_id
    local raw_name = msg.filename or "upload.bin"
    local clean_name = sanitize_filename(raw_name)
    local target_path = "/tmp/" .. clean_name
    local total_size = tonumber(msg.total_size) or 0

    -- Se houver upload anterior pendente, fecha
    if active_upload and active_upload.file then
        pcall(function() active_upload.file:close() end)
    end

    local f, err = io.open(target_path, "wb")
    if not f then
        print("[!] Erro ao abrir arquivo para escrita em /tmp: " .. tostring(err))
        safe_ws_send(sock, json.encode({
            type = "file_upload_ready",
            upload_id = upload_id,
            term_id = term_id,
            success = false,
            error = "Nao foi possivel abrir o arquivo para escrita: " .. tostring(err)
        }), 1)
        return
    end

    active_upload = {
        upload_id = upload_id,
        term_id = term_id,
        filename = clean_name,
        target_path = target_path,
        total_size = total_size,
        received_size = 0,
        file = f,
        start_time = os.time()
    }

    print("[Upload] Iniciando recebimento: " .. target_path .. " (" .. tostring(total_size) .. " bytes)")

    safe_ws_send(sock, json.encode({
        type = "file_upload_ready",
        upload_id = upload_id,
        term_id = term_id,
        filename = clean_name,
        target_path = target_path,
        total_size = total_size,
        success = true
    }), 1)
end

local function handle_file_upload_chunk(sock, msg)
    local upload_id = msg.upload_id
    local term_id = msg.term_id
    local chunk_index = tonumber(msg.chunk) or 0
    local b64_data = msg.data or ""

    if not active_upload or active_upload.upload_id ~= upload_id or not active_upload.file then
        safe_ws_send(sock, json.encode({
            type = "file_upload_ack",
            upload_id = upload_id,
            term_id = term_id,
            chunk = chunk_index,
            success = false,
            error = "Sessao de upload nao encontrada ou inativa"
        }), 1)
        return
    end

    local raw = nixio.bin.b64decode(b64_data)
    if raw and #raw > 0 then
        active_upload.file:write(raw)
        active_upload.received_size = active_upload.received_size + #raw
    end

    safe_ws_send(sock, json.encode({
        type = "file_upload_ack",
        upload_id = upload_id,
        term_id = term_id,
        chunk = chunk_index,
        received = active_upload.received_size,
        total = active_upload.total_size,
        success = true
    }), 1)
end

local function handle_file_upload_end(sock, msg)
    local upload_id = msg.upload_id
    local term_id = msg.term_id

    if not active_upload or active_upload.upload_id ~= upload_id then
        safe_ws_send(sock, json.encode({
            type = "file_upload_done",
            upload_id = upload_id,
            term_id = term_id,
            success = false,
            error = "Sessao de upload nao encontrada"
        }), 1)
        return
    end

    if active_upload.file then
        pcall(function()
            active_upload.file:flush()
            active_upload.file:close()
        end)
        active_upload.file = nil
    end

    local path = active_upload.target_path
    local total_bytes = active_upload.received_size

    -- Calcula md5sum se disponivel
    local md5_val = ""
    local mf = io.popen("md5sum " .. path .. " 2>/dev/null")
    if mf then
        local mline = mf:read("*l")
        mf:close()
        if mline then
            md5_val = mline:match("^(%w+)") or ""
        end
    end

    print("[Upload] Concluido com sucesso: " .. path .. " (" .. tostring(total_bytes) .. " bytes, MD5: " .. md5_val .. ")")

    safe_ws_send(sock, json.encode({
        type = "file_upload_done",
        upload_id = upload_id,
        term_id = term_id,
        filename = active_upload.filename,
        target_path = path,
        size = total_bytes,
        md5 = md5_val,
        success = true
    }), 1)

    -- Mensagem informativa no console terminal
    if active_term and active_term.in_fd and tostring(active_term.id) == tostring(term_id) then
        local esc = string.char(27)
        local mb_str = string.format("%.2f MB", total_bytes / (1024 * 1024))
        local term_notify = "\r\n" .. esc .. "[1;32m[✓ Arquivo recebido em " .. path .. " (" .. mb_str .. " | MD5: " .. (md5_val ~= "" and md5_val or "OK") .. ")]" .. esc .. "[0m\r\n"
        safe_ws_send(sock, json.encode({
            type = "term_output",
            term_id = term_id,
            data = nixio.bin.b64encode(term_notify)
        }), 1)
    end

    active_upload = nil
end

local function handle_fast_file_download(sock, msg)
    local upload_id = msg.upload_id or tostring(os.time())
    local term_id = msg.term_id
    local raw_name = msg.filename or "upload.bin"
    local clean_name = sanitize_filename(raw_name)
    local target_path = msg.target_path or ("/tmp/" .. clean_name)
    local total_size = tonumber(msg.total_size) or 0
    local url = msg.url

    print(string.format("[Turbo-Upload] Baixando diretamente via curl: %s -> %s (%d bytes)", url, target_path, total_size))

    safe_ws_send(sock, json.encode({
        type = "file_upload_ready",
        upload_id = upload_id,
        term_id = term_id,
        filename = clean_name,
        target_path = target_path,
        total_size = total_size,
        success = true
    }), 1)

    -- Executa curl diretamente salvando em target_path
    local curl_cmd = string.format("curl -k -f -sSL -o %s '%s' 2>/dev/null", target_path, url)
    os.execute(curl_cmd)

    -- Verifica tamanho e calcula MD5
    local sz_f = io.popen("ls -l " .. target_path .. " 2>/dev/null | awk '{print $5}'")
    local sz = sz_f and tonumber(sz_f:read("*l")) or 0
    if sz_f then sz_f:close() end

    local md5_val = ""
    local mf = io.popen("md5sum " .. target_path .. " 2>/dev/null")
    if mf then
        local mline = mf:read("*l")
        mf:close()
        if mline then md5_val = mline:match("^(%w+)") or "" end
    end

    if sz > 0 and (total_size == 0 or sz == total_size) then
        print(string.format("[Turbo-Upload] Sucesso: %s (%d bytes, MD5: %s)", target_path, sz, md5_val))
        safe_ws_send(sock, json.encode({
            type = "file_upload_done",
            upload_id = upload_id,
            term_id = term_id,
            filename = clean_name,
            target_path = target_path,
            size = sz,
            md5 = md5_val,
            success = true
        }), 1)

        -- Mensagem informativa no console terminal
        if active_term and active_term.in_fd and tostring(active_term.id) == tostring(term_id) then
            local esc = string.char(27)
            local mb_str = string.format("%.2f MB", sz / (1024 * 1024))
            local term_notify = "\r\n" .. esc .. "[1;32m[✓ Arquivo recebido em " .. target_path .. " (" .. mb_str .. " | MD5: " .. (md5_val ~= "" and md5_val or "OK") .. ")]" .. esc .. "[0m\r\n"
            safe_ws_send(sock, json.encode({
                type = "term_output",
                term_id = term_id,
                data = nixio.bin.b64encode(term_notify)
            }), 1)
        end
    else
        print(string.format("[Turbo-Upload] Falha no download: obtidos %d bytes de %d esperados", sz, total_size))
        safe_ws_send(sock, json.encode({
            type = "file_upload_done",
            upload_id = upload_id,
            term_id = term_id,
            filename = clean_name,
            target_path = target_path,
            size = sz,
            md5 = md5_val,
            success = false,
            error = string.format("Falha ao baixar arquivo (obtidos %d de %d bytes)", sz, total_size)
        }), 1)
    end
end

-- ============================================================================
-- GERENCIADOR DE TÚNEIS TCP (MODELO A - WEBSOCKET REVERSE PROXY)
-- ============================================================================
local active_tunnels = {}

local function open_tunnel(tunnel_id, target_port)
    local tid_str = tostring(tunnel_id)
    target_port = tonumber(target_port) or 80
    local s = socket.tcp()
    s:settimeout(5)

    -- uhttpd do TP-Link redireciona acessos locais (127.0.0.1) para HTTPS (302 Found sem Content-Length),
    -- quebrando o proxy reverso HTTP da Cloud. Portanto, conectamos prioritariamente ao IP LAN ativo (ex: 192.168.0.1).
    local target_host = get_lan_ip()
    local ok, err = s:connect(target_host, target_port)
    if not ok and target_host ~= "192.168.0.1" then
        target_host = "192.168.0.1"
        ok, err = s:connect(target_host, target_port)
    end
    if not ok then
        target_host = "127.0.0.1"
        ok, err = s:connect(target_host, target_port)
    end
    if ok then
        s:settimeout(0)
        active_tunnels[tid_str] = {
            id = tunnel_id,
            sock = s,
            port = target_port,
            created_at = socket.gettime()
        }
        print(string.format("[>] Túnel TCP #%s conectado com sucesso a %s:%d", tid_str, target_host, target_port))
    else
        print(string.format("[-] Falha ao conectar túnel TCP #%s a %s:%d: %s", tid_str, target_host, target_port, tostring(err)))
    end
end

local function close_tunnel(tunnel_id)
    local tid_str = tostring(tunnel_id)
    local t = active_tunnels[tid_str]
    if t then
        if t.sock then pcall(function() t.sock:close() end) end
        active_tunnels[tid_str] = nil
        print(string.format("[x] Túnel TCP #%s fechado", tid_str))
    end
end

local function close_all_tunnels()
    for tid, _ in pairs(active_tunnels) do
        close_tunnel(tid)
    end
end

-- ============================================================================
-- LOOP PRINCIPAL DO AGENTE
-- ============================================================================
print("========================================================")
print("  Conexao Povos da Floresta - Agente de Nuvem (Lua)     ")
print("  Iniciando comunicacao com " .. CONFIG.server_host .. ":" .. CONFIG.server_port)
print("========================================================")

while true do
    local ok_cycle, cycle_err = pcall(function()
    load_uci_config()
    print(string.format("[*] Tentando conectar a %s:%d ...", CONFIG.server_host, CONFIG.server_port))
    local sock, err = socket.tcp()
    if sock then
        sock:settimeout(5)
        local ok_conn, conn_err = sock:connect(CONFIG.server_host, CONFIG.server_port)
        if not ok_conn then
            pcall(function() sock:close() end)
            sock = nil
            err = conn_err
        end
    end

    if not sock then
        print("[-] Falha ao conectar (" .. tostring(err) .. "). Tentando novamente em 5 segundos...")
        socket.sleep(5)
    else
        sock:settimeout(5)
        print("[+] Socket TCP conectado!")

        local is_tls_ok = true
        if CONFIG.use_ssl then
            local ssl_ok, ssl = pcall(require, "ssl")
            if not ssl_ok then
                print("[-] Erro: Modulo LuaSec (ssl) nao disponivel!")
                pcall(function() sock:close() end)
                is_tls_ok = false
            else
                local params = {
                    mode = "client",
                    protocol = "any",
                    verify = "none",
                    options = "all"
                }
                local sconn, serr = ssl.wrap(sock, params)
                if not sconn then
                    print("[-] Falha ao inicializar TLS: " .. tostring(serr))
                    sock:close()
                    is_tls_ok = false
                else
                    sock = sconn
                    local hok, herr = sock:dohandshake()
                    if not hok then
                        print("[-] Falha no Handshake TLS: " .. tostring(herr))
                        sock:close()
                        is_tls_ok = false
                    else
                        print("[+] Conexao segura TLS (WSS) estabelecida com sucesso!")
                    end
                end
            end
        end

        if not is_tls_ok then
            socket.sleep(5)
        else
            print("[+] Enviando Handshake WebSocket...")

            -- Handshake HTTP Upgrade
            local function url_encode(str)
                if not str then return "" end
                str = string.gsub(str, "\r?\n", "\r\n")
                str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
                    return string.format("%%%02X", string.byte(c))
                end)
                str = string.gsub(str, " ", "%%20")
                return str
            end

            local clean_name = url_encode(CONFIG.device_name or "BE220")
            local is_ad_str = (CONFIG.adopted == "1" or CONFIG.adopted == true or CONFIG.adopted == "true") and "1" or "0"
            local host_header = CONFIG.server_host
            if (CONFIG.use_ssl and CONFIG.server_port ~= 443) or (not CONFIG.use_ssl and CONFIG.server_port ~= 80) then
                host_header = string.format("%s:%d", CONFIG.server_host, CONFIG.server_port)
            end

            local req = string.format(
                "GET %s?mac=%s&name=%s&adopted=%s HTTP/1.1\r\n" ..
                "Host: %s\r\n" ..
                "Upgrade: websocket\r\n" ..
                "Connection: Upgrade\r\n" ..
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ..
                "Sec-WebSocket-Version: 13\r\n" ..
                "X-Device-MAC: %s\r\n" ..
                "X-Device-Name: %s\r\n" ..
                "X-Device-Adopted: %s\r\n\r\n",
                CONFIG.server_path, DEVICE_MAC, clean_name, is_ad_str,
                host_header,
                DEVICE_MAC, clean_name,
                is_ad_str
            )

            sock:send(req)
            local resp_header, rerr = sock:receive("*l")

            if not resp_header or not string.match(resp_header, "101") then
                print("[-] Handshake rejeitado pelo servidor: " .. tostring(resp_header))
                sock:close()
                socket.sleep(5)
            else
                -- Descarta o restante dos headers do handshake
                while true do
                    local hline = sock:receive("*l")
                    if not hline or hline == "" then break end
                end

            print("[OK] WebSocket Estabelecido com Sucesso com o Controlador!")

            -- Envia primeiro pacote de telemetria
            local first_telem = collect_telemetry()
            safe_ws_send(sock, json.encode({ type = "telemetry", data = first_telem }), 1)

            local last_telem_time = socket.gettime()
            local last_rx_time = socket.gettime()

            -- Loop de comunicação do WebSocket
            while true do
                local now = socket.gettime()

                -- Dead-peer detection: se ficar mais de 35s sem receber nenhum frame/pong/ping do servidor, força reconexão
                if (now - last_rx_time) > 35 then
                    print("[!] Servidor sem resposta por >35s (outage/queda silenciosa). Reconectando...")
                    break
                end

                -- Envio periódico de telemetria + Ping ativo para confirmar que o servidor está vivo
                if (now - last_telem_time) >= CONFIG.telemetry_interval then
                    local telem = collect_telemetry()
                    local telem_msg = json.encode({ type = "telemetry", data = telem })
                    local ok, send_err = safe_ws_send(sock, telem_msg, 1)
                    if not ok then
                        print("[-] Erro ao enviar telemetria: " .. tostring(send_err))
                        break
                    end
                    -- Envia Ping WebSocket (opcode 9) para exigir Pong (opcode 10) do servidor
                    safe_ws_send(sock, "ping", 9)
                    last_telem_time = now
                end

                -- Leitura e processamento de frames do servidor (com batching de alta vazão durante upload)
                local max_frames = active_upload and 40 or 5
                local frames_read = 0
                local should_break = false
                while frames_read < max_frames do
                    local frame, dec_err = ws_decode(sock)
                    if not frame then
                        if dec_err and dec_err ~= "timeout" and dec_err ~= "wantread" then
                            print("[-] Conexão perdida: " .. tostring(dec_err))
                            should_break = true
                        end
                        break
                    end
                    frames_read = frames_read + 1
                    last_rx_time = socket.gettime()

                    -- Ping -> responde Pong
                    if frame.opcode == 9 then
                        safe_ws_send(sock, frame.payload, 10)
                    -- Pong -> confirma servidor ativo
                    elseif frame.opcode == 10 then
                        -- last_rx_time já atualizado acima
                    -- Close frame
                    elseif frame.opcode == 8 then
                        print("[!] Servidor solicitou encerramento.")
                        should_break = true
                        break
                    -- Text frame (JSON)
                    elseif frame.opcode == 1 then
                        local ok, msg = pcall(json.decode, frame.payload)
                        if ok and type(msg) == "table" then
                            -- COMANDO REMOTO
                            if msg.type == "command" then
                                print("[>] Comando recebido: " .. tostring(msg.action))
                                local res = handle_command(msg)
                                safe_ws_send(sock, json.encode({
                                    type = "cmd_res",
                                    cmd_id = msg.cmd_id,
                                    res = res
                                }), 1)
                            -- TERMINAL WEB: INICIAR SESSÃO PTY
                            elseif msg.type == "term_start" then
                                print("[>] Iniciando sessão PTY para terminal: " .. tostring(msg.term_id))
                                start_terminal(sock, msg.term_id)
                            -- TERMINAL WEB: ENTRADA DE DADOS (TECLADO)
                            elseif msg.type == "term_input" then
                                if active_term and active_term.in_fd then
                                    local data = msg.data or ""
                                    if data:find(string.char(3)) then
                                        -- Interrupção de comando (Ctrl+C / SIGINT)
                                        if active_term.pid then
                                            os.execute(string.format("for c in $(pgrep -P %d 2>/dev/null); do kill -INT $c 2>/dev/null; done", active_term.pid))
                                            os.execute(string.format("kill -INT %d 2>/dev/null", active_term.pid))
                                        end
                                        active_term.in_fd:write("\n")
                                    else
                                        local raw = data:gsub("\r", "\n")
                                        active_term.in_fd:write(raw)
                                    end
                                end
                            -- TERMINAL WEB: ENCERRAR SESSÃO
                            elseif msg.type == "term_stop" then
                                print("[x] Encerrando sessão PTY de terminal: " .. tostring(msg.term_id))
                                stop_terminal(msg.term_id)
                            -- UPLOAD DE ARQUIVOS (WEB TERMINAL -> ROTEADOR /tmp)
                            elseif msg.type == "file_upload_start" then
                                handle_file_upload_start(sock, msg)
                            elseif msg.type == "file_upload_chunk" then
                                handle_file_upload_chunk(sock, msg)
                            elseif msg.type == "file_upload_end" then
                                handle_file_upload_end(sock, msg)
                            elseif msg.type == "fast_file_download" then
                                handle_fast_file_download(sock, msg)
                            -- TÚNEL TCP REVERSO: ABRIR CANAL LOCAL
                            elseif msg.type == "tcp_tunnel_open" then
                                open_tunnel(msg.tunnel_id, msg.target_port)
                            -- TÚNEL TCP REVERSO: DADOS DO BROWSER PARA O WEBSERVER LOCAL
                            elseif msg.type == "tcp_tunnel_data" then
                                local t = active_tunnels[tostring(msg.tunnel_id)]
                                if t and t.sock and msg.data then
                                    local raw = nixio.bin.b64decode(msg.data)
                                    if raw and #raw > 0 then
                                        if raw:find("form=login") then
                                            local f = io.open("/tmp/last_login_req.txt", "w")
                                            if f then f:write(raw); f:close() end
                                            print("[DEBUG] Capturada requisicao form=login: " .. tostring(#raw) .. " bytes")
                                        end
                                        pcall(function()
                                            local sent = 0
                                            local total = #raw
                                            t.sock:settimeout(5)
                                            while sent < total do
                                                local n, err, part = t.sock:send(raw, sent + 1)
                                                if n then
                                                    sent = n
                                                elseif part then
                                                    sent = part
                                                else
                                                    break
                                                end
                                            end
                                            t.sock:settimeout(0)
                                        end)
                                    end
                                end
                            -- TÚNEL TCP REVERSO: FECHAR CANAL
                            elseif msg.type == "tcp_tunnel_close" then
                                close_tunnel(msg.tunnel_id)
                            -- GESTÃO DE ADOÇÃO: COMANDO VINDO DA CLOUD (PADRÃO UNIFI)
                            elseif msg.type == "set_adopted" then
                                local is_ad = (msg.adopted == true or msg.adopted == 1 or msg.adopted == "1")
                                CONFIG.adopted = is_ad and "1" or "0"
                                print(string.format("[>] Status de adocao atualizado pela Cloud: %s", CONFIG.adopted))
                                os.execute(string.format("/sbin/uci set floresta_cloud.global.adopted='%s' 2>/dev/null", CONFIG.adopted))
                                if msg.name and msg.name ~= "" then
                                    CONFIG.device_name = msg.name
                                    os.execute(string.format("/sbin/uci set floresta_cloud.global.device_name='%s' 2>/dev/null", msg.name))
                                end
                                os.execute("/sbin/uci commit floresta_cloud 2>/dev/null")
                                -- Sincroniza configuracao para as particoes persistentes /data e /user_data1
                                os.execute("mkdir -p /data/etc/config && cp /etc/config/floresta_cloud /data/etc/config/ 2>/dev/null")
                                os.execute("mkdir -p /user_data1/etc/config && cp /etc/config/floresta_cloud /user_data1/etc/config/ 2>/dev/null")
                                os.execute("sync")
                                -- Envia confirmacao a nuvem
                                safe_ws_send(sock, json.encode({
                                    type = "adopted_ack",
                                    mac = DEVICE_MAC,
                                    adopted = is_ad
                                }), 1)
                            end
                        end
                    end
                end
                if should_break then break end

                -- Se há terminal ativo, lê saída de comandos do roteador de forma 100% não-bloqueante
                if active_term and active_term.out_fd then
                    while true do
                        local chunk = active_term.out_fd:read(4096)
                        if chunk and #chunk > 0 then
                            -- Codifica em base64: server.php faz base64_decode() para obter bytes PTY raw
                            local b64_chunk = nixio.bin.b64encode(chunk)
                            safe_ws_send(sock, json.encode({
                                type = "term_output",
                                term_id = active_term.id,
                                data = b64_chunk
                            }), 1)
                        else
                            break
                        end
                    end
                end

                -- Trata leitura de dados nos túneis TCP ativos com alto rendimento e proteção contra quedas
                local had_tunnel_activity = false
                for tid, t in pairs(active_tunnels) do
                    local drain_count = 0
                    while drain_count < 20 do
                        local ok_rec, chunk, status, partial = pcall(function()
                            if t and t.sock then
                                return t.sock:receive(8192)
                            end
                            return nil, "closed"
                        end)

                        if not ok_rec then
                            safe_ws_send(sock, json.encode({
                                type = "tcp_tunnel_close",
                                tunnel_id = t.id
                            }), 1)
                            close_tunnel(tid)
                            break
                        end

                        local data = chunk or partial
                        if data and #data > 0 then
                            had_tunnel_activity = true
                            if data:find("403 Forbidden") then
                                local f = io.open("/tmp/last_403_resp.txt", "w")
                                if f then f:write(data); f:close() end
                                print("[DEBUG] Capturada resposta 403 Forbidden de uhttpd")
                            end
                            local b64 = nixio.bin.b64encode(data)
                            safe_ws_send(sock, json.encode({
                                type = "tcp_tunnel_data",
                                tunnel_id = t.id,
                                data = b64
                            }), 1)
                        end
                        if status == "closed" then
                            safe_ws_send(sock, json.encode({
                                type = "tcp_tunnel_close",
                                tunnel_id = t.id
                            }), 1)
                            close_tunnel(tid)
                            break
                        end
                        if not chunk or #chunk < 8192 then
                            break
                        end
                        drain_count = drain_count + 1
                    end
                end

                if had_tunnel_activity or active_upload then
                    socket.sleep(0.001)
                else
                    socket.sleep(0.05)
                end
            end

            pcall(function() sock:close() end)
            if active_upload and active_upload.file then
                pcall(function() active_upload.file:close() end)
                active_upload = nil
            end
            if active_term then stop_terminal(active_term.id) end
            close_all_tunnels()
            print("[-] Desconectado do servidor. Tentando reconectar em 3 segundos...")
            socket.sleep(3)
        end
    end
end
    end)
    if not ok_cycle then
        print("[!] Erro inesperado no ciclo principal: " .. tostring(cycle_err) .. ". Reiniciando ciclo em 3s...")
        socket.sleep(3)
    end
end
