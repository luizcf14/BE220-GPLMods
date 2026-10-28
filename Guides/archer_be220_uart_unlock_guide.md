# Documentação Técnica: Desbloqueio de Acesso UART / Serial no TP-Link Archer BE220 / BE3600

> **Dispositivo:** TP-Link Archer BE220 (Wi-Fi 7) / BE3600 Dual-Band  
> **Plataforma SoC:** Broadcom BCM6764 (ARMv7 quad-core)  
> **Sistema Operacional:** Linux 4.19 (Iplatform / OpenWrt fork)  
> **Bootloader:** U-Boot 2019.07 (Broadcom BCA BTRM -> SPL -> TPL -> U-Boot)  

---

## 1. Visão Geral do Desafio

Os roteadores modernos da TP-Link possuem proteção de segurança em nível de firmware que bloqueia a entrada de dados (RX) da porta serial após a inicialização do kernel Linux, exibindo os logs de inicialização, mas ignorando qualquer toque no teclado.

Através da engenharia reversa no U-Boot e análise do Device Tree embutido no firmware, identificamos a arquitetura do hardware e o comando nativo de fábrica (`test_mode`) que remove essa trava de segurança.

---

## 2. Preparação do Ambiente (Windows + WSL2)

### 2.1 Conexão do Adaptador Serial USB-TTL
- **Baud Rate:** `115200`
- **Data Bits:** `8`, **Parity:** `None`, **Stop Bits:** `1` (8N1)
- **Flow Control:** Hardware = **OFF**, Software = **OFF**
- **Pinagem:**
  - `TX` do Adaptador USB $\rightarrow$ `RX` da placa do roteador
  - `RX` do Adaptador USB $\rightarrow$ `TX` da placa do roteador
  - `GND` do Adaptador USB $\rightarrow$ `GND` da placa do roteador
  - ⚠️ *Não conecte o pino VCC (3.3V/5V).*

### 2.2 Anexar a Porta Serial ao WSL2 via `usbipd`
No PowerShell do Windows (Administrador):
```powershell
# 1. Identificar o ID da distribuição WSL
wsl -l -v

# 2. Listar os dispositivos USB conectados
usbipd list

# 3. Compartilhar e anexar a porta serial (exemplo: busid 1-11)
usbipd attach --busid 1-11 --wsl
```

### 2.3 Ajustes necessários no WSL2 (Ubuntu/Debian)
Para contornar o kernel customizado do WSL2:
```bash
sudo apt update
sudo apt install linux-tools-generic hwdata
sudo update-alternatives --install /usr/local/bin/usbip usbip $(ls /usr/lib/linux-tools/*/usbip | tail -n1) 20
```

Se a porta `/dev/ttyUSB0` ficar travada por sessões anteriores:
```bash
sudo killall -9 minicom
sudo rm -f /var/lock/LCK..ttyUSB0 /run/lock/LCK..ttyUSB0 /tmp/LCK..ttyUSB0
sudo minicom -D /dev/ttyUSB0 -b 115200 -o
```

---

## 3. Descobertas de Arquitetura no U-Boot

### 3.1 Mapeamento da Memória Flash (SPI-NAND 128MB)
O particionamento MTD do dispositivo é:
- `loader` (0x00000000 - 0x00200000): 2MB — U-Boot / TPL
- `image` (0x00200000 - 0x07480000): ~114MB — Volumes UBI (`bootfs1`, `rootfs1`, `data`, `defaults`)
- `tpconfig` (0x07480000 - 0x07800000): 3.5MB — Volume UBI `tp_data`
- `userconfig` (0x07800000 - 0x07F00000): 7MB — Volumes UBI `user_data1`, `user_data2`

