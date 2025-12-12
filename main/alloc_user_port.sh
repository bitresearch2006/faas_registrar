#!/usr/bin/env bash
set -euo pipefail

MAPPING="/etc/tunnel/user_ports.json"
USERNAME="$1"   # required
if [ -z "$USERNAME" ]; then echo "Usage: $0 <username>"; exit 2; fi

# lock file to avoid races
LOCK="/var/lock/alloc_user_port.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "Another alloc in progress"; exit 3; }

python3 - "$USERNAME" "$MAPPING" <<'PY'
import json,sys,os
username=sys.argv[1]
mapping_file=sys.argv[2]
with open(mapping_file,'r') as f:
    data=json.load(f)
users=data.setdefault("users",{})
pr=data.setdefault("port_range",{"min":9001,"max":9100})
mn=pr.get("min",9001); mx=pr.get("max",9100)
# if user already present, output existing
if username in users:
    print(users[username])
    sys.exit(0)
# find first free
used=set(int(p) for p in users.values())
port=None
for p in range(mn,mx+1):
    if p not in used:
        port=p; break
if port is None:
    print("NO_PORT_FREE",file=sys.stderr); sys.exit(4)
users[username]=port
with open(mapping_file+'.tmp','w') as f:
    json.dump(data,f,indent=2)
os.replace(mapping_file+'.tmp',mapping_file)
print(port)
PY
