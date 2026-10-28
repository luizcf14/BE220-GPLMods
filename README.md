# TP-Link Archer BE220 / BE230 / BE3600 (Wi-Fi 7) — Unlock, Root & Recovery Toolkit

[![Platform](https://img.shields.io/badge/SoC-Broadcom%20BCM6764-blue.svg)](#)
[![Wi-Fi](https://img.shields.io/badge/Wi--Fi-Wi--Fi%207%20(802.11be)-success.svg)](#)
[![License](https://img.shields.io/badge/License-GPL%20v2-orange.svg)](#)
[![Status](https://img.shields.io/badge/Status-Root%20Achieved%20%2F%20Rescue%20Supported-brightgreen.svg)](#)

Este repositório contém ferramentas, scripts automatizados e documentação técnica de engenharia reversa para desbloqueio de console serial (UART), ativação permanente de SSH (Dropbear) com permissões completas de terminal (PTY), e empacotamento de imagens de recuperação (FIT Image Bundle) para a linha de roteadores **TP-Link Archer Wi-Fi 7** baseados no chip **Broadcom BCM6764** (Archer BE220, Archer BE230, BE3500 e BE3600 Pro).

---

## 📑 Sumário

- [Principais Descobertas Técnicas](#-principais-descobertas-técnicas)
- [Estrutura do Repositório](#-estrutura-do-repositório)
- [Mapeamento da Memória Flash (SPI-NAND 128MB)](#-mapeamento-da-memória-flash-spi-nand-128mb)
- [Floresta Cloud Controller](#-floresta-cloud-controller)
- [Guias Rápidos](#-guias-rápidos)
  - [1. Recuperação via Rescue Mode (WPS Web UI - Sem abrir o roteador)](#1-recuperação-via-rescue-mode-wps-web-ui)
  - [2. Criação do RootFS Modificado com SSH Permanente](#2-criação-do-rootfs-modificado-com-ssh-permanente)
  - [3. Desbloqueio da Console Serial (UART)](#3-desbloqueio-da-console-serial-uart)
  - [4. Gravação de Partições via U-Boot (TFTP)](#4-gravação-de-partições-via-u-boot-tftp)
- [Guias Detalhados](#-guias-detalhados)
- [Aviso Legal](#-aviso-legal)

---

## 🔬 Principais Descobertas Técnicas

Durante o processo de engenharia reversa no U-Boot e no kernel da Broadcom/TP-Link, superamos diversas proteções proprietárias implementadas pelo fabricante:

1. **Desbloqueio da UART Serial (`test_mode enable`):**
   A TP-Link bloqueia a recepção serial (RX) do console no kernel através dos módulos `user-debug` e `kmonitor`. O comando nativo `test_mode enable` no U-Boot desativa esse bloqueio e permite entrada de teclado no console `ttyAMA0`.

2. **A Flag Secreta do Dropbear (`-L`):**
   A TP-Link modificou o código-fonte C do servidor SSH Dropbear criando a armadilha `svr_opts.sessionEnable == 0`. Mesmo autenticando senha ou chave pública, o terminal PTY e o shell eram rejeitados silenciosamente. Descobrimos que a flag de inicialização proprietária `-L` (`/usr/sbin/dropbear -p 22 -L -B &`) desarma a trava e abre o shell normalmente.

3. **Armadilha do Pseudoterminal (`/dev/ptmx` & `devpts`):**
   O kernel Broadcom monta o sistema `/dev/pts` com `ptmxmode=000` e mantém `/dev/ptmx` como nó estático morto. Corrigimos remontando com `mode=666,ptmxmode=666` e substituindo `/dev/ptmx` por um link simbólico para `pts/ptmx`.

4. **Boot Hook Real (`S99zzzzboot_done`):**
   Como a TP-Link removeu o `/etc/init.d/done`, o tradicional `/etc/rc.local` nunca é chamado no boot. O ponto de entrada definitivo para inicialização customizada é o `/etc/rc.d/S99zzzzboot_done`.

5. **Estrutura de Pacote Broadcom BCA (FIT Image):**
   O modo de recuperação por WPS (Rescue Mode) do bootloader valida o formato Broadcom BCA FIT (`generate_bundle_itb`), exigindo partições `loader`, `bootfs`, `rootfs` e a string de compatibilidade estrita `compatible = "flash=nand;chip=6764;fstype=squashfs"`.

---

## 📂 Estrutura do Repositório

```text
├── Guides/                               # Documentações técnicas aprofundadas
│   ├── archer_be220_dual_bank_partition_guide.md # Guia de Arquitetura Dual-Bank (A/B) e Partições UBI
│   ├── archer_be220_rescue_mode_guide.md # Guia completo do Rescue Mode (WPS Web UI)
│   ├── archer_be220_ssh_upgrade_guide.md # Upgrade de firmware via SSH
│   ├── archer_be220_uart_unlock_guide.md # Guia completo de hardware, UART e RootFS
│   ├── deployment_and_management.md      # Deploy e gerenciamento
│   ├── firmware_build_system.md          # Sistema de build do firmware
│   └── openwrt_infrastructure.md         # Infraestrutura OpenWrt
├── cloudController/                      # Floresta Cloud Controller (PHP assíncrono, Cloud Run)
│   ├── server.php                        # Servidor HTTP/WebSocket, auth, RBAC, túnel reverso
│   └── public/                           # Dashboard (index.html, login.html, app.js, style.css) e agente Lua
├── captivePortal/                        # Portal cativo, QoS e agente do roteador (be220_port)
├── web_deploy/                           # Artefatos distribuídos aos roteadores (floresta_agent)
├── scratch/                              # Scripts temporários e de teste (não poluir a raiz)
├── Copias MTD/                           # Dumps das partições originais da NAND
│   ├── mtd1_loader.bin                   # U-Boot Bootloader
│   ├── mtd7_bootfs1.bin                  # Kernel Linux FIT Image
│   ├── mtd8_rootfs1.bin                  # Root Filesystem (SquashFS)
│   └── ...
├── generate_recovery_bundle.sh           # Script de empacotamento do FIT bundle para Rescue Mode
├── build_rootfs.sh                       # Script que descompacta, aplica patches SSH e remonta o rootfs
├── deploy_cloud_run.ps1 / .sh            # Deploy do controller no Google Cloud Run
├── firmware.its                          # Template Device Tree Source para o mkimage
├── serve_tftp.py                         # Servidor TFTP Python nativo para envio via U-Boot
├── AGENTS.md                             # Memória de projeto e regras do agente
└── README.md                             # Este documento
```

---

## 🗺️ Mapeamento da Memória Flash (SPI-NAND 128MB)

| Dispositivo | Tamanho Hex | Tamanho Real | Partição | Descrição |
|:---|:---|:---|:---|:---|
| `/dev/mtd0` | `0x08000000` | **128 MiB** | `spi1.0` | Imagem completa de fábrica bit a bit |
| `/dev/mtd1` | `0x00200000` | 2 MiB | `loader` | Bootloader U-Boot e TPL |
| `/dev/mtd2` | `0x07280000` | 114.5 MiB | `image` | Contêiner UBI (`bootfs1/2`, `rootfs1/2`, `data`) |
| `/dev/mtd3` | `0x00380000` | 3.5 MiB | `tpconfig` | Volume UBI `tp_data` (PIN WPS, MAC, Calibração) |
| `/dev/mtd4` | `0x00700000` | 7 MiB | `userconfig` | Configurações persistentes do usuário |
| `/dev/mtd7` | `0x006e4780` | ~6.9 MiB | `bootfs1` | Kernel Linux FIT (Kernel + DTBs) |
| `/dev/mtd8` | `0x01f9b000` | ~31.6 MiB | `rootfs1` | Sistema de arquivos SquashFS (Root) |

---

## 🚀 Guias Rápidos

### 1. Recuperação via Rescue Mode (WPS Web UI)

Não requer abrir o roteador. Usado para restaurar o firmware ou testar pacotes FIT.

1. Configure a placa de rede do seu PC com IP estático:
   - **IP:** `192.168.0.2` | **Máscara:** `255.255.255.0` | **Gateway:** `192.168.0.1`
2. Conecte o cabo de rede à porta LAN 1 do roteador.
3. Desligue o roteador.
4. **Mantenha o botão WPS pressionado**, ligue o roteador e **continue segurando o botão WPS por 20 segundos**.
5. Abra o navegador em: **`http://192.168.0.1`**.
6. Gere o pacote FIT com o script:
   ```bash
   wsl -d Ubuntu-24.04 bash generate_recovery_bundle.sh
   ```
7. Na página do Rescue Mode, selecione `recovery_bundle.bin` e clique em **Upgrade**.

---

### 2. Criação do RootFS Modificado com SSH Permanente

O script `build_rootfs.sh` faz o processo de forma 100% segura dentro do WSL2 (em partição ext4 para preservar symlinks):

```bash
wsl -d Ubuntu-24.04 bash build_rootfs.sh
```

**O que este script faz:**
- Descompacta o SquashFS original.
- Configura `/etc/inittab` para shell direto sem pedir login na serial.
- Grava o hash da senha de root (`<ROOT_PASSWORD>`) em `/etc/shadow` e `/etc/passwd`.
- Injeta a sua chave pública SSH em `/root/.ssh/authorized_keys`.
- Aplica o patch no `/etc/rc.d/S99zzzzboot_done` com a flag `-L`, fix do `devpts` e limpeza do `fail_count`.
- Recompacta gerando `rootfs1_mod.bin`.

---

### 3. Desbloqueio da Console Serial (UART)

- **Parâmetros da Serial:** `115200 8N1`, sem controle de fluxo.
- **Console do Kernel:** `ttyAMA0` (ARM PrimeCell PL011).

Para entrar no sistema original com a serial desbloqueada:
1. Interrompa o autoboot no U-Boot pressionando qualquer tecla.
2. Execute no prompt `=>`:
   ```bash
   test_mode enable
   sdk boot_img
   ```
3. O Linux iniciará com o terminal serial aberto e funcional!

---

### 4. Gravação de Partições via U-Boot (TFTP)

1. No Windows, inicie o servidor TFTP embutido:
   ```powershell
   python serve_tftp.py
   ```
   *(Configure o IP do PC como `192.168.12.2` na porta WAN/2.5G)*.
2. No U-Boot:
   ```bash
   setenv ipaddr 192.168.12.1; setenv serverip 192.168.12.2; setenv netmask 255.255.255.0
   ping 192.168.12.2
   ubi part image
   tftpboot 0x05000000 rootfs1_mod.bin
   ubi write 0x05000000 rootfs1 0x1f90000
   setenv bootcmd "test_mode enable; sdk boot_img"
   saveenv
   reset
   ```

---

## ☁️ Floresta Cloud Controller

Controlador estilo UniFi (projeto GCP `<GCP_PROJECT_ID>`, serviço `floresta-controller`, região `southamerica-east1`) que gerencia os roteadores via WebSocket (`/ws/router`), sem IP público nem VPN.

- **Recursos:** adoção de roteadores, perfis QoS, bloqueio DNS (global e por roteador), reboot, terminal remoto web (xterm.js em `/ws/terminal`) e túnel reverso para a WebUI/LuCI do roteador.
- **Deploy:** `.\deploy_cloud_run.ps1` (instância única, `--no-cpu-throttling`, dados persistidos no bucket GCS `<GCS_BUCKET>` via Cloud Storage FUSE em `/app/data`).
- **Autenticação e RBAC:** login por usuário/senha (bcrypt) com cookie `fl_session` assinado (HMAC-SHA256). Perfis: `viewer` < `operator` < `admin`. No primeiro acesso, o `/dashboard` pede o **código de setup** impresso nos logs:
  ```powershell
  gcloud run services logs read floresta-controller --project=<GCP_PROJECT_ID> --region=southamerica-east1 | findstr SETUP
  ```
- **Apontar um roteador ao controller:**
  ```sh
  set-inform https://<CONTROLLER_HOST>/ws/router
  ```
- **Firmware customizado:** a versão é fixada em `77.0.1 Build 20991231 rel.99999` e `ota-download.tplinkcloud.com` é bloqueado para impedir OTA oficial. O `floresta_agent` restaura configurações de `/data` e `/user_data1` após factory reset.
- **Teste local de autenticação:** `scratch/test_auth_local.py` (rodar `server.php` com `PORT=8099` e `DATA_DIR=scratch/authtest_data`).

Detalhes, armadilhas conhecidas e regras estritas em [`AGENTS.md`](AGENTS.md).

---

## 📚 Guias Detalhados

Para diagramas, pinagens completas, scripts de backup de 128 MB via netcat e instruções passo a passo detalhadas, consulte os documentos na pasta [`Guides/`](Guides/):

- 📖 **[Guia de Arquitetura Dual-Bank e Partições MTD/UBI](Guides/archer_be220_dual_bank_partition_guide.md)**
- 📖 **[Guia de Recuperação e Rescue Mode](Guides/archer_be220_rescue_mode_guide.md)**
- 📖 **[Guia de Desbloqueio UART e Modificação de Firmware](Guides/archer_be220_uart_unlock_guide.md)**
- 📖 **[Guia de Upgrade via SSH](Guides/archer_be220_ssh_upgrade_guide.md)**
- 📖 **[Deploy e Gerenciamento](Guides/deployment_and_management.md)**
- 📖 **[Sistema de Build do Firmware](Guides/firmware_build_system.md)**
- 📖 **[Infraestrutura OpenWrt](Guides/openwrt_infrastructure.md)**

---

## ⚠️ Aviso Legal

Este projeto foi desenvolvido estritamente para fins educacionais, de pesquisa em segurança de sistemas embarcados e preservação de hardware do proprietário. A modificação de firmware pode invalidar a garantia do fabricante. Os autores não se responsabilizam por danos causados a dispositivos decorrentes do uso das instruções contidas neste repositório.