### 3.2 Dados de Fábrica Extraídos da Partição `tp_data`
Ao montar o volume UBI `tp_data` no U-Boot:
- **PIN WPS padrão:** `74212217`
- **Senha padrão do Wi-Fi de fábrica:** `74212217` (SSIDs: `TP-Link_E1FC` e `TP-Link_E1FC_5G`)
- **Endereço MAC:** `68:7F:F0:82:E1:FC`
- **ID do Hardware:** `6F9F815F7F5CCC6D5FC0C06BB740B6A8`

### 3.3 Identificação do Console Real do Kernel
Inspecionando o Device Tree (`fdt_TPBE220` dentro da FIT Image no volume `bootfs1`):
```text
chosen {
    stdout-path = "serial0:115200n8";
    bootargs = "coherent_pool=4M cpuidle_sysfs_switch pci=pcie_bus_safe isolcpus=3 init=/etc/preinit console=ttyAMA0,115200 earlycon rootwait rng_core.default_quality=1024";
};
```
- O driver da UART serial é o **ARM PrimeCell PL011** (`arm,pl011`).
- O nó Linux correto é **`ttyAMA0`** (e não `ttyS0`).

---

## 4. O Mecanismo de Bloqueio da TP-Link

Nos firmwares de produção da TP-Link:
1. O U-Boot injeta por padrão o parâmetro `test_mode=disable` na linha de comando do kernel.
2. Módulos de segurança da TP-Link (`user-debug`, `kmonitor`) desativam as rotinas de recepção serial (RX) do driver do console para evitar acesso não autorizado.
3. Se você tentar dar boot com `init=/bin/sh` sem passar o parâmetro `mtdparts`, o kernel entra em **Kernel Panic** porque não encontra a partição MTD `image` para montar o UBI.
4. Além disso, no modo `/bin/sh` puro, o watchdog de hardware (`wdt0`) não é alimentado e reinicia o roteador após ~80 segundos.

---

## 5. A Solução Definitiva: Ativação do Modo de Teste de Fábrica

A TP-Link possui um comando interno no U-Boot especificamente para bancada de testes que reverte esse bloqueio:

### Passo a Passo da Execução:

1. **Ligue o roteador** com o cabo serial conectado e o minicom aberto.
2. Durante a contagem de 1 segundo (`Hit any key to stop autoboot`), **pressione qualquer tecla repetidamente** para entrar no prompt do U-Boot:
   ```text
   =>
   ```
3. **Execute o comando de desbloqueio:**
   ```bash
   test_mode enable
   ```
4. **Inicie o boot do firmware oficial:**
   ```bash
   sdk boot_img
   ```

### Resultado:
- O U-Boot injeta `test_mode=enable` no kernel.
- O Linux inicializa normalmente todos os serviços e drivers.
- O watchdog de hardware é gerenciado normalmente (sem reinicializações indesejadas).
- **A porta serial fica totalmente destravada para entrada de dados!**
- Ao final do boot (ou ao pressionar `ENTER`), a tela de **Login** é exibida!

---

## 6. Mapeamento Completo da Memória Flash (MTD)

Extraído diretamente do kernel Linux via `/proc/mtd`:

| Dispositivo | Tamanho Hex | Tamanho Real | Nome da Partição | Descrição |
|---|---|---|---|---|
| `/dev/mtd0` | `08000000` | **128 MiB** | **`spi1.0`** | **Flash Completa (Dump bit a bit de todo o chip)** |
| `/dev/mtd1` | `00200000` | 2 MiB | `loader` | Bootloader U-Boot e TPL |
| `/dev/mtd2` | `07280000` | 114.5 MiB | `image` | Contêiner UBI com bootfs, rootfs, data |
| `/dev/mtd3` | `00380000` | 3.5 MiB | `tpconfig` | Volume UBI `tp_data` (dados de fábrica, PIN WPS, MAC) |
| `/dev/mtd4` | `00700000` | 7 MiB | `userconfig` | Configurações persistentes do usuário (`user_data1/2`) |
| `/dev/mtd5` | `00000110` | 272 bytes | `metadata1` | Metadados de boot A/B (partição 1) |
| `/dev/mtd6` | `00000110` | 272 bytes | `metadata2` | Metadados de boot A/B (partição 2) |
| `/dev/mtd7` | `006e4780` | ~6.9 MiB | `bootfs1` | Imagem FIT (Kernel Linux + Device Trees + ATF) |
| `/dev/mtd8` | `01f9b000` | ~31.6 MiB | `rootfs1` | Sistema de arquivos Squashfs (Root) |
| `/dev/mtd9` | `0020f000` | ~2.0 MiB | `data` | Dados e configurações de NVRAM do rádio Wi-Fi |
| `/dev/mtd10`| `00117000` | ~1.1 MiB | `defaults` | Configurações padrão de fábrica |

