# Guia de Engenharia Reversa: Upgrade de Firmware/RootFS via SSH
## Plataforma: TP-Link Archer BE220 / Broadcom BCM6764 (BCA SDK)

Este documento descreve detalhadamente o método de upgrade de firmware e RootFS através de sessão SSH remota, sem necessidade de console serial, TFTP ou reinicialização em modo rescue (WPS).

---

## 1. Por que o Método Oficial Web Falha para RootFS Customizado?

Ao tentar enviar um RootFS modificado pela WebUI ou pelo comando `/sbin/sysupgrade`, o roteador aborta com o erro `firmware upgrade file check error`.

### Causa Raiz Criptográfica:
A TP-Link encapsula o processo de verificação no binário fechado `/usr/bin/nvrammanager`. A engenharia reversa do executável revelou as seguintes rotinas de validação:
- **Assinatura RSA-2048 PSS:** O binário valida a assinatura do arquivo `.bin` oficial contra a chave pública da TP-Link gravada na fábrica.
- **Checagem de MD5 e metadados:** Validação estrita de `productName`, `productId`, `productVer` e `productLanguage`.
Qualquer imagem reconstruída em laboratório falha nessa validação e é descartada antes de chegar ao flash.

---

## 2. Arquitetura de Armazenamento Dual-Bank (UBI)

O Archer BE220 utiliza memória Flash NAND SPI de 128 MB (`mtd0`), gerenciada pelo subsistema UBI (`ubi0`).

A memória é dividida em dois bancos simétricos de inicialização:

| Volume UBI | Nome da Partição | Função | Bloco de Montagem |
| :--- | :--- | :--- | :--- |
| **`ubi0_3`** | `bootfs1` | Kernel Linux (Slot 1) | — |
| **`ubi0_4`** | `rootfs1` | SquashFS RootFS (Slot 1) | `/dev/ubiblock0_4` |
| **`ubi0_5`** | `bootfs2` | Kernel Linux (Slot 2) | — |
| **`ubi0_6`** | `rootfs2` | SquashFS RootFS (Slot 2) | `/dev/ubiblock0_6` |
| **`ubi0_1`** | `metadata1` | Metadados BCA de Boot | — |
| **`ubi0_2`** | `metadata2` | Espelho de Metadados BCA | — |

### Mecanismo de Segurança Dual-Bank:
- Em qualquer momento, o sistema operacional está montado **em apenas um dos slots** (por exemplo, no Slot 2: `/dev/ubiblock0_6 on / type squashfs (ro)`).
- O outro slot (Slot 1) permanece **completamente desmontado, ocioso e seguro para escrita**.
- Se a gravação no slot inativo for corrompida ou interrompida, o slot ativo não é afetado, prevenindo *bricking*.

---

## 3. O Utilitário Oficial Broadcom: `/sbin/bcm_flasher`

O SDK da Broadcom traz no próprio sistema um gravador nativo de baixo nível chamado `/sbin/bcm_flasher`:
```text
Flash image burner, usage: /sbin/bcm_flasher [filename of image to burn] [file sizes] [up file offset]
```

Diferente do `sysupgrade`, o `bcm_flasher`:
1. Não depende das checagens RSA proprietárias da TP-Link.
2. Reconhece pacotes FIT padrão Broadcom (`conf_6764_nand_squashfs`), gerados pelo script `generate_recovery_bundle.sh`.
3. Grava automaticamente o Kernel e o RootFS no **slot inativo**.
4. Atualiza os metadados de inicialização (`metadata1`/`metadata2`), definindo o novo slot como `COMMITTED` e incrementando o contador de sequência (`SEQ`).

---

## 4. A Descoberta Crítica: O "Bug/Gotcha" do `upfileoffset`

Ao tentar executar o comando básico passando offset zero:
```bash
/sbin/bcm_flasher /tmp/recovery_bundle.bin $FILESIZE 0
```
O utilitário aborta imediatamente com:
```text
Flash image filesize = 36547576, upfileoffset = 0.
Flash image filesize = 36547576, upfileoffset = 0. Error: Aborting
```

### Análise Assembly ARM do `bcm_flasher`:
Ao desmontar a rotina `main` do executável ARM, encontramos o seguinte trecho:

