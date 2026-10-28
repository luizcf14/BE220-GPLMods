# Memória de Projeto e Diretrizes do Agente — TP-Link Archer BE220 / Floresta Controller

Este documento consolida a arquitetura, regras estritas de desenvolvimento, armadilhas conhecidas (gotchas) e procedimentos operacionais adquiridos ao longo de todo o desenvolvimento da solução **Conexão Povos da Floresta**.

---

## 1. Regras Estritas do Projeto (Invioláveis)

### 1.1 Preservação da Restauração de Configuração (`floresta_agent`)
- **REGRA DE OURO:** NUNCA remover ou desativar a rotina de restauração e sincronização de configurações de rede/cloud em `/etc/init.d/floresta_agent` ou `web_deploy/floresta_agent`.
- **Motivo:** Quando um roteador é novo de fábrica ou passa por factory reset, os arquivos em `/etc/config` voltam ao padrão do GPL. A rotina que restaura a partir de `/data/etc/config` e `/user_data1/etc/config` é essencial para que o equipamento suba com as credenciais, portal captivo e configurações de nuvem intactas.

### 1.2 Arquitetura Cloud Run de Instância Única e Persistência GCS
- O Cloud Controller (`floresta-controller`) roda no Google Cloud Run mantendo conexões persistentes em memória (`--min-instances=1`, `--max-instances=1`, `--concurrency=500`, `--no-cpu-throttling`, `--session-affinity`, `--execution-environment=gen2`).
- **Persistência Permanente de Dados:** O diretório `/app/data` é montado diretamente no bucket Google Cloud Storage `gs://<GCS_BUCKET>/` via Cloud Storage FUSE (`--add-volume` e `--add-volume-mount`). Todos os arquivos de adoção (`adopted_devices.json`) e bloqueio DNS (`default_dns_blocklist.json`) sobrevivem intactos a qualquer restart ou deploy de novas revisões.
- Não adicionar dependências externas de banco ou Redis sem alinhamento prévio; todo o estado vive na memória assíncrona do PHP e é sincronizado atomicamente com o bucket GCS e a Flash dos roteadores.

### 1.3 Scripts Temporários e Ferramentas Ad-Hoc (`scratch/`)
- Todos os scripts temporários, ferramentas de teste, diagnósticos descartáveis, automações (Node.js/Python/Shell/PowerShell) e rotinas auxiliares criadas pelo agente devem ser salvos e executados obrigatoriamente dentro da pasta `scratch/` do workspace (`GPL/scratch/`).
- **Autonomia Total de Execução:** NÃO é necessário pedir permissão ao usuário para rodar scripts (Node.js, Python, Shell, PowerShell, etc.) criados na pasta `scratch/`. Execute-os de forma direta e proativa.
- **NUNCA** poluir a raiz do projeto ou outras pastas da árvore com scripts temporários.

### 1.4 Proteção contra Limpeza de `/etc/config` no Primeiro Boot (`loadconfig` / `S10boot`)
- **Causa Raiz:** No boot do Archer BE220 (`S10boot`), o binário `/sbin/loadconfig` (`luci.sys.config.reloadconfig()`) executa `rm -rf /etc/config /tmp/etc/*` e extrai o XML criptografado da partição NVRAM (`user-config`) para `/etc/config`.
- Em um roteador novo de fábrica (onde `/data/captiveportal/captiveportal` ainda não existe), isso apaga `/etc/config/captiveportal` e `/etc/config/floresta_cloud` antes do `S95captiveportal` rodar, fazendo com que os perfis de QoS (`visitante`, `basico`, `premium`, `ilimitado`) desapareçam da WebUI.
- **Solução Obrigatória:**
  1. `build_rootfs.sh` salva cópias imutáveis fora de `/etc/config` em `/etc/captiveportal/captiveportal.default` e `/etc/captiveportal/floresta_cloud.default`.
  2. Tanto `/etc/init.d/captiveportal` (`_load_config` chamado **antes** de `config_load captiveportal`) quanto `/www/cgi-bin/captive_admin_api` (`_ensure_config`) verificam se `config profile` existe em `/etc/config/captiveportal`; caso não exista, restauram automaticamente os 4 perfis padrão e persistem em `/data/captiveportal/captiveportal` e `/user_data1/captiveportal/captiveportal`.

