#!/usr/bin/lua
-- /etc/captiveportal/captive_redirector.lua
-- Portal Captivo 3000 — Redirecionador HTTP Dedicado (Archer BE220)
--
-- Escuta na porta 2080 (destino das regras NAT do iptables para porta 80 externa)
-- Responde HTTP 302 Found imediato para qualquer teste de conectividade (Android, iOS, Windows)
-- sem passar pelo uhttpd, evitando o bug de HTTPS do firmware TP-Link.

local socket = require("socket")

local PORT = 2080
local ROUTER_DOMAIN = "roteador.conexaopovosdafloresta.org.br"
local ROUTER_IP = "192.168.0.1"

-- Lê domínio e IP do UCI nativo ou da interface ativa br-lan
pcall(function()
    local ucursor = require("uci").cursor()
    local d = ucursor:get("captiveportal", "global", "router_domain")
    if d and d ~= "" then ROUTER_DOMAIN = d end
    local net_ip = ucursor:get("network", "lan", "ipaddr")
    if net_ip and net_ip ~= "" then ROUTER_IP = net_ip end
    local ip = ucursor:get("captiveportal", "global", "router_ip")
    if ip and ip ~= "" and ip ~= "192.168.0.1" then ROUTER_IP = ip end
end)

pcall(function()
    local f = io.popen("ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1")
    if f then
        local live_ip = f:read("*l")
        f:close()
        if live_ip and live_ip ~= "" then ROUTER_IP = live_ip end
    end
end)

local PORTAL_URL = "http://" .. ROUTER_IP .. "/captive/"

local server, err = socket.bind("0.0.0.0", PORT)
if not server then
    io.stderr:write("Erro ao vincular na porta " .. PORT .. ": " .. tostring(err) .. "\n")
    os.exit(1)
end
server:settimeout(0.5)

-- Grava arquivo de PID
local pid_file = "/var/run/captive_redirector.pid"
local pf = io.open("/proc/self/stat", "r")
if pf then
    local pid = pf:read("*number")
    pf:close()
    if pid then
        local f = io.open(pid_file, "w")
        if f then
            f:write(tostring(pid) .. "\n")
            f:close()
        end
    end
end

local function url_encode(str)
    if not str then return "" end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

while true do
    local client = server:accept()
    if client then
        client:settimeout(1.0)
        local line = client:receive("*l")
        if line then
            local method, uri = line:match("^(%a+)%s+(%S+)")
            local host = ""

            -- Lê os cabeçalhos HTTP
            while true do
                local h = client:receive("*l")
                if not h or h == "" or h == "\r" then break end
                local k, v = h:match("^([%w%-]+):%s*(.+)")
                if k and k:lower() == "host" then
                    host = v:gsub("[\r\n%s]", "")
                    host = host:gsub(":%d+$", "")
                end
            end

            local dest = PORTAL_URL

            -- Identifica se é sonda automática de captive portal
            local is_probe = false
            if uri and (uri:find("generate_204") or uri:find("gen_204") or 
                        uri:find("hotspot%-detect") or uri:find("ncsi%.txt") or 
                        uri:find("connecttest") or uri:find("canonical%.html") or
                        uri:find("success%.txt")) then
                is_probe = true
            end
            if host and (host:find("gstatic") or host:find("apple") or 
                         host:find("msft") or host:find("google") or
                         host:find("akamaitechnologies") or host:find("cloudflare")) then
                is_probe = true
            end

            -- Se a requisição for direcionada ao próprio roteador (IP ou domínios locais),
            -- garante acesso direto aos recursos locais (WebUI TP-Link, captive, cgi-bin)
            local is_router_host = (host == ROUTER_IP or host == "192.168.0.1" or host == "192.168.12.1" or
                                    host == "127.0.0.1" or host == "tplinkwifi.net" or host == "tplinklogin.net" or
                                    host == ROUTER_DOMAIN)
            if is_router_host then
                if uri and (uri:find("^/captive") or uri:find("^/portal")) then
                    dest = PORTAL_URL
                else
                    dest = "http://" .. ROUTER_IP .. (uri or "/webpages/index.html")
                end
            elseif not is_probe and host ~= "" and host ~= ROUTER_DOMAIN and host ~= ROUTER_IP then
                local orig = "http://" .. host .. (uri or "/")
                dest = PORTAL_URL .. "?next=" .. url_encode(orig)
            end

            -- Registra log de conexão
            local peer_ip = client:getpeername()
            local lf = io.open("/tmp/captive_redirector.log", "a")
            if lf then
                lf:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(peer_ip) .. " " .. tostring(method) .. " " .. tostring(host) .. tostring(uri) .. " -> 302 " .. tostring(dest) .. "\n")
                lf:close()
            end

            local body = "<!DOCTYPE html><html><head><title>Portal Captivo</title>" ..
                         "<meta http-equiv=\"refresh\" content=\"0; url=" .. dest .. "\">" ..
                         "</head><body><a href=\"" .. dest .. "\">Acessar Internet</a></body></html>\r\n"

            local response = "HTTP/1.1 302 Found\r\n" ..
                             "Location: " .. dest .. "\r\n" ..
                             "Connection: close\r\n" ..
                             "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n" ..
                             "Pragma: no-cache\r\n" ..
                             "Expires: 0\r\n" ..
                             "Content-Type: text/html; charset=UTF-8\r\n" ..
                             "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body

            client:send(response)
        end
        client:close()
    end
end