```arm
0x00010a34:  ldr   r0, [r6, #8]    ; argv[2] (filesize)
0x00010a38:  bl    strtoul         ; sl = valor numérico de filesize
0x00010a48:  ldr   r0, [r6, #12]   ; argv[3] (upfileoffset)
0x00010a4c:  bl    strtoul         ; r7 = valor numérico de upfileoffset

0x00010a6c:  cmp   r7, #0          ; Compara upfileoffset com 0
0x00010a70:  cmpne sl, #0          ; Se upfileoffset != 0, compara filesize com 0
0x00010a74:  moveq fp, #1          ; Se algum for 0, marca flag de erro (fp = 1)
0x00010a78:  movne fp, #0          ; Se ambos forem > 0, sucesso (fp = 0)
0x00010a7c:  bne   #0x10aa0        ; Salta para abrir o arquivo e iniciar o flash
0x00010a80:  ldr   r1, = "Flash image filesize = %d, upfileoffset = %d. Error: Aborting"
```

### Por que essa checagem existe?
O `bcm_flasher` foi escrito para receber arquivos temporários gerados por formulários multipart de servidores web CGI da Broadcom. Nesses servidores, o arquivo em disco contém o cabeçalho HTTP inicial e o firmware real começa após os cabeçalhos.
A Broadcom codificou a checagem:
```c
if (upfileoffset == 0 || filesize == 0) {
    printf("Flash image filesize = %d, upfileoffset = %d. Error: Aborting\n", filesize, upfileoffset);
    return -1;
}
```
**O `bcm_flasher` rejeita `upfileoffset == 0` por design!** Mais adiante no código, ele executa:
```arm
0x00010b40:  bl fseek(fd, upfileoffset, SEEK_SET)
0x00010b38:  sub r3, filesize, upfileoffset   ; image_length = filesize - upfileoffset
```

### A Solução do Padding (Preenchimento de 512 bytes):
Para contornar essa trava:
1. Criamos um cabeçalho artificial de **512 bytes** de zeros (`pad.bin`).
2. Concatenamos antes da imagem: `cat pad.bin recovery_bundle.bin > flash_bundle.bin`.
3. Passamos `filesize = (tamanho_original + 512)` e `upfileoffset = 512`.
4. O `bcm_flasher` valida que `upfileoffset != 0`, faz `fseek(512)` e encontra exatamente o início do pacote FIT, liberando a gravação!

---

## 5. Procedimento Passo a Passo para Upgrade via SSH

### Passo 1: Gerar o Pacote FIT no PC (WSL)
Execute no Ubuntu-24.04 (que possui a ferramenta `mkimage` instalada):
```bash
wsl -d Ubuntu-24.04 bash generate_recovery_bundle.sh
```
*Saída gerada:* `recovery_bundle.bin` (~35 MB).

---

### Passo 2: Enviar o Arquivo para a RAM do Roteador
Como o servidor SSH do roteador é o **Dropbear**, ele não possui o binário do subsistema SFTP (`/usr/libexec/sftp-server`). 

No PowerShell do PC, use a flag **`-O`** para usar o protocolo SCP legado:
```powershell
scp -O recovery_bundle.bin root@192.168.12.1:/tmp/
```
*(A transferência direta leva cerca de 4 a 5 segundos via Gigabit Ethernet).*

---

### Passo 3: Aplicar o Padding e Executar a Gravação no Roteador

Acesse o SSH do roteador (`ssh root@192.168.12.1`) e execute:

```bash
# 1. Criar o cabeçalho de 512 bytes e concatenar:
dd if=/dev/zero of=/tmp/pad.bin bs=512 count=1 2>/dev/null
cat /tmp/pad.bin /tmp/recovery_bundle.bin > /tmp/flash_bundle.bin
rm -f /tmp/pad.bin

# 2. Obter o tamanho exato com o padding:
FILESIZE=$(ls -l /tmp/flash_bundle.bin | awk '{print $5}')

# 3. Executar o gravador oficial Broadcom com offset 512:
/sbin/bcm_flasher /tmp/flash_bundle.bin $FILESIZE 512
```

### O que acontece durante a execução:
1. O `bcm_flasher` exibe:
   ```text
   imgif: Enabling NAND image flashing functions!
   Flash type 0x2, flash size 0x7280000, block size 0x20000
   ```
2. Os pontos (`....`) indicam a gravação dos blocos UBI no slot inativo.
3. Ao término, os metadados são atualizados e a mensagem de sucesso é exibida:
   ```text
   Image flash complete, you may reboot the board
   Image change to another new state
   ```

---

### Passo 4: Reinicialização
Após o término, reinicie o roteador:
```bash
reboot
```

---

### Passo 5: Validação Pós-Boot
Após a reinicialização (cerca de 60 segundos), conecte novamente via SSH e verifique a partição montada:
```bash
mount | grep ' / '
```
- Se o roteador estava rodando no **Slot 2 (`ubiblock0_6`)**, ele agora estará no **Slot 1 (`ubiblock0_4`)**, confirmando o upgrade com sucesso!