### 1.5 Versão Fixa `77.0.1 Build 20991231 rel.99999` e Bloqueio de OTA Oficial TP-Link
- Para impedir que o roteador exiba alertas de atualização ou baixe firmwares oficiais `1.x.x` da TP-Link que sobrescreveriam o sistema customizado:
  1. A versão na partição NVRAM `soft-version` (`mtd10_misc2`) e em `/etc/partition_config/soft-version` é fixada em `soft_ver:77.0.1 Build 20991231 rel.99999` (mantendo o formato `X.Y.Z Build YYYYMMDD rel.NNNNN` exigido pelo parser Lua `cloud_getFirmware.lua`).
  2. O script `/etc/init.d/floresta_agent` verifica no boot se `/sbin/getfirm SOFTVERSION` inicia com `77.0.1`; caso contrário, grava automaticamente `77.0.1 Build 20991231 rel.99999` na partição NVRAM `soft-version` via `nvrammanager -w` e limpa `cloud_config.upgrade_info`, `cloud_config.new_firmware.fw_new_notify='0'` e `auto_upgrade.upgrade.enable='off'`.
  3. O domínio `ota-download.tplinkcloud.com` é bloqueado em `/etc/hosts` (`0.0.0.0 ota-download.tplinkcloud.com`).

---

## 2. Arquitetura do Floresta Cloud Controller (Estilo UniFi)

- **GCP Project:** `<GCP_PROJECT_ID>`
- **Serviço:** `floresta-controller`
- **Região:** `southamerica-east1` (São Paulo)
- **URL Pública (HTTPS):** `https://<CONTROLLER_HOST>`
- **WebSocket dos Roteadores:** `wss://<CONTROLLER_HOST>/ws/router`
- **Deploy Automático:** Executar via PowerShell `.\deploy_cloud_run.ps1`.

### 2.1 Túnel Reverso Web (Acesso ao LuCI / WebUI do Roteador)
- Funciona inteiramente sobre a conexão WebSocket existente do roteador (`Model A`), sem exigir IP público no roteador, sem abrir portas de entrada e sem VPN.
- **Mensagens do protocolo:**
  - `tcp_tunnel_open` — Cria conexão TCP local com `uhttpd` (porta 80).
  - `tcp_tunnel_data` — Dados base64 trafegados bidirecionalmente.
  - `tcp_tunnel_close` — Encerramento do socket do túnel.

### 2.2 ARMADILHA CRÍTICA RESOLVIDA: HTTP 429 ("Rate exceeded") e 503
- **Causa Raiz 1 (Saturação do `uhttpd`):** O servidor web `uhttpd` do OpenWrt tem `option max_requests 3`. Quando o navegador carrega a WebUI, ele dispara 3 a 5 requisições HTTP paralelas. Se o servidor na nuvem não souber quando a resposta HTTP terminou, os sockets ficam retidos por 25 segundos, esgotando os workers locais do roteador.
- **Causa Raiz 2 (Queda Malformada no Cloud Run):** Fechar conexões HTTP com `@fclose()` sem enviar cabeçalhos de resposta faz o Cloud Run classificar a requisição como erro 503 (*"malformed response or connection error"*). Quando múltiplas requisições sofrem isso, o Cloud Run marca a instância como com falha e passa a rejeitar requisições na borda com **`429 Rate exceeded.`**.
- **SOLUÇÃO OBRIGATÓRIA NO `server.php`:**
  1. Inspecionar `Content-Length` e o terminador `0\r\n\r\n` de `Transfer-Encoding: chunked` em TODAS as respostas de túnel HTTP (incluindo LuCI JSON).
  2. Assim que o último byte for enviado ao navegador, chamar `closeClient($cid)` imediatamente (fecha o socket HTTP e envia `tcp_tunnel_close` ao roteador em milissegundos).
  3. No caso de timeout (>20s) ou desconexão do roteador, NUNCA fechar o socket sem emitir previamente uma resposta HTTP válida:
     `HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: 15\r\nConnection: close\r\n\r\nGateway Timeout`