---

## 7. Como tornar `/etc` gravável para alterar senhas

Como o rootfs está em `squashfs` (somente leitura), o comando `passwd` falha por padrão. Para torná-lo gravável temporariamente na RAM:

```sh
mkdir -p /tmp/etc
cp -a /etc/* /tmp/etc/
mount -o bind /tmp/etc /etc
passwd root
```

---

## 8. Procedimento Completo: Root Shell + Ativação de Rede (`eth0`)

Quando você inicializa diretamente pelo `/bin/sh`, o Linux não sobe os drivers de rede proprietários da Broadcom nem monta a RAM em `/tmp`. O passo a passo completo para contornar isso e obter rede 100% ativa é:

### Passo 1: Boot pelo U-Boot com Shell Direto e Watchdog Estendido
No U-Boot (`=>`):
> [!TIP]
> Você também pode rodar `test_mode on` (ou `test_mode enable`) diretamente no prompt do U-Boot para desbloquear o console antes de inicializar!

```bash
setenv bootargs_append ""
setenv bootargs "coherent_pool=4M cpuidle_sysfs_switch pci=pcie_bus_safe isolcpus=3 console=ttyAMA0,115200 earlycon rootwait rng_core.default_quality=1024 mtdparts=spi1.0:2097152(loader),120061952@2097152(image),3670016@122159104(tpconfig),7340032@125829120(userconfig) root=/dev/ubiblock0_4 ubi.mtd=image ubi.block=0,4 rootfstype=squashfs init=/bin/sh test_mode=enable bcm96xxx_wdt.heartbeat=3600"
sdk boot_img
```

### Passo 2: Configuração Inicial no Shell Root (`/ #`)
Assim que entrar no prompt `/ #`:
```sh
# 1. Desarmar o Watchdog de hardware para nunca reiniciar sozinho
echo V > /dev/watchdog

# 2. Montar os pseudo-sistemas de arquivos e memória RAM
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
```

### Passo 3: Ativação dos Drivers e Energia dos Transceptores Físicos (PHYs)
No `/bin/sh`, as interfaces físicas (`eth0`, `eth1`, etc.) e os transceptores elétricos (PHYs) começam em modo **Power Down** (`power set is disabled!!!` no dmesg). Para ligar a energia física e estabelecer o link elétrico de 1 Gbps / 2.5 Gbps:

```sh
# 1. Carregar os drivers Broadcom/Archer no kernel
. /lib/preinit/05_init_interfaces_brcm
init_brcm_mount_fs
init_brcm_base_drivers
init_brcm_enet

# 2. Desbloquear a trava de energia e ligar os transmissores físicos (PHYs)
ethswctl -c powerset-enable -v 1
ethctl eth0 phy-power up
ethctl eth4 phy-power up
ethctl eth1 phy-power up
echo sgmii 1 > /proc/driver/phy/rtl8367s
```

**Confirmação no `dmesg`:**
```text
eth0 (Int switch port: 0) (Logical Port: 0) (phyId: 8) Link Up at 1000 mbps full duplex AN: On
IPv6: ADDRCONF(NETDEV_CHANGE): eth0: link becomes ready
```

---

