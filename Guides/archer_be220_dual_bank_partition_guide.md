# Guia de Arquitetura Dual-Bank (A/B) e Gerenciamento de Partições MTD/UBI
## TP-Link Archer BE220 & BE230 (Broadcom BCM6764 / BCA SDK)

Este documento detalha o funcionamento da arquitetura de partição redundante **Dual-Bank (Slots A e B)** dos roteadores Wi-Fi 7 baseados na plataforma Broadcom BCM6764, explicando o comportamento do **Recovery Bundle**, os metadados de boot e como espelhar, atualizar ou alternar entre os slots `rootfs1` e `rootfs2`.

---

## 📑 Sumário

1. [Visão Geral da Arquitetura Dual-Bank](#1-visão-geral-da-arquitetura-dual-bank)
2. [Mapeamento Completo de Partições (NAND & UBI)](#2-mapeamento-completo-de-partições-nand--ubi)
3. [Comportamento do Recovery Bundle (Rescue Mode WPS)](#3-comportamento-do-recovery-bundle-rescue-mode-wps)
4. [Como Gravar / Espelhar o Firmware no Slot 2 (rootfs2)](#4-como-gravar--espelhar-o-firmware-no-slot-2-rootfs2)
   - [Método A: Pelo Linux Ativo via SSH (Comandos UBI)](#método-a-pelo-linux-ativo-via-ssh-comandos-ubi)
   - [Método B: Pelo U-Boot Interativo via TFTP (Serial UART)](#método-b-pelo-u-boot-interativo-via-tftp-serial-uart)
5. [Como Alternar o Slot Ativo de Boot no U-Boot](#5-como-alternar-o-slot-ativo-de-boot-no-u-boot)
6. [Estratégia de Layout: Dual-Bank (33 MB) vs Expandido (66 MB)](#6-estratégia-de-layout-dual-bank-33-mb-vs-expandido-66-mb)

---

## 1. Visão Geral da Arquitetura Dual-Bank

A plataforma Broadcom Broadband Carrier Access (**BCA**) adota um sistema de partição duplo redundante (estilo Android A/B) para garantir tolerância a falhas durante atualizações de firmware.

Existem dois bancos lógicos na memória flash NAND (128 MB):
* **Slot 1 (Bank A - Primário / Padrão):** Contém `bootfs1` (Kernel Linux FIT) e `rootfs1` (SquashFS do sistema).
* **Slot 2 (Bank B - Secundário / Backup):** Contém `bootfs2` (Kernel Linux FIT) e `rootfs2` (SquashFS do sistema).

O U-Boot mantém duas pequenas partições dedicadas a metadados (`metadata1` e `metadata2`) que armazenam:
- `committed-img`: Indica qual dos slots é considerado estável e aprovado para inicialização (1 ou 2).
- `valid-imgs`: Flags indicando se o Slot 1 e/ou Slot 2 possuem imagens válidas com hashes íntegros.
- `seq# img 1 / img 2`: Número de sequência incremental para saber qual é o slot mais recente.

---

## 2. Mapeamento Completo de Partições (NAND & UBI)

Na inicialização, o kernel do Archer BE220 monta a tabela MTD via `/proc/mtd`:

```text
dev:    size   erasesize  name
mtd0: 08000000 00020000 "spi1.0"      -> Flash NAND SPI inteira (128 MB)
mtd1: 00200000 00020000 "loader"      -> Bootloader U-Boot + TPL (2 MB)
mtd2: 07280000 00020000 "image"       -> Contêiner UBI principal (~114.5 MB)
mtd3: 00380000 00020000 "tpconfig"   -> NVRAM de fábrica tp_data (PIN, MAC, Calibração)
mtd4: 00700000 00020000 "userconfig"   -> Configurações persistentes do usuário
mtd5: 00000110 0001f000 "metadata1"   -> Metadados de boot do Slot 1
mtd6: 00000110 0001f000 "metadata2"   -> Metadados de boot do Slot 2
mtd7: 006e4780 0001f000 "bootfs1"     -> Kernel + DTBs do Slot 1 (~6.9 MB)
mtd8: 01aa4000 0001f000 "rootfs1"     -> RootFS SquashFS do Slot 1 (~26.6 MB / limite 33.1 MB)
mtd9: 006e4780 0001f000 "bootfs2"     -> Kernel + DTBs do Slot 2 (~6.9 MB)
mtd10: 01ac3000 0001f000 "rootfs2"    -> RootFS SquashFS do Slot 2 (~26.8 MB / limite 33.1 MB)
mtd11: 0020f000 0001f000 "data"       -> Partição de dados /data (UBIFS montado)
mtd12: 00117000 0001f000 "defaults"   -> Padrões de fábrica
mtd13: 0026c000 0001f000 "tp_data"    -> Dados adicionais de calibração
mtd14: 002e8000 0001f000 "user_data1" -> Dados do usuário no Slot 1
mtd15: 002e8000 0001f000 "user_data2" -> Dados do usuário no Slot 2
```

---

## 3. Comportamento do Recovery Bundle (Rescue Mode WPS)

Quando você liga o roteador segurando o botão WPS por 20 segundos e faz o upload do arquivo `recovery_bundle.bin` pelo navegador em `http://192.168.0.1`:

> [!IMPORTANT]
> **O Recovery Bundle grava APENAS o Slot 1 (`bootfs1` e `rootfs1`). Ele NÃO regrava o `rootfs2`.**

### Por que isso acontece?
1. **Comportamento Nativo de Recuperação:** O mini servidor web HTTP do U-Boot invoca o manipulador de flash da Broadcom (`flash_upgrade_img_bundle`), que foi projetado para restaurar o sistema no Slot 1 prioritário.
2. **Preservação de Segurança:** O Slot 2 (`rootfs2` / `bootfs2`) é deixado intocado propositalmente para servir como fallback de emergência caso o arquivo enviado esteja corrompido ou seja incompatível.
3. **Commit Automático:** Ao terminar a gravação, o bootloader comita o Slot 1:
   ```text
   Flashing rootfs (0x... bytes) to rootfs1.....
   ubi check rootfs1
   ubi remove rootfs1
   ubi create rootfs1 0x19f5000 dynamic
   ubi write 0x... rootfs1 0x19f5000
   INFO: Committing antirollback level
   INFO: Setting committed-img: 1
   ```
4. Em seguida, o roteador reinicia automaticamente no Slot 1 recém-gravado.

---

## 4. Como Gravar / Espelhar o Firmware no Slot 2 (rootfs2)

Se você deseja que o **Slot 2 (`rootfs2`)** contenha exatamente a mesma versão do firmware modificado (para ter redundância total ou caso o bootloader tente alternar de slot), existem dois métodos:

---

### Método A: Pelo Linux Ativo via SSH (Comandos UBI)

Com o roteador já inicializado no Slot 1 e com SSH ativo:

#### 1. Envie a imagem SquashFS para o diretório temporário do roteador:
No PowerShell ou terminal do seu computador:
```bash
scp -O rootfs1_mod.bin root@192.168.0.1:/tmp/
```

#### 2. Conecte-se via SSH:
```bash
ssh root@192.168.0.1
```

#### 3. Identifique o nó de dispositivo do volume `rootfs2`:
No Linux, o contêiner UBI `image` expõe cada partição como um volume `/dev/ubi0_X`. Execute:
```bash
# Lista todos os volumes UBI com seus respectivos nomes:
for v in /sys/class/ubi/ubi0_*; do
    [ -f "$v/name" ] && echo "$v -> $(cat "$v/name")"
done
```

Exemplo de saída típica:
```text
/sys/class/ubi/ubi0_0 -> bootfs1
/sys/class/ubi/ubi0_1 -> rootfs1
/sys/class/ubi/ubi0_2 -> bootfs2
/sys/class/ubi/ubi0_3 -> rootfs2
/sys/class/ubi/ubi0_4 -> data
```
*(No exemplo acima, `rootfs2` corresponde ao dispositivo `/dev/ubi0_3`).*

Você também pode confirmar com o utilitário nativo `ubinfo`:
```bash
ubinfo /dev/ubi0 -a | grep -E "Volume ID|Name"
```

#### 4. Grave a imagem modificada diretamente no volume do `rootfs2`:
Substitua `/dev/ubi0_X` pelo nó correspondente ao `rootfs2` identificado no passo anterior:
```bash
ubiupdatevol /dev/ubi0_3 /tmp/rootfs1_mod.bin
```

#### 5. Confirme a gravação:
```bash
ubinfo /dev/ubi0_3
```
O campo `Data bytes` agora refletirá exatamente o tamanho em bytes do arquivo `rootfs1_mod.bin` gravado.

#### 6. Remova o arquivo temporário da RAM:
```bash
rm -f /tmp/rootfs1_mod.bin
sync
```

---

### Método B: Pelo U-Boot Interativo via TFTP (Serial UART)

Se você estiver conectado com o cabo adaptador USB-UART na porta serial interna (`ttyAMA0`):

1. Configure seu servidor TFTP no PC (IP `192.168.12.2`) e coloque o `rootfs1_mod.bin` na pasta raiz do TFTP.
2. Interrompa a contagem do U-Boot pressionando `Ctrl + C` ou qualquer tecla.
3. Configure a rede do U-Boot:
   ```bash
   setenv ipaddr 192.168.12.1
   setenv serverip 192.168.12.2
   setenv netmask 255.255.255.0
   ping 192.168.12.2
   ```
4. Anexe o contêiner UBI:
   ```bash
   ubi part image
   ```
5. Baixe a imagem para a memória RAM (endereço `0x05000000`):
   ```bash
   tftpboot 0x05000000 rootfs1_mod.bin
   ```
6. Grave no **Slot 1** E no **Slot 2**:
   *(Substitua `0x19f5000` pelo tamanho hexadecimal gerado pelo `build_rootfs.sh`)*:
   ```bash
   ubi write 0x05000000 rootfs1 0x19f5000
   ubi write 0x05000000 rootfs2 0x19f5000
   ```
7. Salve o comando de inicialização padrão e reinicie:
   ```bash
   setenv bootcmd "test_mode enable; sdk boot_img"
   saveenv
   reset
   ```

---

## 5. Como Alternar o Slot Ativo de Boot no U-Boot

Caso você queira forçar a inicialização por um slot específico pelo console U-Boot:

### Forçar Boot pelo Slot 1:
```bash
setenv boot_image 1
setenv committed_image 1
saveenv
reset
```

### Forçar Boot pelo Slot 2:
```bash
setenv boot_image 2
setenv committed_image 2
saveenv
reset
```

> [!TIP]
> Se o roteador tentar bootar pelo Slot 2 e encontrar um erro de integridade de kernel ou squashfs, o watchdog do U-Boot reiniciará automaticamente e alternará de volta para o Slot 1 com base nos metadados de contingência.

---

## 6. Estratégia de Layout: Dual-Bank (33 MB) vs Expandido (66 MB)

O script [`build_rootfs.sh`](file:///f:/OpenWRT/BE230V2.6+BE3500V1.6+BE3600%20ProV1.6_GPL_20250918/GPL/build_rootfs.sh) oferece duas estratégias de partição:

| Recurso | Modo Dual-Bank Padrão (Opção 1) | Modo Expandido ~66MB (Opção 2) |
| :--- | :--- | :--- |
| **Limite do RootFS** | **33.1 MB** (`33.140.736 bytes`) | **~66.2 MB** (`66.281.472 bytes`) |
| **Slot B (rootfs2)** | **Preservado** (Ativo para contingência) | **Removido** (`ubi remove rootfs2`) |
| **Compatível com Rescue Mode (WPS)** | **Sim 100%** (via `recovery_bundle.bin`) | **Não** (Exige flash manual via UART/TFTP) |
| **Finalidade recomendada** | Produção, estabilidade e resiliência a falhas | Desenvolvimento avançado com pacotes pesados (ex: Python, Node.js, Docker) |

### Resumo de Boas Práticas:
* Para a maioria dos cenários (Portal Captivo 3000, Floresta Cloud Agent, Htop, Túnel WebSocket e QoS), a nossa imagem compilada ocupa **apenas 25.96 MB**, ficando **7.1 MB abaixo do limite do Slot Dual-Bank**.
* Portanto, **o modo Dual-Bank (Opção 1) é o ideal e recomendado**, mantendo total segurança e compatibilidade tanto com o Recovery Bundle quanto com gravações manuais.
