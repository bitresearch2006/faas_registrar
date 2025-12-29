Tunnel Signer + Dynamic Reverse-Tunnel Router

This system provides:

Token-based SSH certificate signing for remote WSL instances

Automatic reverse tunneling from each WSL to the VM

Dynamic per-user Nginx routing based on username → local port mapping

Secure isolation of each user's traffic via dedicated ports

Automatic add/remove of user routes and per-user config files

Full audit and revocation capability

Each user can expose a local service (for example, a chatbot at port 8080) as:

https://<username>.bitone.in

The VM accepts reverse tunnels, signs short-lived certs, and routes each user’s subdomain to the correct backend port.

🔥 System Architecture Overview
1. WSL Client

Connects to the VM via SSH reverse tunneling:

ssh -N -R 127.0.0.1:<assigned_port>:localhost:8080 user@bitone.in

Before connecting, it requests a signed SSH certificate from the VM using its token.

2. VM / Server Components

SSH Certificate Authority under /etc/ssh/ca/

sign_service.py (Flask API) signs SSH user certificates

Per-user port allocator dynamically assigns an available port

Per-user nginx config generator creates one file per user under:

/etc/nginx/conf.d/users/<username>.conf

When routing is regenerated → Nginx reloads safely.

3. Domain Routing (Subdomain Mode)
https://alice.bitone.in  →  127.0.0.1:9001 → Alice’s WSL:8080
https://bob.bitone.in    →  127.0.0.1:9002 → Bob’s WSL:8080
📁 Directory Layout (VM)
Path	Purpose
/etc/tunnel/tunnel_tokens.json	Token store
/etc/tunnel/user_ports.json	Username → port mapping
/etc/nginx/conf.d/users/	Per-user nginx vhost files
/usr/local/sbin/	Admin scripts (add/revoke/remove/alloc)
/usr/local/bin/	sign_service.py, regen_nginx_routes.sh
/etc/systemd/system/sign_service.service	Systemd unit
/etc/ssh/ca/	SSH Certificate Authority
📜 Script Explanations
1. vm_create_ca.sh

Creates an SSH Certificate Authority.

What it does:

Creates CA keypair in /etc/ssh/ca/ssh_ca

Adds TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys.pem to sshd

Enables TCP forwarding (AllowTcpForwarding yes)

Restarts sshd

Normally run once — automatically during setup.

2. sign_service.py

A Flask API service that signs short-lived SSH certificates for WSL clients.

Purpose:

Clients send public key + token

VM verifies token and TTL

Signs the key with CA

Returns a .pub-cert file usable for SSH login

Endpoint:

POST /sign-cert

Controlled by systemd:

systemctl restart sign_service.service
systemctl status sign_service.service
3. add_token.sh

Adds a new user token and auto-assigns a port.

Workflow:

Creates a random token

Saves token metadata to /etc/tunnel/tunnel_tokens.json

Calls alloc_user_port.sh → assigns unique port (9001–9100)

Calls regen_nginx_routes.sh → creates /etc/nginx/conf.d/users/<username>.conf

Example:

sudo add_token.sh "alice" "bitresearch" 3600

Output includes:

Generated token

Assigned port

4. alloc_user_port.sh

Allocates a free port for a new user.

Inputs:
alloc_user_port.sh <username>

Stores mapping in:

/etc/tunnel/user_ports.json
5. regen_nginx_routes.sh

Generates per-user nginx server blocks from user_ports.json.

Creates files like:

/etc/nginx/conf.d/users/alice.conf

Each file defines a server block mapping:

server_name alice.bitone.in;
→ proxy_pass http://127.0.0.1:<port>;

Also:

Removes stale users

Runs nginx -t

Reloads nginx safely

Run manually:

sudo regen_nginx_routes.sh
6. remove_user_port.sh

Removes a user’s assigned port and nginx config.

sudo remove_user_port.sh alice

It does:

Removes from /etc/tunnel/user_ports.json

Deletes /etc/nginx/conf.d/users/alice.conf

Calls regen_nginx_routes.sh

7. revoke_token.sh

Deactivates a token and removes the user's routing.

sudo revoke_token.sh <token>

It:

Sets active=false for the token

Extracts the username

Calls remove_user_port.sh <username>

Result: user route and port mapping are fully removed.

⚙️ Setup Procedure

Upload all scripts to a folder on the VM and run:

sudo bash setup_tunnel_signer.sh

Installer performs:

Sets up CA

Installs sign_service + systemd unit

Creates token storage

Creates port mapping file

Installs admin tools

Prepares nginx per-user directory

Reloads nginx safely

🚀 Operational Workflow
➕ Add a new user
sudo add_token.sh "alice" "bitresearch" 3600


Installer will:

Generate token

Assign port (ex: 9001)

Create /etc/nginx/conf.d/users/alice.conf

Reload nginx

User gets:

Token

Assigned port (for example 9001)

Instructions for reverse tunnel

WSL reverse tunnel connection

WSL runs:

ssh -N -R 127.0.0.1:<port>:localhost:8080 bitresearch@bitone.in

Service becomes live at:

https://alice.bitone.in
➖ Revoke a user
sudo revoke_token.sh <token>

Automatically:

Disables token

Removes port mapping

Deletes per-user nginx config

Regenerates nginx routing

🔍 Viewing Existing Tokens

Token store file:

/etc/tunnel/tunnel_tokens.json
Show all tokens (pretty):
jq . /etc/tunnel/tunnel_tokens.json
List only token values:
jq -r '.tokens | keys[]' /etc/tunnel/tunnel_tokens.json
List active tokens with usernames:
jq -r '.tokens | to_entries[] | select(.value.active==true) | "\(.key) -> \(.value.name)"' \
  /etc/tunnel/tunnel_tokens.json

Use any token value with:

sudo revoke_token.sh <token>
🌐 Subdomain Routing Requirements (Recent Change)

The system now exposes users via subdomains instead of path prefixes.

✅ DNS

Create a wildcard DNS record:

*.bitone.in  →  <VM_PUBLIC_IP>

(Cloudflare: A record, DNS only / grey cloud.)

✅ TLS Certificate

Your TLS certificate must cover:

bitone.in
*.bitone.in

If needed, reissue with Certbot using a wildcard certificate.

✅ Nginx

Per-user vhosts are generated automatically under:

/etc/nginx/conf.d/users/

TLS and proxy settings are centralized via snippets:

/etc/nginx/snippets/bitone_ssl.conf
/etc/nginx/snippets/bitone_proxy.conf

No manual nginx edits are required after setup.

🗑️ Uninstall

To completely remove the tunnel signer setup:

sudo /usr/local/sbin/uninstall_tunnel_signer.sh

This will:
- Stop and disable sign_service
- Remove installed scripts and nginx configs
- Remove token and port mappings
- Optionally remove SSH CA
- Remove nginx snippets

🧨 Impact on the System

This system modifies:

SSHD

Enables CA authentication

Allows TCP forwarding

Nginx

Uses dynamic per-user server blocks

Reloads safely on changes

Systemd

Runs sign_service.service on boot

/etc/tunnel

Stores tokens and port mappings

⚠️ Safety Considerations

All edits are atomic (write to .tmp, then rename)

Nginx reload only occurs if nginx -t passes

Ports are bound only to 127.0.0.1

SSH CA key permissions are locked down

Revocation cleans up routing immediately

🎯 Conclusion

This system provides:

Secure WSL → Cloud VM routing

Automatic port allocation

Per-user SSL-protected subdomains

Strong token-based authentication

Clean add/remove with per-user isolation