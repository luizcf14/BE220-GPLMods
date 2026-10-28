import gzip
import re
import os

js_dir = "/mnt/f/OpenWRT/BE230V2.6+BE3500V1.6+BE3600 ProV1.6_GPL_20250918/GPL/captivePortal/be220_port/openwrt/www/webpages/js"

def check_file(fname):
    p = os.path.join(js_dir, fname)
    if not os.path.exists(p):
        return
    with gzip.open(p, "rt", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    imports = re.findall(r'from\s*["\'](\./[^"\']+)["\']', content)
    dyn_imports = re.findall(r'import\(["\'](\./[^"\']+)["\']\)', content)
    return imports + dyn_imports

print("CXUXv-e4:", check_file("index-CXUXv-e4.js.gz"))
print("ESh8tgBq:", check_file("index-ESh8tgBq.js.gz"))
print("1YOMGISy:", check_file("index-1YOMGISy.js.gz"))