### Passo 4: Desbloqueio do Switch Broadcom (Evitando Pacotes Descartados / Dropped)
Por padrão de segurança do SoC BCM6764, o switch interno descarta todos os pacotes de entrada na `eth0` (`RX packets: ... dropped: ...`) devido ao Spanning Tree (STP) e isolamento da WAN. Para liberar o tráfego IP:

```sh
# 1. Desativar Spanning Tree do switch e habilitar a eth0 para tráfego local
ethswctl -c hwstp -i eth0 -o disable
ethswctl -c wan -i eth0 -o enable

# 2. Desativar acelerações e filtros de pacote (Flow Cache / BLOG)
ifconfig eth0 promisc
fcctl disable 2>/dev/null
blogctl disable 2>/dev/null

# 3. Atribuir o IP e resetar a interface para aplicar as regras
ifconfig eth0 192.168.12.1 netmask 255.255.255.0 up
```

---

### Passo 5: Backup Completo de 128MB para o PC (PowerShell + Netcat)
No ambiente mínimo `/bin/sh`, o servidor web `uhttpd` não inicia por depender do daemon `ubus`. A forma mais rápida, estável e 100% nativa de transferir a memória flash completa para o Windows sem instalar nenhum programa externo é usando um socket TCP no PowerShell:

#### No Windows (PowerShell):
Abra o PowerShell no Windows, configure a placa de rede com IP estático `192.168.12.2` (máscara `255.255.255.0`) e execute o receptor:

```powershell
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, 8080)
$listener.Start()
Write-Host ">> Aguardando conexao do roteador na porta 8080..."
$client = $listener.AcceptTcpClient()
Write-Host ">> Conectado! Gravando dump de 128MB na pasta Downloads..."
$stream = $client.GetStream()
$file = [System.IO.File]::Create("$HOME\Downloads\archer_be220_full_dump.bin")
$stream.CopyTo($file)
$file.Close()
$client.Close()
$listener.Stop()
Write-Host ">> SUCESSO! Backup salvo em: $HOME\Downloads\archer_be220_full_dump.bin"
```

#### No Roteador (Terminal Serial):
Com o script do PowerShell aguardando no PC, envie a flash SPI-NAND inteira (`mtd0`) diretamente pelo cabo de rede:

```sh
cat /dev/mtd0 | nc 192.168.12.2 8080
```
*(A transferência direta da flash a 1 Gbps leva aproximadamente 8 a 12 segundos. Ao concluir, o socket fecha automaticamente e o PowerShell exibirá `SUCESSO!`)*.

#### Conferindo o Arquivo Gerado:
No Windows PowerShell:
```powershell
(Get-Item "$HOME\Downloads\archer_be220_full_dump.bin").Length
```
O tamanho exato deve ser rigorosamente **134.217.728 bytes** (128 MB exatos).

---

## 9. Modificação Permanente do Firmware: Root Serial + SSH (Dropbear)

Esta etapa modifica a partição `rootfs1` (Squashfs, `mtd8`) para habilitar permanentemente o acesso root via serial e SSH.

> [!IMPORTANT]
> **Faça o backup de 128 MB descrito na Seção 8 antes de continuar!** O backup garante que você pode restaurar o firmware de fábrica caso algo dê errado.

---

### 9.1 — Extração do Squashfs (Descompactação)

No seu terminal **WSL2** (Ubuntu):

#### Instalar as ferramentas:
```bash
sudo apt-get update && sudo apt-get install -y squashfs-tools
```

#### Inspecionar os parâmetros do Squashfs original (OBRIGATÓRIO):
```bash
unsquashfs -s mtd8_rootfs1.bin
```

**Resultado real do Archer BE220:**
```
Found a valid SQUASHFS 4:0 superblock on mtd8_rootfs1.bin.
Filesystem size 33095822 bytes (31.56 Mbytes)
Compression xz
Block size 1048576
```
> [!IMPORTANT]
> Anote a **Compressão** e o **Block size**. Esses dois valores são obrigatórios para recompactar corretamente. No BE220: `xz` e `1048576` (1 MB).

