import socket
import struct
import os
import sys

# TFTP Opcodes
OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6

def run_tftp_server(serve_dir=".", bind_ip="0.0.0.0", port=69):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    # No Windows, desativa o erro WSAECONNRESET quando clientes desconectam
    if sys.platform == "win32":
        try:
            SIO_UDP_CONNRESET = 0x9800000C
            sock.ioctl(SIO_UDP_CONNRESET, False)
        except Exception:
            pass
            
    sock.bind((bind_ip, port))
    print(f"[*] Servidor TFTP ativo em {bind_ip}:{port}")
    print(f"[*] Pasta de arquivos: {os.path.abspath(serve_dir)}")
    print("[*] Aguardando solicitacao do U-Boot...")

    while True:
        try:
            data, client_addr = sock.recvfrom(2048)
        except (ConnectionResetError, OSError):
            continue

        if len(data) < 4:
            continue
        
        opcode = struct.unpack("!H", data[:2])[0]
        if opcode != OP_RRQ:
            continue  # Apenas leitura suportada
        
        # Parse RRQ: filename\0mode\0[opt1\0val1\0...]
        parts = data[2:].split(b'\x00')
        req_filename = parts[0].decode('latin1').lstrip('/')
        mode = parts[1].decode('latin1').lower() if len(parts) > 1 else 'octet'
        
        # Parse options (blksize, etc)
        options = {}
        idx = 2
        while idx + 1 < len(parts) and parts[idx]:
            opt_name = parts[idx].decode('latin1').lower()
            opt_val = parts[idx+1].decode('latin1')
            options[opt_name] = opt_val
            idx += 2

        filepath = os.path.join(serve_dir, os.path.basename(req_filename))
        if not os.path.exists(filepath):
            err_pkt = struct.pack("!HH", OP_ERROR, 1) + b"File not found\x00"
            sock.sendto(err_pkt, client_addr)
            print(f"[-] Arquivo nao encontrado: {req_filename}")
            continue
        
        filesize = os.path.getsize(filepath)
        blksize = int(options.get("blksize", 512))
        blksize = min(max(blksize, 512), 1468)
        
        print(f"[+] U-Boot conectou de {client_addr}! Enviando '{os.path.basename(filepath)}' ({filesize} bytes, bloco={blksize})...")
        
        client_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if sys.platform == "win32":
            try:
                SIO_UDP_CONNRESET = 0x9800000C
                client_sock.ioctl(SIO_UDP_CONNRESET, False)
            except Exception:
                pass
        client_sock.settimeout(5.0)

        try:
            with open(filepath, "rb") as f:
                block_num = 0
                
                # Se cliente solicitou options (ex: blksize, tsize), responde OACK
                if options:
                    oack_data = bytearray(struct.pack("!H", OP_OACK))
                    if "blksize" in options:
                        oack_data.extend(b"blksize\x00" + str(blksize).encode() + b"\x00")
                    if "tsize" in options:
                        oack_data.extend(b"tsize\x00" + str(filesize).encode() + b"\x00")
                    
                    for retry in range(5):
                        client_sock.sendto(oack_data, client_addr)
                        try:
                            ack_pkt, _ = client_sock.recvfrom(512)
                            if len(ack_pkt) >= 4:
                                ack_op, ack_block = struct.unpack("!HH", ack_pkt[:4])
                                if ack_op == OP_ACK and ack_block == 0:
                                    break
                        except socket.timeout:
                            continue
                
                block_num = 1
                total_sent = 0
                while True:
                    chunk = f.read(blksize)
                    pkt = struct.pack("!HH", OP_DATA, block_num & 0xFFFF) + chunk
                    
                    ack_received = False
                    for retry in range(5):
                        client_sock.sendto(pkt, client_addr)
                        try:
                            ack_pkt, _ = client_sock.recvfrom(512)
                            if len(ack_pkt) >= 4:
                                ack_op, ack_block = struct.unpack("!HH", ack_pkt[:4])
                                if ack_op == OP_ACK and ack_block == (block_num & 0xFFFF):
                                    ack_received = True
                                    break
                        except socket.timeout:
                            continue
                    
                    if not ack_received:
                        print("[-] Timeout de ACK do cliente!")
                        break
                    
                    total_sent += len(chunk)
                    block_num += 1
                    
                    if len(chunk) < blksize:
                        print(f"[OK] Transferencia concluida com sucesso! {total_sent} bytes enviados.")
                        break
        except Exception as e:
            print(f"[-] Erro durante envio: {e}")
        finally:
            client_sock.close()

if __name__ == "__main__":
    serve_dir = os.path.dirname(os.path.abspath(__file__))
    run_tftp_server(serve_dir=serve_dir)
