# Diretrizes e Restrições — TP-Link Archer BE220 (BCM6764 / Wi-Fi 7)

## 1. Credenciais e Acesso SSH
- **IP padrão:** `192.168.0.1` (porta `22`)
- **Usuário:** `root`
- **Senha:** `<ROOT_PASSWORD>`
- **Chave Privada:** `C:\Users\<USER>\.ssh\id_router`
- **Algoritmo Obrigatório OpenSSH:** `-o PubkeyAcceptedAlgorithms=+ssh-rsa`
- **Comando de Acesso:**
  ```powershell
  ssh -i "$HOME\.ssh\id_router" -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.0.1
  ```

## 2. Travas Proprietárias da TP-Link (Dropbear & Kernel)
- **Flag Secreta `-L` (Obrigatória):** O Dropbear da TP-Link foi modificado para recusar requisições de PTY e shell (`svr_opts.sessionEnable == 0`) a menos que seja iniciado com a flag `-L`. Sempre inicie com `/usr/sbin/dropbear -p 22 -L -B &`.
- **Anti-Lockout (`/var/dropbear/fail_count`):** Após 10 tentativas falhas, o Dropbear bloqueia o IP por 120 minutos. Para destravar, use `rm -f /var/dropbear/fail_count`. **NUNCA** crie link simbólico para `/dev/null`, pois a função `fscanf()` da biblioteca C da Broadcom entra em loop infinito e trava a negociação SSH!
- **Alocação de Pseudoterminal (PTY):** O kernel monta `/dev/pts` com permissão zero (`ptmxmode=000`). É necessário remontar com `mode=666,ptmxmode=666` e substituir `/dev/ptmx` por um symlink apontando para `pts/ptmx`.
- **Boot Hook Real:** A TP-Link removeu `/etc/init.d/done`, logo `/etc/rc.local` nunca é executado no boot. Todos os serviços customizados devem ser inseridos em `/etc/rc.d/S99zzzzboot_done`.

## 3. Manipulação do Sistema de Arquivos Squashfs
- **Regra do ext4:** Nunca descompacte ou compacte imagens Squashfs em partições Windows NTFS (`/mnt/f/...`). O NTFS descarta silenciosamente os 460 links simbólicos do Linux, causando `Kernel panic - not syncing: Requested init /etc/preinit failed (error -2)`. Sempre use `/tmp` ou o ext4 nativo do WSL2.

## 4. Execução de Comandos, Consultas e Scripts com o Roteador
- **Autonomia Total para Consultas e Scripts:** O usuário autorizou expressamente que **não é necessário pedir autorização** para rodar consultas, diagnósticos, inspeções, requisições HTTP, conexões SSH ou scripts que se comuniquem com o roteador. Execute de forma direta e proativa, mantendo sempre o registro dos resultados.
- **Pasta `scratch/` e Execução Sem Confirmação Prévia:** Qualquer script de apoio temporário (Node.js `.mjs`/`.js`, Python, Shell, etc.) deve ser salvo exclusivamente na pasta `scratch/` e **pode ser executado diretamente sem pedir confirmação prévia** ao usuário.
- **Ações Críticas que Exigem Confirmação:** Apenas remoção destrutiva de arquivos essenciais ou gravação direta/flash de partições MTD exigem aviso prévio.
