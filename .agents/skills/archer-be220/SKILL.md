---
name: archer-be220
description: Ações rápidas, compilação de rootfs e conexão SSH para o TP-Link Archer BE220
---

# Procedimentos Operacionais — Archer BE220

## 1. Conexão SSH Rápida

**Credenciais:**
- Host: `192.168.0.1`
- Usuário: `root`
- Senha: `<ROOT_PASSWORD>`

```powershell
# Com chave (se disponível)
ssh -i "$HOME\.ssh\id_router" -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.0.1

# Com senha (padrão)
ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no root@192.168.0.1
# senha: <ROOT_PASSWORD>
```

### Via Python (paramiko) — preferido para automação:
```python
import paramiko
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.0.1', username='root', password='<ROOT_PASSWORD>', look_for_keys=False, allow_agent=False)
```

## 1b. Deploy do floresta_agent.lua

Servir arquivos de `web_deploy/` na porta 8099 e baixar no roteador via wget:
```powershell
# 1. Iniciar servidor de arquivos (no diretório GPL/)
python -S -m http.server 8099 --directory web_deploy

# 2. Executar deploy
python deploy_tunnel_agent.py   # ou deploy_fixes.py para deploy completo
```

Ou via paramiko diretamente (sem pexpect):
```python
import paramiko, time
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('192.168.0.1', username='root', password='<ROOT_PASSWORD>', look_for_keys=False, allow_agent=False)
ssh.exec_command('wget -O /data/floresta_agent.lua http://192.168.0.2:8099/floresta_agent.lua')
time.sleep(3)
ssh.exec_command('killall -9 lua 2>/dev/null; sleep 1; /usr/bin/lua /data/floresta_agent.lua >/tmp/floresta_agent.log 2>&1 &')
```

## 2. Recompilar o RootFS Modificado (WSL)
```bash                                                                                                                 
wsl bash /mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600\ ProV1.6_GPL_20250918/GPL/build_rootfs.sh
```

## 2b. Upgrade Remoto de Firmware/RootFS via SSH (Sem U-Boot / Sem Serial)
*Guia completo de engenharia reversa:* [archer_be220_ssh_upgrade_guide.md](../../GUIDES/archer_be220_ssh_upgrade_guide.md)

1. **Gerar o pacote FIT no PC (Ubuntu-24.04):**
   ```bash
   wsl -d Ubuntu-24.04 bash generate_recovery_bundle.sh
   ```
   *(Isso gera `recovery_bundle.bin` com cabeçalho TP-Link para Rescue Mode e `recovery_bundle_raw_fit.bin` com FIT puro para `bcm_flasher`)*
2. **Enviar o FIT puro via SCP legado (`-O`) para a RAM do roteador:**
   ```powershell
   scp -O recovery_bundle_raw_fit.bin root@192.168.12.1:/tmp/
   ```
3. **No SSH do roteador, aplicar padding de 512 bytes (trava do `upfileoffset` do bcm_flasher) e queimar:**
   ```bash
   dd if=/dev/zero of=/tmp/pad.bin bs=512 count=1 2>/dev/null
   cat /tmp/pad.bin /tmp/recovery_bundle_raw_fit.bin > /tmp/flash_bundle.bin && rm -f /tmp/pad.bin
   FILESIZE=$(ls -l /tmp/flash_bundle.bin | awk '{print $5}')
   /sbin/bcm_flasher /tmp/flash_bundle.bin $FILESIZE 512
   reboot
   ```

## 3. Comandos de Gravação no U-Boot

### Opção A: Modo Padrão Dual-Bank (33 MB - Mantém Slot B)
```bash
setenv ipaddr 192.168.12.1
setenv serverip 192.168.12.2
setenv netmask 255.255.255.0
ping 192.168.12.2
ubi part image
tftpboot 0x05000000 rootfs1_mod.bin
# Gravar nos dois slots com o tamanho exato da compilação:
ubi write 0x05000000 rootfs1 0x19aa000
ubi write 0x05000000 rootfs2 0x19aa000
setenv bootcmd "test_mode enable; sdk boot_img"
saveenv
reset
```