#### Extrair para uma pasta editável:
```bash
unsquashfs -d squashfs-root mtd8_rootfs1.bin
```
Uma pasta `squashfs-root/` é criada com todos os arquivos do sistema do roteador.

---

### 9.2 — Modificações Necessárias nos Arquivos

Todos os arquivos ficam dentro da pasta `squashfs-root/`. No WSL2, o caminho completo é `/mnt/f/OpenWRT/.../GPL/squashfs-root/`.

---

#### Arquivo 1: `/etc/inittab` — Desbloqueio da Console Serial

A TP-Link comentou a linha do shell root direto e substituiu por `/bin/login` (que falha porque o `/etc/shadow` tem `x`):

```diff
- #ttyAMA0::askfirst:/bin/ash --login
- ttyAMA0::askfirst:/bin/login
+ ttyAMA0::askfirst:/bin/ash --login
+ #ttyAMA0::askfirst:/bin/login
```

**Efeito:** Ao conectar o cabo serial e apertar **Enter**, o roteador cai direto no prompt `#` como root, sem pedir login nem senha.

#### Arquivo 2: `/etc/shadow` e `/etc/passwd` — Senha do Root para SSH

> [!IMPORTANT]
> **Pegadinha do Dropbear:** O binário do Dropbear da TP-Link lê o hash da senha diretamente da estrutura `passwd` (`/etc/passwd`). Se o `/etc/passwd` contiver `root:x:...`, o Dropbear falha com o erro:
> `User account 'root' is locked`
> Portanto, o hash da senha **deve ser gravado tanto no `/etc/shadow` quanto no `/etc/passwd`**!

```diff
# No /etc/shadow:
- root:x:0:0:99999:7:::
+ root:$1$epcfkocI$ohDOvIs9Jz.P0WxBWFUZf1:0:0:99999:7:::

# No /etc/passwd:
- root:x:0:0:root:/root:/bin/ash
- admin:x:1000:0:admin:/var:/bin/false
+ root:$1$epcfkocI$ohDOvIs9Jz.P0WxBWFUZf1:0:0:root:/root:/bin/ash
+ admin:x:1000:0:admin:/root:/bin/ash
```

O hash acima foi gerado nativamente pelo comando `passwd` do próprio sistema do Archer BE220 e corresponde à senha `<ROOT_PASSWORD>`.

**Efeito:** O Dropbear (servidor SSH) e o comando `login` autenticam o root sem travas, e o usuário `admin` ganha shell `/bin/ash`.

#### Arquivo 3: `/etc/rc.d/S99zzzzboot_done` — A Inicialização Completa do SSH

> [!CAUTION]
> **Pegadinha 1 (O Arquivo de Boot Real):** No OpenWrt tradicional, scripts customizados são colocados no `/etc/rc.local`. Porém, a TP-Link **removeu** o script `/etc/init.d/done` da pasta `/etc/rc.d/`. Portanto, **o `/etc/rc.local` nunca é executado pelo sistema**! O **único script final** que o inicializador da TP-Link (`rcS`) executa no término do boot é o **`/etc/rc.d/S99zzzzboot_done`**.

> [!CAUTION]
> **Pegadinha 2 (A Trava Secreta e Deliberada da TP-Link — Flag `-L`):**  
> Em uma **tentativa deliberada de impedir qualquer acesso a terminal**, a TP-Link modificou o código-fonte C oficial do Dropbear (`svr-runopts.c` e `svr-chansession.c`), criando uma trava proprietária baseada na variável interna `svr_opts.sessionEnable` (que inicia desligada como `0`).  
> **Como a armadilha funciona:** O Dropbear aceita a senha e a chave pública, mas quando o cliente solicita o terminal (`pty-req`, `shell` ou `exec`), o código proprietário da TP-Link **aborta a requisição silenciosamente**, gerando os erros:
> - `PTY allocation request failed on channel 0`
> - `shell request failed on channel 0`
> - `exec request failed on channel 0`
> O objetivo dessa modificação foi criar uma "porta cega": mesmo que alguém consiga subir o daemon e autenticar a senha, o roteador não abre o shell! A **única chave para desarmar essa trava secreta da TP-Link** é passar o parâmetro proprietário **`-L`** na linha de comando do Dropbear.

