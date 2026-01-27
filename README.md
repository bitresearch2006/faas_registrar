# Tunnel Signer + Dynamic Reverse-Tunnel Router

This system provides automated, secure exposure of local services running on **WSL clients** to the public internet via a **central VM** using SSH reverse tunnels and dynamic Nginx routing.

The design follows a **token-based authentication model** with short-lived SSH certificates and strict per-user isolation.

---

## Features

* Token-based SSH certificate signing
* Automatic reverse tunnel from each WSL to the VM
* Dynamic per-user port allocation
* Automatic Nginx route generation
* Per-user subdomain routing
* Full audit and revocation support
* Safe reload and atomic configuration updates

Each user can expose a local service (for example, a chatbot at port `8080`) as:

```
https://<username>.bitone.in
```

---

## System Architecture

### 1. WSL Client

The WSL client establishes a reverse SSH tunnel to the VM:

```bash
ssh -N -R 127.0.0.1:<assigned_port>:localhost:8080 user@bitone.in
```

Before connecting:

* The client requests a signed SSH certificate
* Authentication is done using a token
* Certificate is short-lived (TTL enforced)

---

### 2. VM / Server Components

The VM provides:

* SSH Certificate Authority
* Token verification service
* Dynamic port allocator
* Per-user Nginx config generator

Core components:

| Component | Purpose |
|----------|--------|
| `/etc/ssh/ca/` | SSH Certificate Authority |
| `sign_service.py` | Flask API for cert signing |
| `user_ports.json` | Username → port mapping |
| `tunnel_tokens.json` | Token store |
| `regen_nginx_routes.sh` | Nginx config generator |

---

### 3. Domain Routing

Each user gets a dedicated subdomain:

```
https://alice.bitone.in  →  127.0.0.1:9001 → Alice WSL:8080
https://bob.bitone.in    →  127.0.0.1:9002 → Bob WSL:8080
```

Traffic never leaves localhost on the VM.

---

## Directory Layout (VM)

| Path | Purpose |
|------|--------|
| `/etc/tunnel/tunnel_tokens.json` | Token store |
| `/etc/tunnel/user_ports.json` | Username → port mapping |
| `/etc/nginx/conf.d/users/` | Per-user vhosts |
| `/usr/local/sbin/` | Admin scripts |
| `/usr/local/bin/` | Runtime services |
| `/etc/systemd/system/` | Systemd units |
| `/etc/ssh/ca/` | SSH CA keys |

---

## Script Overview

### vm_create_ca.sh

Creates the SSH Certificate Authority.

Actions:

* Generates CA keypair
* Configures `TrustedUserCAKeys`
* Enables TCP forwarding
* Restarts `sshd`

Run once during initial setup.

---

### sign_service.py

Flask API for signing SSH user certificates.

Workflow:

* Client submits public key + token
* VM validates token
* Certificate is signed with CA
* `.pub-cert` file returned

Endpoint:

```
POST /sign-cert
```

Controlled by:

```bash
systemctl restart sign_service.service
systemctl status sign_service.service
```

---

### add_token.sh

Creates a new user token and assigns a port.

```bash
sudo add_token.sh "alice" "bitresearch" 3600
```

Performs:

* Generates random token
* Stores metadata
* Allocates port (9001–9100)
* Generates Nginx config
* Reloads Nginx

---

### alloc_user_port.sh

Allocates a free port.

```bash
alloc_user_port.sh <username>
```

Stores mapping in:

```
/etc/tunnel/user_ports.json
```

---

### regen_nginx_routes.sh

Generates per-user Nginx server blocks.

Creates:

```
/etc/nginx/conf.d/users/<username>.conf
```

Each file maps:

```
server_name <user>.bitone.in;
→ proxy_pass http://127.0.0.1:<port>;
```

Also:

* Removes stale users
* Runs `nginx -t`
* Reloads Nginx safely

---

### remove_user_port.sh

Removes a user's routing.

```bash
sudo remove_user_port.sh alice
```

Actions:

* Deletes port mapping
* Removes Nginx config
* Regenerates routing

---

### revoke_token.sh

Revokes a user token.

```bash
sudo revoke_token.sh <token>
```

Actions:

* Marks token inactive
* Removes routing
* Cleans up configs

---

## Setup Procedure

Run on the VM:

```bash
sudo bash setup_tunnel_signer.sh
```

Installer performs:

* Creates SSH CA
* Installs sign service
* Initializes token store
* Prepares Nginx structure
* Installs admin tools
* Reloads Nginx

---

## Operational Workflow

### Add a User

```bash
sudo add_token.sh "alice" "bitresearch" 3600
```

User receives:

* Token
* Assigned port
* SSH command

WSL connects:

```bash
ssh -N -R 127.0.0.1:<port>:localhost:8080 bitresearch@bitone.in
```

Service becomes live at:

```
https://alice.bitone.in
```

---

### Revoke a User

```bash
sudo revoke_token.sh <token>
```

Automatically:

* Disables token
* Removes routing
* Reloads Nginx

---

## Token Inspection

Token store:

```
/etc/tunnel/tunnel_tokens.json
```

Examples:

```bash
jq . /etc/tunnel/tunnel_tokens.json
jq -r '.tokens | keys[]' /etc/tunnel/tunnel_tokens.json
jq -r '.tokens | to_entries[] | select(.value.active==true) | "\(.key) -> \(.value.name)"' \
  /etc/tunnel/tunnel_tokens.json
```

---

## DNS & TLS Requirements

### DNS

Wildcard record:

```
*.bitone.in → <VM_PUBLIC_IP>
```

### TLS

Certificate must cover:

```
bitone.in
*.bitone.in
```

---

## Uninstall

```bash
sudo /usr/local/sbin/uninstall_tunnel_signer.sh
```

Removes:

* sign_service
* Nginx configs
* Tokens and ports
* SSH CA (optional)

---

## System Impact

This system modifies:

### SSHD

* Enables CA authentication
* Allows TCP forwarding

### Nginx

* Dynamic per-user vhosts
* Safe reload on change

### Systemd

* Runs signing service

---

## Safety Guarantees

* All file writes are atomic
* Nginx reload only on valid config
* Ports bound to `127.0.0.1`
* SSH CA permissions locked
* Revocation removes access immediately

---

## Conclusion

This system provides:

* Secure WSL → VM tunneling
* Per-user isolation
* Automatic routing
* Token-based authentication
* Zero manual Nginx management

Designed for multi-user remote service exposure with strong operational safety.

