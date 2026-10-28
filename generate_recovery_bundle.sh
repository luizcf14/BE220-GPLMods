#!/usr/bin/env bash
# ==============================================================================
# Script de Geração de Pacote de Recuperação (FIT Bundle) — TP-Link Archer BE220
# Plataforma: Broadcom BCM6764 (BCA SDK)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MTD_DIR="${SCRIPT_DIR}/Copias MTD"
OUTPUT_BUNDLE="${SCRIPT_DIR}/recovery_bundle.bin"
TEMP_ITS="${SCRIPT_DIR}/.recovery_bundle_tmp.its"

if [ -f "${SCRIPT_DIR}/mtd1_loader.bin" ]; then
    LOADER_BIN="${SCRIPT_DIR}/mtd1_loader.bin"
else
    LOADER_BIN="${MTD_DIR}/mtd1_loader.bin"
fi

if [ -f "${SCRIPT_DIR}/mtd7_bootfs1.bin" ]; then
    BOOTFS_BIN="${SCRIPT_DIR}/mtd7_bootfs1.bin"
else
    BOOTFS_BIN="${MTD_DIR}/mtd7_bootfs1.bin"
fi

if [ -f "${SCRIPT_DIR}/rootfs1_mod.bin" ]; then
    ROOTFS_BIN="${SCRIPT_DIR}/rootfs1_mod.bin"
elif [ -f "${SCRIPT_DIR}/mtd8_rootfs1.bin" ]; then
    ROOTFS_BIN="${SCRIPT_DIR}/mtd8_rootfs1.bin"
else
    ROOTFS_BIN="${MTD_DIR}/mtd8_rootfs1.bin"
fi

echo "========================================================"
echo "    Gerador de Firmware de Recuperação (Rescue Mode)   "
echo "               TP-Link Archer BE220 (BCM6764)           "
echo "========================================================"

# 1. Verificar ferramenta mkimage (com fallback para /usr/bin caso não esteja no PATH)
if ! command -v mkimage &> /dev/null; then
    # Fallback: busca direta (Ubuntu-24.04 instala em /usr/bin)
    for candidate in /usr/bin/mkimage /usr/local/bin/mkimage; do
        if [ -x "$candidate" ]; then
            export PATH="$(dirname $candidate):$PATH"
            break
        fi
    done
fi
if ! command -v mkimage &> /dev/null; then
    echo "[-] Erro: 'mkimage' não foi encontrado no PATH!"
    echo "    Instale no Ubuntu/Debian com: sudo apt update && sudo apt install -y u-boot-tools"
    exit 1
fi

# 2. Permitir passagem customizada de arquivos via parâmetros
if [ "$#" -ge 3 ]; then
    LOADER_BIN="$1"
    BOOTFS_BIN="$2"
    ROOTFS_BIN="$3"
    [ -n "$4" ] && OUTPUT_BUNDLE="$4"
fi

# 3. Validar existência das partições
echo "[*] Verificando arquivos de partição:"
for FILE in "$LOADER_BIN" "$BOOTFS_BIN" "$ROOTFS_BIN"; do
    if [ ! -f "$FILE" ]; then
        echo "[-] Arquivo não encontrado: $FILE"
        echo "    Certifique-se de que os arquivos MTD estão presentes em 'Copias MTD/' ou passe como argumentos."
        exit 1
    else
        SIZE=$(du -h "$FILE" | cut -f1)
        echo "    [OK] $(basename "$FILE") ($SIZE)"
    fi
done

# 4. Gerar arquivo .its dinamicamente com caminhos absolutos
echo "[*] Criando estrutura FIT (.its)..."
cat <<EOF > "$TEMP_ITS"
/dts-v1/;

