#!/usr/bin/env bash
set -euo pipefail
MAPPING="/etc/tunnel/user_ports.json"
USER="$1"
python3 - <<PY
import json,sys,os
mf="$MAPPING"
u="$USER"
data=json.load(open(mf))
users=data.get("users",{})
if u in users:
    del users[u]
    with open(mf+'.tmp','w') as f:
        json.dump(data,f,indent=2)
    os.replace(mf+'.tmp',mf)
    print("removed",u)
else:
    print("not found",u)
PY
# regen nginx
sudo /usr/local/bin/regen_nginx_routes.sh
