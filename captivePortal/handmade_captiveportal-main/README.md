# Portal Captivo 3000

Sistema de portal captivo para redes OpenWrt integrado a um backend **Laravel + Sanctum**. Desenvolvido para a rede comunitária **Conexão Povos da Floresta**.

---

## Sumário

- [Visão Geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Fluxo de Autenticação](#fluxo-de-autenticação)
- [Estrutura de Arquivos](#estrutura-de-arquivos)
- [Requisitos](#requisitos)
- [Configuração](#configuração)
- [Deploy](#deploy)
- [Gerenciamento](#gerenciamento)
- [Interface LuCI](#interface-luci)
- [Segurança](#segurança)
- [Resolução de Problemas](#resolução-de-problemas)
- [Recuperação de Emergência (Modo Failsafe)](#recuperação-de-emergência-modo-failsafe)

---

## Visão Geral

O Portal Captivo 3000 intercepta todo o tráfego HTTP de clientes não autenticados na rede LAN e os redireciona para uma tela de login. Após o login, o cliente recebe acesso à internet com **limite de banda** determinado pelo perfil do seu usuário no backend Laravel.

**Funcionalidades principais:**

- Interceptação HTTP via nftables (sem `iptables`, compatível com fw4/OpenWrt 23+)
- Autenticação via token **Laravel Sanctum** — validado diretamente pelo roteador contra a API
- **Controle de banda por perfil** com `tc/HTB` (classes configuráveis via UCI)
- **Walled garden** — domínios liberados antes do login (ex: domínio da API)
- Timeout de sessão automático gerenciado pelo kernel (via `timeout` do nftables)
- Interface de administração integrada ao **LuCI** (OpenWrt WebUI)
- CLI de gerenciamento `portal_ctl` para operação via SSH

---

## Arquitetura

```
┌──────────────────────────────────────────────────────────────────┐
│                        CLIENTE (navegador)                       │
└────────────────────────────┬─────────────────────────────────────┘
                             │ HTTP (qualquer site)
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                    ROTEADOR OpenWrt                              │
│                                                                  │
│  nftables / fw4                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ captive_prerouting  → redireciona HTTP → porta 2080       │  │
│  │ captive_forward     → bloqueia WAN para não autenticados  │  │
│  │ captive_mangle      → aplica fwmark por perfil (QoS)      │  │
│  │ sets:                                                      │  │
│  │   captive_authenticated  → IPs liberados (com timeout)    │  │
│  │   captive_whitelist      → IPs do walled garden (dnsmasq) │  │
│  │   captive_fwmark         → IP → fwmark do perfil          │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  uhttpd (porta 80 + 2080)                                        │
│  ├── /portal/          → tela de login (HTML/CSS/JS estático)   │
│  └── /cgi-bin/                                                   │
│       ├── portal_redirect  → 302 para /portal/                  │
│       └── portal_auth      → valida token + libera nftables     │
│                                                                  │
│  tc/HTB (interface WAN)                                          │
│  └── classes por fwmark → limite de banda por perfil            │
│                                                                  │
│  dnsmasq-full                                                    │
│  └── nftset= → popula captive_whitelist com IPs dos domínios    │
└──────────────────────┬───────────────────────────────────────────┘
                       │ HTTPS (uclient-fetch — do próprio roteador)
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│              BACKEND Laravel + Sanctum                           │
│   POST /api/login   → retorna token Sanctum                     │
│   GET  /api/user    → valida token, retorna user.role.name      │
└──────────────────────────────────────────────────────────────────┘
```

---

## Fluxo de Autenticação

### Do ponto de vista do usuário

```
1. Usuário conecta no Wi-Fi / cabo
2. Abre o navegador e tenta acessar qualquer site HTTP
3. É redirecionado automaticamente para http://192.168.1.1/portal/
4. Preenche e-mail e senha
5. Clica em "Entrar e Conectar"
6. Vê o card de sucesso com seu perfil e um countdown
7. É redirecionado automaticamente para o destino original
8. Navega normalmente com o limite de banda do seu perfil
```

### Internamente (sequência técnica)

```
Navegador                 Frontend (JS)            Roteador CGI           Backend Laravel
    │                          │                        │                       │
    │── GET http://example ───►│                        │                       │
    │                    nftables redireciona           │                       │
    │◄── 302 /portal/ ─────────│                        │                       │
    │── GET /portal/ ─────────►│                        │                       │
    │◄── login page ───────────│                        │                       │
    │                          │                        │                       │
    │── submit form ──────────►│                        │                       │
    │                          │── POST /api/login ────────────────────────────►│
    │                          │◄── { token, user } ───────────────────────────│
    │                          │                        │                       │
    │                          │── POST /cgi-bin/portal_auth (token) ──────────►│
    │                          │                        │── GET /api/user ─────►│
    │                          │                        │◄── { role.name } ─────│
    │                          │                        │                       │
    │                          │                   nft add element              │
    │                          │                   captive_authenticated {IP}   │
    │                          │                   nft add element              │
    │                          │                   captive_fwmark {IP: mark}    │
    │                          │                        │                       │
    │                          │◄── { status: "ok" } ───│                       │
    │◄── card de sucesso ──────│                        │                       │
    │── GET http://example ───────────────────────────► WAN (acesso liberado)  │
```

---

## Estrutura de Arquivos

```
Portal Captivo 3000/
│
├── README.md                           ← Este arquivo
├── deploy.sh                           ← Script de deploy (envia tudo ao roteador via SCP)
│
├── frontend/                           ← Tela de login servida pelo roteador
│   ├── index.html                      ← Página principal com card de login e card de sucesso
│   ├── style.css                       ← Dark glassmorphism, animações, responsivo
│   └── app.js                          ← Lógica: login → autorização → redirecionamento
│
└── openwrt/                            ← Espelho da estrutura do roteador
    ├── etc/
    │   ├── config/
    │   │   └── captiveportal           ← Config UCI: interfaces, API, sessão, perfis
    │   ├── init.d/
    │   │   └── captiveportal           ← Serviço procd (start/stop/reload)
    │   └── nftables.d/
    │       └── 10-captive-portal.nft   ← Template de regras nftables (placeholders)
    │
    ├── www/
    │   └── cgi-bin/
    │       ├── portal_redirect         ← CGI: redireciona clientes não autenticados
    │       └── portal_auth             ← CGI: valida token + insere IP no nftables
    │
    ├── usr/
    │   ├── bin/
    │   │   └── portal_ctl              ← CLI de gerenciamento
    │   └── share/
    │       ├── luci/menu.d/
    │       │   └── luci-app-captiveportal.json   ← Entradas de menu LuCI
    │       └── rpcd/acl.d/
    │           └── luci-app-captiveportal.json   ← Permissões RPCD
    │
    └── htdocs/luci-static/resources/view/captiveportal/
        ├── config.js                   ← LuCI: configuração global e perfis
        ├── whitelist.js                ← LuCI: gerenciamento do walled garden
        └── sessions.js                 ← LuCI: sessões ativas (auto-refresh 10s)
```

---

## Requisitos

### Roteador

| Componente | Requisito |
|---|---|
| **OpenWrt** | 23.05 ou superior |
| **Firewall** | fw4 com nftables (padrão no 23+) |
| **Kernel** | Suporte a `nft timeout` em sets |
| **RAM** | Mínimo 64 MB recomendado |
| **Flash** | Mínimo 16 MB recomendado |

### Pacotes OpenWrt obrigatórios

```sh
opkg update
opkg install \
    uclient-fetch \
    dnsmasq-full \
    kmod-sched-core \
    kmod-sched-htb \
    kmod-sched-fq-codel \
    tc-full
```

> **Atenção:** O pacote `dnsmasq-full` substitui o `dnsmasq` padrão. Se já houver `dnsmasq` instalado, remova-o antes:
> ```sh
> opkg remove dnsmasq && opkg install dnsmasq-full
> ```

### Pacotes LuCI (opcional, para interface web de administração)

```sh
opkg install luci luci-base luci-mod-admin-full
```

### Backend Laravel

| Requisito | Detalhe |
|---|---|
| **Endpoint de login** | `POST /api/login` — aceita `email` + `password`, retorna `{ token, user }` |
| **Endpoint de validação** | `GET /api/user` — aceita `Authorization: Bearer <token>`, retorna objeto user com `user.role.name` |
| **Autenticação** | Laravel Sanctum (token de API) |
| **CORS** | Deve aceitar requisições do domínio do frontend (ou `*` para desenvolvimento) |
| **Campo de perfil** | `user.role.name` — deve corresponder exatamente ao `name` dos perfis configurados no UCI |

### Máquina de desenvolvimento (para deploy)

- SSH configurado com acesso root ao roteador (chave pública ou senha)
- `scp` disponível (Linux/macOS nativos, Windows via WSL ou Git Bash)

---

## Configuração

### Arquivo principal: `/etc/config/captiveportal`

Editável via LuCI (**Serviços → Captive Portal → Configuração**) ou diretamente via UCI.

#### Seção `global`

| Opção | Padrão | Descrição |
|---|---|---|
| `api_url` | `https://apidev.conexaopovosdafloresta.org.br` | URL base do backend Laravel |
| `api_user_path` | `/api/user` | Endpoint GET de validação do token Sanctum |
| `session_time` | `3600` | Duração da sessão em segundos (ex: `86400` = 24h) |
| `wan_interface` | `eth0.2` | Interface WAN para QoS. Verificar com `ip route show default` |
| `lan_interface` | `br-lan` | Interface LAN (bridge) para interceptação |
| `router_ip` | `192.168.1.1` | IP do roteador — sempre liberado no walled garden |
| `portal_port` | `2080` | Porta interna do uhttpd para o portal |

> **Sobre as interfaces:** Os valores de `wan_interface` e `lan_interface` são aplicados **dinamicamente** nas regras nftables ao iniciar o serviço. O arquivo `10-captive-portal.nft` é um template com placeholders — não edite as interfaces diretamente nele.

#### Seção `walled_garden`

Domínios acessíveis **antes do login**. O dnsmasq-full resolve os IPs e os insere automaticamente no set `captive_whitelist` do nftables.

```uci
config captiveportal 'walled_garden'
    list domain 'apidev.conexaopovosdafloresta.org.br'
    list domain 'conexaopovosdafloresta.org.br'
```

Suporte a wildcard: `*.exemplo.com` libera todos os subdomínios.

Adicionar/remover via CLI:
```sh
portal_ctl whitelist add meudominio.com
portal_ctl whitelist del meudominio.com
```

#### Seção `profile` (perfis de velocidade)

Cada perfil mapeia um valor de `user.role.name` a limites de banda.

```uci
config profile 'visitante'
    option name     'Visitante'   # deve ser IDÊNTICO ao user.role.name do Laravel
    option fwmark   '1'           # identificador interno único (1–255), não altere após criação
    option dl_kbit  '2048'        # limite de download em Kbps (0 = ilimitado)
    option ul_kbit  '1024'        # limite de upload em Kbps (0 = ilimitado)
```

> **Importante:** O `fwmark` é o identificador interno da classe `tc/HTB`. Após usuários estarem conectados com um perfil, **não altere o fwmark** desse perfil (pode confundir o mapeamento de banda).

**Perfis pré-configurados:**

| Perfil | Papel (role) | Download | Upload |
|---|---|---|---|
| visitante | Visitante | 2 Mbps | 1 Mbps |
| jovem | Jovem | 4 Mbps | 2 Mbps |
| comunitario | Comunitario | 5 Mbps | 2 Mbps |
| medico | Médico | 10 Mbps | 5 Mbps |
| administrador | Administrador | 25 Mbps | 10 Mbps |
| ilimitado | Ilimitado | sem limite | sem limite |

---

## Deploy

### Método 1 — Script automático `deploy.sh` (recomendado)

O script envia todos os arquivos via SCP, ajusta permissões, habilita o serviço e recarrega o firewall.

**No Linux/macOS ou Git Bash (Windows):**

```bash
cd "Portal Captivo 3000"
bash deploy.sh 192.168.1.1
```

O script:
1. Verifica conectividade SSH com o roteador
2. Cria todos os diretórios necessários
3. Envia os arquivos de configuração, CGI, CLI, frontend e LuCI
4. Ajusta permissões de execução
5. Configura o uhttpd para escutar na porta 2080
6. Habilita e inicia o serviço `captiveportal`
7. Recarrega o firewall (fw4)
8. Exibe verificação pós-deploy

**Pré-requisito:** Chave SSH configurada para o roteador. Para configurar:
```sh
ssh-copy-id root@192.168.1.1
# ou para adicionar a chave manualmente:
cat ~/.ssh/id_rsa.pub | ssh root@192.168.1.1 'cat >> /etc/dropbear/authorized_keys'
```

---

### Método 2 — Deploy manual passo a passo

#### 1. Instalar dependências no roteador

```sh
ssh root@192.168.1.1
opkg update
opkg remove dnsmasq
opkg install uclient-fetch dnsmasq-full kmod-sched-core kmod-sched-htb kmod-sched-fq-codel tc-full
```

#### 2. Enviar os arquivos

```sh
# A partir do diretório raiz do projeto:

# Configuração e serviço
scp openwrt/etc/config/captiveportal          root@192.168.1.1:/etc/config/captiveportal
scp openwrt/etc/init.d/captiveportal          root@192.168.1.1:/etc/init.d/captiveportal
scp openwrt/etc/nftables.d/10-captive-portal.nft root@192.168.1.1:/etc/nftables.d/10-captive-portal.nft

# CGI scripts
scp openwrt/www/cgi-bin/portal_redirect       root@192.168.1.1:/www/cgi-bin/portal_redirect
scp openwrt/www/cgi-bin/portal_auth           root@192.168.1.1:/www/cgi-bin/portal_auth

# CLI de gerenciamento
scp openwrt/usr/bin/portal_ctl                root@192.168.1.1:/usr/bin/portal_ctl

# Frontend (tela de login)
ssh root@192.168.1.1 'mkdir -p /www/portal'
scp frontend/index.html                        root@192.168.1.1:/www/portal/index.html
scp frontend/style.css                         root@192.168.1.1:/www/portal/style.css
scp frontend/app.js                            root@192.168.1.1:/www/portal/app.js
```

#### 3. Ajustar permissões

```sh
ssh root@192.168.1.1 '
    chmod 755 /etc/init.d/captiveportal
    chmod 755 /www/cgi-bin/portal_redirect
    chmod 755 /www/cgi-bin/portal_auth
    chmod 755 /usr/bin/portal_ctl
    chmod 600 /etc/config/captiveportal
    chmod 644 /etc/nftables.d/10-captive-portal.nft
    chmod 644 /www/portal/index.html /www/portal/style.css /www/portal/app.js
'
```

#### 4. Configurar uhttpd (porta 2080)

```sh
ssh root@192.168.1.1 '
    uci add_list uhttpd.main.listen_http="0.0.0.0:2080"
    uci commit uhttpd
    /etc/init.d/uhttpd restart
'
```

#### 5. Habilitar e iniciar o serviço

```sh
ssh root@192.168.1.1 '
    /etc/init.d/captiveportal enable
    /etc/init.d/captiveportal start
    /etc/init.d/firewall reload
'
```

#### 6. Verificar

```sh
ssh root@192.168.1.1 'portal_ctl status'
```

---

### Verificação pós-deploy

```sh
# Verifica sets nftables ativos
ssh root@192.168.1.1 'nft list sets inet'

# Verifica regras geradas (arquivo dinâmico em /tmp)
ssh root@192.168.1.1 'cat /tmp/captive-portal-active.nft'

# Verifica classes tc/HTB
ssh root@192.168.1.1 'tc class show dev eth0.2'

# Verifica logs do serviço
ssh root@192.168.1.1 'logread | grep captiveportal'
```

---

## Gerenciamento

### `portal_ctl` — CLI de administração

Disponível via SSH no roteador.

```sh
# Exibe estado geral: sessões, sets nftables, status do serviço
portal_ctl status

# Lista sessões ativas com IP, MAC, usuário, perfil e tempo restante
portal_ctl sessions

# Lista sessões em JSON (para scripts/automação)
portal_ctl sessions-json

# Desconecta um cliente pelo IP
portal_ctl kick 192.168.1.50

# Desconecta um cliente pelo MAC
portal_ctl kick-mac aa:bb:cc:dd:ee:ff

# Desconecta TODOS os clientes
portal_ctl flush

# Gerencia o walled garden
portal_ctl whitelist                    # lista domínios
portal_ctl whitelist add meusite.com   # adiciona domínio
portal_ctl whitelist del meusite.com   # remove domínio

# Lista perfis de velocidade configurados
portal_ctl profiles
```

### Gerenciamento do serviço

```sh
service captiveportal start    # inicia (aplica regras + configura tc)
service captiveportal stop     # para (remove todas as regras, desbloqueia tráfego)
service captiveportal restart  # reinicia completamente
service captiveportal reload   # recarrega config sem derrubar sessões ativas
```

### Alterar configurações via UCI

```sh
# Alterar tempo de sessão para 8 horas
uci set captiveportal.global.session_time=28800
uci commit captiveportal
service captiveportal restart

# Alterar interfaces (ex: roteador com WAN em pppoe-wan)
uci set captiveportal.global.wan_interface=pppoe-wan
uci set captiveportal.global.lan_interface=br-lan
uci commit captiveportal
service captiveportal restart

# Adicionar domínio ao walled garden
uci add_list captiveportal.walled_garden.domain=meudominio.com
uci commit captiveportal
service captiveportal reload
```

---

## Interface LuCI

Acesse em: **`http://192.168.1.1/cgi-bin/luci/admin/services/captiveportal`**

### Abas disponíveis

#### Configuração
- URL do backend Laravel e endpoint de validação
- Duração da sessão
- **Interface WAN** e **Interface LAN** (usadas nas regras nftables)
- IP do roteador (walled garden implícito)
- Perfis de velocidade: adicionar, remover e editar

#### Walled Garden
- Lista de domínios liberados antes do login
- Adicionar/remover domínios com aplicação imediata

#### Sessões Ativas
- Tabela com todos os clientes autenticados: MAC, IP, usuário, e-mail, perfil, tempo restante
- Atualização automática a cada 10 segundos
- Botão "Desconectar" por cliente individual
- Botão "Desconectar Todos"

---

## Segurança

### Prevenção de spoofing

- O **IP do cliente** é sempre obtido de `REMOTE_ADDR` (nível TCP — impossível de falsificar)
- O **MAC do cliente** é obtido da tabela ARP do kernel (`/proc/net/arp`) — não confia em parâmetros enviados pelo cliente
- O **token** é validado **diretamente** pelo roteador contra o backend (não existe segredo compartilhado)

### Sem estado no cliente

- O cliente não recebe nenhuma informação privilegiada (fwmark, MAC esperado etc.)
- A liberação acontece inteiramente no lado do roteador

### Timeout automático

- O kernel do Linux gerencia o timeout das sessões nativamente via nftables `timeout`
- Não há daemon de controle de sessão — o próprio kernel remove o IP do set ao expirar

### HTTPS obrigatório para API

- Toda comunicação entre o roteador e o backend ocorre via HTTPS (`uclient-fetch`)
- O frontend faz login também via HTTPS na API antes de chamar o roteador localmente

---

## Resolução de Problemas

### Cliente não é redirecionado

```sh
# Verifica se as chains captive existem
ssh root@IP 'nft list chains inet | grep captive'

# Verifica o arquivo gerado
ssh root@IP 'cat /tmp/captive-portal-active.nft'

# Verifica se o serviço está ativo
ssh root@IP 'service captiveportal status'

# Reinicia e observa logs
ssh root@IP 'service captiveportal restart; logread | grep captive'
```

### Erro "Token inválido" no portal

```sh
# Testa o endpoint manualmente a partir do roteador
ssh root@IP 'uclient-fetch -O- --header "Authorization: Bearer SEU_TOKEN" \
  https://apidev.conexaopovosdafloresta.org.br/api/user'
```

### Controle de banda não funciona

```sh
# Verifica classes HTB
ssh root@IP 'tc class show dev eth0.2'
ssh root@IP 'tc filter show dev eth0.2'

# Verifica fwmark no nftables
ssh root@IP 'nft list map inet fw4 captive_fwmark'
```

### Interface WAN incorreta

```sh
# Descobre a interface WAN real
ssh root@IP 'ip route show default'
# Exemplo de saída: default via 192.168.0.1 dev eth0.2

# Atualiza a configuração
uci set captiveportal.global.wan_interface=NOME_DA_INTERFACE
uci commit captiveportal
service captiveportal restart
```

### Walled garden não está funcionando

```sh
# Verifica se o dnsmasq-full está instalado (e não o dnsmasq comum)
ssh root@IP 'dnsmasq --version | head -1'
# Deve conter: Dnsmasq version ... with-nftset

# Verifica o arquivo gerado
ssh root@IP 'cat /etc/dnsmasq.d/captive-whitelist.conf'

# Verifica IPs resolvidos no set
ssh root@IP 'nft list set inet fw4 captive_whitelist'
```

### Logs em tempo real

```sh
ssh root@192.168.1.1 'logread -f | grep -E "captive|portal"'
```

---

## Recuperação de Emergência (Modo Failsafe)

Se o roteador parar de responder via SSH/Web, ou se pacotes vitais do sistema (como `busybox`) forem removidos por engano, o OpenWrt possui um **Modo Failsafe** embutido na memória de fábrica (SquashFS somente-leitura). **O roteador não está perdido.**

### Passo 1: Entrar no Modo Failsafe
1. Desligue o roteador da tomada.
2. Religue o roteador.
3. Assim que a luz LED (`Power`, `SYS` ou `WLAN`) começar a piscar, **pressione repetidamente (ou segure) o botão Reset / WPS** até que o LED comece a **piscar muito rápido** (várias vezes por segundo).
4. O roteador entrou no **Modo Failsafe**.

### Passo 2: Configurar IP estático na placa de rede do PC
Conecte um cabo de rede de uma porta **LAN** do roteador ao seu computador e configure o IP da sua máquina:
* **Endereço IP:** `192.168.1.2`
* **Máscara de Sub-rede:** `255.255.255.0`
* **Gateway Padrão:** `192.168.1.1`

### Passo 3: Resetar via Telnet / SSH
Abra o Terminal / Prompt do Windows e conecte via Telnet ou SSH:

```sh
telnet 192.168.1.1
# ou
ssh root@192.168.1.1
```

Após conectar, execute:

```sh
firstboot -y && reboot
```

Aguarde 2 minutos. O roteador reiniciará limpo, restaurado ao estado original de fábrica do OpenWrt! Lembre-se de retornar a placa de rede do PC para IP Automático (DHCP).

---

## Desenvolvimento e Testes

Para testar o frontend localmente sem um roteador, edite temporariamente o `CONFIG.ROUTER_HOST` em `frontend/app.js` para apontar para um servidor de mock, ou use um proxy reverso local.

O arquivo `10-captive-portal.nft` em `openwrt/etc/nftables.d/` é um **template** — os placeholders `__LAN_IF__`, `__WAN_IF__` e `__ROUTER_IP__` são substituídos pelo `init.d/captiveportal` em runtime. O arquivo final gerado fica em `/tmp/captive-portal-active.nft` no roteador.

---

## Licença

Projeto desenvolvido para a rede comunitária **Conexão Povos da Floresta**. Uso livre para fins comunitários e educacionais.