/ {
	description = "Broadcom BCA image upgrade package tree binary";
	#address-cells = <1>;

	images {
		loader_6764 {
			description = "loader";
			data = /incbin/("$LOADER_BIN");
			type = "firmware";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};

		bootfs_6764 {
			description = "bootfs";
			data = /incbin/("$BOOTFS_BIN");
			type = "multi";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};

		rootfs_6764 {
			description = "rootfs";
			data = /incbin/("$ROOTFS_BIN");
			type = "filesystem";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "conf_6764_nand_squashfs";

		conf_6764_nand_squashfs {
			description = "Brcm Image Bundle";
			loader = "loader_6764";
			bootfs = "bootfs_6764";
			rootfs = "rootfs_6764";
			compatible = "flash=nand;chip=6764;fstype=squashfs";
		};
	};
};
EOF

# 5. Compilar com mkimage (-E para dados externos, padrão BCA)
echo "[*] Compilando FIT bundle com mkimage..."
RAW_FIT_BUNDLE="${SCRIPT_DIR}/recovery_bundle_raw_fit.bin"
mkimage -f "$TEMP_ITS" -E "$RAW_FIT_BUNDLE"

# 6. Limpar arquivo temporário
rm -f "$TEMP_ITS"

# 7. Empacotar com cabeçalho TP-Link (0x1014 bytes + fwup-ptn + MD5 com salt)
echo "[*] Adicionando cabeçalho TP-Link (fwup-ptn + support-list + soft-version + MD5)..."
python3 - "$SCRIPT_DIR" "$RAW_FIT_BUNDLE" "$OUTPUT_BUNDLE" << 'PYEOF'
import sys, os, struct, hashlib

script_dir, raw_fit_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
support_list_file = os.path.join(script_dir, "squashfs-root", "etc", "partition_config", "support-list")
with open(support_list_file, "rb") as f:
    orig_support_list = f.read().decode("ascii", errors="ignore")

lines = [l.strip() for l in orig_support_list.splitlines() if l.strip()]
extra_entries = [
    "{vendor_name:TP-Link}",
    "{product_name:Archer BE220,product_ver:1.0.0,special_id:42520000}",
    "{product_name:Archer BE220,product_ver:1.0.0,special_id:00000000}",
    "{product_name:Archer BE220,product_ver:1.6.0,special_id:55530000}",
    "{product_name:Archer BE220,product_ver:2.0.0,special_id:55530000}",
    "{product_name:Archer BE220,product_ver:2.6.0,special_id:55530000}",
]
out_lines = [lines[0]]
for e in extra_entries:
    if e not in lines:
        out_lines.append(e)
for l in lines[1:]:
    out_lines.append(l)

support_list_bytes = ("\r\n".join(out_lines) + "\r\n\x00").encode("ascii")
soft_version_bytes = b"soft_ver:77.0.1 Build 20991231 rel.99999\nfw_id:2201DC33F42936D3DC3E01E2D05EA6E2\n\n"

while (0x2c + len(support_list_bytes)) % 4 != 0:
    support_list_bytes += b"\x00"
while (0x2c + len(soft_version_bytes)) % 4 != 0:
    soft_version_bytes += b"\x00"

def make_ptn_hdr(name_str, start_addr, next_off, size):
    return name_str.encode("ascii")[:31].ljust(32, b"\x00") + struct.pack(">III", start_addr, next_off, size)

ptn0_start = 0x2c
ptn0_size = len(support_list_bytes)
ptn0_next = ptn0_start + ptn0_size
ptn1_start = ptn0_next + 0x2c
ptn1_size = len(soft_version_bytes)

ptn_blob = (
    make_ptn_hdr("support-list", ptn0_start, ptn0_next, ptn0_size)
    + support_list_bytes
    + make_ptn_hdr("soft-version", ptn1_start, 0, ptn1_size)
    + soft_version_bytes
)

with open(raw_fit_path, "rb") as f:
    raw_fit = f.read()

total_len = 0x1014 + len(ptn_blob) + len(raw_fit)
body_after_md5 = (b"\x00" * 0x1000) + ptn_blob + raw_fit
tp_salt = bytes.fromhex("7a2b15ed9b98596de504ab44ac2a9f4e")
md5_digest = hashlib.md5(tp_salt + body_after_md5).digest()
final_img = struct.pack(">I", total_len) + md5_digest + body_after_md5

with open(out_path, "wb") as f:
    f.write(final_img)
print(f"    [OK] Header TP-Link aplicado: {total_len:,} bytes (MD5 hdr: {md5_digest.hex()})")
PYEOF

echo ""
echo "[+] Sucesso! Pacotes gerados:"
echo "    1. Com Header TP-Link: $OUTPUT_BUNDLE ($(du -h "$OUTPUT_BUNDLE" | cut -f1))"
echo "    2. FIT Puro (Broadcom): $RAW_FIT_BUNDLE ($(du -h "$RAW_FIT_BUNDLE" | cut -f1))"
echo ""
echo "Instruções de envio:"
echo " 1. Configure sua placa de rede com IP 192.168.0.2 / Máscara 255.255.255.0"
echo " 2. Ligue o roteador mantendo o botão WPS pressionado continuamente por 20 segundos"
echo " 3. Acesse http://192.168.0.1 no navegador"
echo " 4. Selecione o arquivo gerado e clique em 'Upgrade'"
echo "========================================================"