### 2.3 ARMADILHA CRÍTICA DE REFERÊNCIA PHP (Socket Corruption Bug)
- **NUNCA** usar atribuição por referência como `$meta = &$clientMeta[$clientId]` dentro do laço de leitura de sockets se houver laços aninhados ou modificações. Em PHP, isso transforma a variável em referência persistente, fazendo com que conexões de roteadores subsequentes sejam acidentalmente reclassificadas como `type = 'terminal'`.
- Sempre utilizar leitura direta `$clientMeta[$clientId]['campo']` ou limpar explicitamente referências (`unset($meta)`).

### 2.4 ARMADILHA CRÍTICA: Oscilação de Status ("Reconectando..." <-> "Controlador Conectado")
- **Causa Raiz 1 (Timeout de Inatividade no Cloud Run):** O Cloud Run encerra conexões WebSocket ociosas após ~60 segundos sem tráfego. Tanto o frontend (`app.js`) quanto o backend (`server.php`) devem implementar heartbeat bidirecional com ping a cada 15 segundos.
- **Causa Raiz 2 (Crash Silencioso por Codificação Não-UTF8):** Nomes com acentuação (ex: "<NOME>") enviados por roteadores via cabeçalhos HTTP (`X-Device-Name`) ou URLs em ISO-8859-1 fazem o `json_encode()` nativo do PHP falhar retornando `false`. Devido ao `declare(strict_types=1);`, chamar `sendToClient($conn, false)` disparava um `Fatal error: TypeError`, derrubando o processo PHP com `exit(255)`. O Cloud Run reiniciava o container, os roteadores e administradores reconectavam, e o crash se repetia em loop contínuo.
- **SOLUÇÃO OBRIGATÓRIA:**
  1. Sanitizar todas as entradas de texto com `safeUtf8()` (convertendo ISO-8859-1/Windows-1252 para UTF-8).
  2. Utilizar `safeJsonEncode()` com a flag `JSON_INVALID_UTF8_SUBSTITUTE` em todos os broadcasts e envios WebSocket.
  3. No `sendToClient()`, aceitar `mixed $data` e converter arrays ou filtrar `false`/`null` sem interromper o processo.
  4. No agente Lua (`floresta_agent.lua`), encodar o nome do dispositivo com `url_encode()` antes de inseri-lo em cabeçalhos HTTP.

---

## 3. Terminal Remoto Web (Web SSH / xterm.js)

- O console do navegador conecta em `wss://.../ws/terminal?mac=...`.
- O roteador roda `/bin/ash -l -i` através de FIFOs não-bloqueantes (`/tmp/floresta_term_in_<id>` e `/tmp/floresta_term_out_<id>`).
- O servidor PHP repassa a saída do PTY diretamente ao navegador como **frame binário WebSocket (opcode 0x02)** para renderização imediata de sequências ANSI e cores no xterm.js.

---

## 4. Hardware e Firmware do TP-Link Archer BE220

- **IP Padrão de Fábrica:** `192.168.0.1` (sub-rede `192.168.0.0/24`)
- **IP do U-Boot / TFTP de Recuperação:** `192.168.12.1` (servidor TFTP no PC: `192.168.12.2`)
- **Credenciais SSH / Console Serial:** Usuário `root`, Senha `<ROOT_PASSWORD>`
- **Partições Flash UBI Principais:**
  - `rootfs1` / `rootfs2`: 33 MB cada em modo dual-bank; ou `0x4000000` (64 MB) em modo single-bank expandido.
  - `/data` (`mtd9`): Partição de persistência local para binários e configurações.
  - `/user_data1`: Partição secundária de persistência.