> [!IMPORTANT]
> **Pegadinha 3 (O Pseudoterminal PTY e devpts):**  
> 1. O kernel da Broadcom monta o `/dev/pts` com `ptmxmode=000` (permissão zero para novos terminais). É obrigatório remontar com `mode=666,ptmxmode=666`.
> 2. O `/dev/ptmx` original é um nó estático morto (`1969`). Ele deve ser substituído por um link simbólico apontando para `pts/ptmx` (`/dev/pts/ptmx`).

Dentro da função `start()` de `/etc/rc.d/S99zzzzboot_done`:
```sh
start() {
    touch /tmp/dut_bootdone

    # 1. Neutralizar a trava de bloqueio por tentativas falhas (brute-force)
    # ATENCAO: Apenas remover o arquivo (rm -f). Nunca criar link simbolico para /dev/null,
    # pois a funcao fscanf() da biblioteca C da Broadcom trava em loop ao ler /dev/null!
    mkdir -p /var/dropbear /dev/pts
    rm -f /var/dropbear/fail_count

    # 2. Configurar devpts com permissão total e link do ptmx real
    mount -o remount,mode=666,ptmxmode=666 /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts -o mode=666,ptmxmode=666 2>/dev/null || true
    rm -f /dev/ptmx
    ln -sf pts/ptmx /dev/ptmx
    chmod 666 /dev/pts/ptmx /dev/ptmx 2>/dev/null || true

    # 3. Iniciar Dropbear na porta 22 com a flag secreta -L e permitir senha (-B)
    /usr/sbin/dropbear -p 22 -L -B &

    return 0
}
```

---

### 9.3 — A Armadilha dos Links Simbólicos (NTFS vs ext4)

> [!WARNING]
> **PERIGO DE KERNEL PANIC (`error -2`):**  
> Se o comando `unsquashfs` for executado diretamente em uma partição formatada em **Windows NTFS** (ex: `/mnt/f/...` no WSL2), o Windows **descarta silenciosamente todos os 459 links simbólicos** do Linux (incluindo `/bin/sh -> busybox`).  
> Quando esse rootfs é gravado no roteador, o kernel entra em pânico imediato:
> `Kernel panic - not syncing: Requested init /etc/preinit failed (error -2)`
> porque `/etc/preinit` precisa de `#!/bin/sh` e o arquivo `/bin/sh` sumiu!
>
> **Regra Obrigatória:** Toda extração e modificação do Squashfs **deve** ocorrer em uma pasta dentro do sistema de arquivos nativo do Linux (**ext4**, ex: `/tmp` ou `~` no WSL2).

---

### 9.4 — O Script Automatizado: `build_rootfs.sh` (Versão 3 — Com Chave SSH, PTY e Flag `-L`)

