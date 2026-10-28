import datetime
import os
import subprocess
import sys

LOG_FILE = os.path.join(os.path.dirname(__file__), "router_commands.log")

def run_ssh(cmd):
    full_cmd = [
        "sshpass", "-p", "<ROOT_PASSWORD>",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "root@192.168.0.1", "sh"
    ]
    res = subprocess.run(full_cmd, input=cmd, capture_output=True, text=True)
    
    # Registra log auditável da execução
    try:
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a", encoding="utf-8") as lf:
            lf.write(f"[{now}] COMMAND:\n{cmd.strip()}\nEXIT_CODE: {res.returncode}\n")
            if res.stdout:
                lf.write(f"STDOUT:\n{res.stdout.strip()}\n")
            if res.stderr:
                lf.write(f"STDERR:\n{res.stderr.strip()}\n")
            lf.write("-" * 60 + "\n")
    except Exception:
        pass

    return res.stdout, res.stderr, res.returncode

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "uname -a"
    out, err, code = run_ssh(cmd)
    print("STDOUT:\n" + out)
    if err:
        print("STDERR:\n" + err)
    print("CODE:", code)