### 4.1 Comandos de Apontamento ao Controlador (No Roteador)
```sh
set-inform https://<CONTROLLER_HOST>/ws/router
# ou manualmente via uci:
uci set floresta_cloud.global.server_url="https://<CONTROLLER_HOST>/ws/router"
uci commit floresta_cloud
/etc/init.d/floresta_agent restart
```

### 4.2 Compilação de RootFS e Geração de Recovery
- **RootFS modificado:** `wsl bash /mnt/f/OpenWRT/.../build_rootfs.sh`
- **Recovery Bundle (FIT + Header TP-Link para WPS Web UI):** `wsl -d Ubuntu-24.04 bash /mnt/f/OpenWRT/.../generate_recovery_bundle.sh`
  - Gera dois arquivos:
    1. `recovery_bundle.bin` — Pacote FIT envolvido pelo **cabeçalho TP-Link (`0x1014` bytes + `fwup-ptn` com `support-list` e `soft-version` + MD5 com salt)**. Obrigatório para a tela web de **Rescue Mode (`http://192.168.0.1`)**.
    2. `recovery_bundle_raw_fit.bin` — Pacote Broadcom FIT puro (`0xd00dfeed` no byte 0), próprio para gravação via SSH com `/sbin/bcm_flasher` (com padding de 512 bytes).

### 4.3 Arquitetura de Validação do Rescue Mode no U-Boot (`nm_tpFirmwareCheck`)
- Quando um firmware é enviado via HTTP POST na tela de Rescue Mode (`http://192.168.0.1`), a função `http_update_image` do U-Boot invoca `nm_api_getOSoffset` $\rightarrow$ `nm_tpFirmwareCheck`:
  1. **Fluxo Criptografado (`fw-type:Cloud` / `fw-type:Test` em `0x14`):** Exige assinatura RSA-2048 PSS válida em `0x0130..0x0230` e descriptografa o payload a partir de `0x0230` com AES-128-CBC.
  2. **Fluxo Comum Sem Criptografia (`"Firmware process common."`):** Ativado quando os bytes `0x14..0x1013` estão zerados (sem `fw-type:`). O U-Boot:
     - Verifica se o tamanho total em big-endian nos primeiros 4 bytes (`0x00..0x03`) é `<= upload_len`.
     - Valida o hash MD5 nos bytes `0x04..0x13` usando o salt fixo da TP-Link (`7a2b15ed9b98596de504ab44ac2a9f4e`) sobre todo o corpo a partir de `0x14` (`nm_tpFirmwareMd5Check`).
     - Lê a tabela `fwup-ptn` em `0x1014` (`support-list` e `soft-version`), valida `product_name` / `product_ver` / `special_id` e calcula o offset exato onde inicia o pacote FIT Broadcom (`0xd00dfeed`), repassando-o para `flash_upgrade_img_bundle()`.
- **Gotcha Crítico:** Enviar um arquivo FIT puro (`0xd00dfeed` no offset 0) na tela de Rescue Mode faz `nm_tpFirmwareCheck` falhar por ausência do cabeçalho TP-Link e da partição `support-list`.