Para eliminar qualquer risco de erro humano, perda de links simbólicos ou bloqueios por tentativas falhas de senha, criamos o script automatizado:  
📄 [`build_rootfs.sh`](file:///f:/OpenWRT/BE230V2.6+BE3500V1.6+BE3600%20ProV1.6_GPL_20250918/GPL/build_rootfs.sh)

Ele realiza todo o processo de forma 100% segura dentro do WSL2:
1. Extrai o `mtd8_rootfs1.bin` original diretamente no `/tmp/be220_squashfs_work` (ext4 nativo, garantindo os **459 symlinks** intactos).
2. Aplica automaticamente os patches no `inittab`, `shadow` e `passwd`.
3. Injeta a **chave pública SSH RSA do usuário** diretamente em `/etc/dropbear/authorized_keys` e `/root/.ssh/authorized_keys` (com permissões `0600`).
4. Registra a conta `root` no `/etc/config/accountmgnt` para suporte à função proprietária `svr_auth_uci()`.
5. Substitui o nó estático `/dev/ptmx` pelo link simbólico `pts/ptmx`.
6. Insere o inicializador completo no `S99zzzzboot_done` desarmando a trava secreta da TP-Link com a flag **`-L`** (`sessionEnable`), além da calibração do `devpts` e neutralização do `fail_count`.
7. Recompacta com `mksquashfs` usando XZ e blocos de 1 MB:
   ```bash
   mksquashfs /tmp/be220_squashfs_work rootfs1_mod.bin -comp xz -b 1048576 -noappend -root-owned
   ```
8. Valida a integridade dos 4667 inodes e 460 symlinks.

Para rodar o script no WSL2 a qualquer momento:
```bash
bash build_rootfs.sh
```

---

### 9.5 — Upload e Gravação via U-Boot (TFTP → UBI)

A gravação é feita pelo **U-Boot** (bootloader), garantindo que nenhum arquivo esteja em uso e que o driver UBI gerencie os blocos da flash com segurança.

#### Passo 1: Servidor TFTP no Windows
Execute o script em Python nativo na raiz do projeto (dispensa instalação de programas extras):
```powershell
python serve_tftp.py
```
*(Ele abre a porta UDP 69 e aguarda a conexão do U-Boot)*.

> **Configuração de Rede:** Placa Ethernet do Windows em **`192.168.12.2`** (máscara `255.255.255.0`), conectada à porta **WAN / 2.5G** do roteador.

#### Passo 2: Parar no U-Boot
Ligue o roteador e pressione qualquer tecla na serial durante a contagem para entrar no prompt `=>`.

#### Passo 3: Gravar e Tornar o Desbloqueio Permanente

```bash
# 1. Configurar IPs de rede e mascara no bootloader
setenv ipaddr 192.168.12.1
setenv serverip 192.168.12.2
setenv netmask 255.255.255.0

# 2. Sincronizar o link Ethernet com o PC (obrigatorio antes do TFTP)
ping 192.168.12.2

# 3. Conectar a particao UBI da flash
ubi part image

# 4. Baixar a nova imagem completa para a RAM
tftpboot 0x05000000 rootfs1_mod.bin

# 5. Gravar a imagem no volume rootfs1
ubi write 0x05000000 rootfs1 0x1f90000

# 6. TORNAR O DESBLOQUEIO SERIAL PERMANENTE:
# Faz o U-Boot sempre iniciar com test_mode enable automaticamente em todo boot!
setenv bootcmd "test_mode enable; sdk boot_img"
saveenv

# 7. Reiniciar no sistema 100% desbloqueado!
reset
```

---

### 9.6 — Verificação e Acesso Pós-Boot

Assim que o roteador reiniciar:

1. **Acesso Serial (UART):** Pressione **Enter** na janela serial. O terminal abrirá direto no prompt `#` como root, sem pedir login nem senha.
2. **Acesso SSH Sem Senha (Chave Pública RSA):** No PowerShell do seu PC:
   ```powershell
   ssh -i "$HOME\.ssh\id_router" -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.0.1
   ```
   *(Entra instantaneamente no shell sem pedir senha!)*
3. **Acesso SSH com Senha (Alternativa):**
   ```powershell
   ssh root@192.168.0.1
   ```
   **Senha:** `<ROOT_PASSWORD>`
4. **Funcionalidades de Fábrica:** O roteador mantém 100% das suas funções originais de fábrica (Wi-Fi 7, MLO, mesh, tela web e aceleradores Broadcom) completamente operacionais!