### Opção B: Modo Expandido Single-Bank (~66 MB - Descarta Slot B)
```bash
setenv ipaddr 192.168.12.1
setenv serverip 192.168.12.2
setenv netmask 255.255.255.0
ping 192.168.12.2
# Fixar no Slot 1
setenv boot_image 1
setenv committed_image 1
# Reconfigurar UBI (apagar volumes e recriar rootfs1 com 64MB)
ubi part image
ubi remove rootfs2
ubi remove rootfs1
ubi create rootfs1 0x4000000 dynamic
# Baixar e gravar imagem expandida
tftpboot 0x05000000 rootfs1_mod.bin
ubi write 0x05000000 rootfs1 0x19aa000
setenv bootcmd "test_mode enable; sdk boot_img"
saveenv
reset
```

## 4. Gerar Pacote para Rescue Mode (WPS Web UI)
```bash
wsl -d Ubuntu-24.04 bash /mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600\ ProV1.6_GPL_20250918/GPL/generate_recovery_bundle.sh
```
- **Arquivos gerados:**
  - `recovery_bundle.bin` — Contém o **cabeçalho TP-Link (`0x1014` bytes + `fwup-ptn` com `support-list` e `soft-version` + MD5 com salt)** seguido pelo FIT Broadcom (`0xd00dfeed`). Obrigatório para passar pela validação `nm_tpFirmwareCheck` do U-Boot no Rescue Mode.
  - `recovery_bundle_raw_fit.bin` — FIT Broadcom puro (sem cabeçalho TP-Link).
- **Modo Rescue (WPS):** Ligue o roteador segurando o botão WPS por 20s.
- **IP do PC:** `192.168.0.2` (máscara `255.255.255.0`).
- **Acesso:** Navegue até `http://192.168.0.1` e faça o upload de `recovery_bundle.bin`.

---

## 5. Portal Captivo 3000 (Recursos e Acessos)
- **Painel de Administração (Monitoramento de Clientes):** `http://192.168.0.1/captive/admin/`
- **Tela de Login do Cliente:** `http://192.168.0.1/captive/` (ou `http://192.168.0.1/portal/`)
- **API RFC 8908 (CAPPORT):** `http://192.168.0.1/cgi-bin/captive_portal_api`
- **CLI Shell no Roteador:**
  - `portal_ctl status` — Exibe status geral e clientes conectados
  - `portal_ctl sessions` — Lista tabela de sessões ativas
  - `portal_ctl kick <IP>` — Desconecta cliente pelo IP
  - `portal_ctl kick-mac <MAC>` — Desconecta cliente pelo MAC
  - `portal_ctl flush` — Desconecta todos os clientes
  - `portal_ctl whitelist` / `portal_ctl whitelist add <dominio>` — Gerencia Walled Garden

---

## 6. Floresta Cloud Controller (GCP Cloud Run)

- **GCP Project:** `<GCP_PROJECT_ID>`
- **Serviço Cloud Run:** `floresta-controller`
- **Região:** `southamerica-east1`
- **URL Pública:** `https://<CONTROLLER_HOST>`
- **Endpoint WebSocket dos Roteadores:** `https://<CONTROLLER_HOST>/ws/router`

### Deploy Automático:
```powershell
powershell -ExecutionPolicy Bypass -File .\deploy_cloud_run.ps1
```

### Comandos de Adoção e Apontamento:
No roteador (via SSH ou serial):
```sh
set-inform https://<CONTROLLER_HOST>/ws/router
# ou via UCI:
uci set floresta_cloud.global.server_url="https://<CONTROLLER_HOST>/ws/router"
uci commit floresta_cloud
/etc/init.d/floresta_agent restart
```

---

## 7. Gotchas Críticos e Regras Invioláveis

1. **Preservação de Configuração (`floresta_agent`):**
   - NUNCA remover a sincronização/restauração de `/data/etc/config` e `/user_data1/etc/config` em `/etc/init.d/floresta_agent`. Ela é mandatória para roteadores recém-flasheados de fábrica.
2. **Auto-Encerramento de Túneis HTTP (Evitar 429 Rate Exceeded e 503):**
   - O `uhttpd` possui limite de 3 conexões simultâneas (`max_requests 3`).
   - O `server.php` DEVE inspecionar `Content-Length` e o terminador chunked `0\r\n\r\n` para fechar imediatamente o túnel HTTP e enviar `tcp_tunnel_close` ao roteador.
   - NUNCA fechar sockets HTTP sem cabeçalhos (sempre emitir `504 Gateway Timeout` antes do `@fclose`), caso contrário o Cloud Run marca a instância como com falha e ativa `429 Rate exceeded`.
3. **Anti-Vazamento de Referências PHP:**
   - Nunca usar `&$clientMeta[...]` em laços sobre `$clients` no PHP, pois corrompe a tipagem dos sockets em tempo de execução.