### 4.4 Descriptografia de Firmwares Oficiais TP-Link (`1.1.7-P1` / `fw-type:Cloud`)
- Os firmwares oficiais assinados da TP-Link (ex: `be220v1-be230v2-be3600ProJP-all-sp1-up-ver1-1-7-P1..._2048_signed.bin`) usam um envelope híbrido RSA-2048 PSS + AES-128-CBC:
  - A chave pública RSA-2048 (451 bytes PEM) reside em `/usr/bin/nvrammanager` no offset `0x19240` (e também no binário do U-Boot em `mtd7_bootfs1.bin`).
  - Elevando os 256 bytes de `0x0130..0x0230` ao expoente público `e = 65537 mod n`, obtém-se um bloco `EM` codificado com **PKCS#1 v2.1 EMSA-PSS (SHA-256, MGF1, salt de 32 bytes)**.
  - Após aplicar o XOR da máscara `MGF1-SHA256(H, 223)` sobre `maskedDB`, os **últimos 32 bytes do `DB` (o salt PSS)** contêm diretamente:
    - **Primeiros 16 bytes:** Chave `AES-128`.
    - **Últimos 16 bytes:** Vetor de Inicialização (`IV`).
  - Com essa chave e IV, descriptografa-se em modo `AES-128-CBC` todo o arquivo a partir do offset `0x0230` até o final (com truncamento ao múltiplo de 16 bytes), revelando o `fwup-ptn` em `0x1014` e o pacote FIT Broadcom (`0xd00dfeed`) logo após a partição `soft-version`.
  - **Nota sobre o FIT Oficial `1.1.7-P1`:** O FIT interno da atualização oficial contém apenas as imagens `bootfs_6764_a0+` e `nand_squashfs` (não inclui `loader`).

---

## 5. Autenticação, Usuários e RBAC do Cloud Controller

- **Armazenamento:** `/app/data/users.json` (bcrypt, `tv` = token version) e `/app/data/auth_secret.key` (segredo HMAC; override via env `AUTH_SECRET`) — ambos no bucket GCS. **NUNCA** colocar `users.json`/`auth_secret.key`/`setup_code.txt` em `cloudController/data/` local (vai para a imagem Docker).
- **Perfis:** `viewer` (leitura) < `operator` (terminal, QoS, reboot, DNS, adotar/renomear, túnel web) < `admin` (+ esquecer roteador e CRUD de usuários).
- **Sessão:** cookie `fl_session` assinado (HMAC-SHA256), `HttpOnly; SameSite=Lax; Secure`. 12h de inatividade (renovada por `GET /api/auth/me` a cada 10 min pelo frontend) ou 30 dias com "Manter conectado". Revogação imediata via `tv` (troca de senha, mudança de perfil/status, exclusão) + `revalidateAuthSockets()` fecha WebSockets afetados.
- **Primeiro acesso:** sem usuários, `/dashboard` mostra "Configuração inicial"; exige o **código de setup** impresso nos logs (`gcloud run services logs read floresta-controller --project=<GCP_PROJECT_ID> --region=southamerica-east1 | findstr SETUP`).
- **Proteções:** `/ws/admin` (qualquer perfil), `/ws/terminal` (operator+), `/api/router/*`, `/api/upload`, proxy da WebUI do roteador, `/select-router`, `/tunnel/*` e arquivos de `/dashboard/*` exigem sessão. WS e POST/PUT/DELETE validam `Origin == Host` (anti CSRF/CSWSH). Login com rate limit (5 falhas/5 min por usuário+IP).
- **Exceções intencionais:** `/ws/router` (agente do roteador, sem login) e `/api/download?token=` (capability token usado pelos roteadores via curl).
- **GOTCHAS:** (1) `/ws/router` continua aberto — qualquer cliente que saiba o protocolo pode se passar por roteador; autenticação de dispositivo é trabalho futuro. (2) Sockets autenticados (`clientMeta[id]['user']`) nunca podem ser reclassificados como `router` pelo bloco "CORREÇÃO". (3) O cookie `fl_session` é removido do header `Cookie` encaminhado ao roteador no proxy. (4) `serveStaticFile` valida `realpath` dentro de `public/` (anti path traversal). (5) Scripts em `scratch/` que falam com o controller precisam de `FLORESTA_USER`/`FLORESTA_PASS` e `scratch/floresta_auth.py` (`get_cookie()` / `ws_cookie_line()`).
- **Teste local:** `scratch/test_auth_local.py` (rodar `server.php` com `PORT=8099` e `DATA_DIR=scratch/authtest_data`).