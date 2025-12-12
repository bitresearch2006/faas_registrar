README — Tunnel Signer + Dynamic Reverse-Tunnel Router

This system provides:

Token-based SSH certificate signing for remote WSL instances

Automatic reverse tunneling from each WSL to the VM

Dynamic per-user Nginx routing based on username → local port mapping

Secure isolation of each user's traffic via dedicated ports

Automatic add/remove of user routes and per-user config files

Full audit and revocation capability

The system makes it possible for each WSL user to expose a local service (ex: chatbot at port 8080) via:

https://bitone.in/<username>


The VM accepts reverse tunnels, signs short-lived certs, and routes each user's prefix to the correct backend port.

🔥 System Architecture Overview
8
1. WSL Client

Connects to the VM via SSH reverse tunneling:

ssh -N -R 127.0.0.1:<assigned_port>:localhost:8080 user@bitone.in


Before connecting, it requests a signed SSH certificate from the VM using its token.

2. VM / Server Components

SSH Certificate Authority installed under /etc/ssh/ca/

sign_service.py (Flask API) signs SSH user certificates

Per-user port allocator dynamically assigns an available port

Per-user nginx config generator creates one file per user under:

/etc/nginx/conf.d/users/<username>.conf


When routing is regenerated → Nginx reloads safely

3. Domain Routing
https://bitone.in/alice  →  127.0.0.1:9001 → Alice’s WSL:8080
https://bitone.in/bob    →  127.0.0.1:9002 → Bob’s WSL:8080

📁 Directory Layout (VM)
Path	Purpose
/etc/tunnel/tunnel_tokens.json	Token store
/etc/tunnel/user_ports.json	Username → port mapping
/etc/nginx/conf.d/users/	Per-user nginx route files
/usr/local/sbin/	Admin scripts (add/revoke/remove/alloc)
/usr/local/bin/	sign_service, regen scripts
/etc/systemd/system/sign_service.service	Systemd unit
/etc/ssh/ca/	SSH Certificate Authority
📜 Script Explanations

Below is a complete explanation of each script installed by the system.

1. vm_create_ca.sh

Creates an SSH Certificate Authority.

What it does:

Creates CA keypair in /etc/ssh/ca/ssh_ca

Adds TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys.pem to sshd

Enables TCP forwarding (AllowTcpForwarding yes)

Restarts sshd

When you call it:

Normally only once — automatically run during setup.

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

Example usage:
sudo add_token.sh "alice" "bitresearch" 3600


Output includes:

Generated token

Assigned port

4. alloc_user_port.sh

Allocates a free port for a new user.

Inputs:
alloc_user_port.sh <username>

Stores result in:
/etc/tunnel/user_ports.json

Returns:

The assigned port (ex: 9003)

5. regen_nginx_routes.sh

Creates per-user nginx files from user_ports.json.

Generates:
/etc/nginx/conf.d/users/alice.conf
/etc/nginx/conf.d/users/bob.conf
…

Each file looks like:
location ^~ /alice {
    proxy_pass http://127.0.0.1:9001$request_uri;
}

Also does:

Removes stale users

Runs nginx -t

Reloads nginx safely

How to run manually:
sudo regen_nginx_routes.sh

6. remove_user_port.sh

Removes a user’s assigned port and per-user nginx file.

Usage:
sudo remove_user_port.sh alice

It does:

Removes from /etc/tunnel/user_ports.json

Deletes /etc/nginx/conf.d/users/alice.conf

Calls regen_nginx_routes.sh

7. revoke_token.sh

Deactivates a token and removes the user's routing.

Workflow:

Marks token as inactive (active=false)

Extracts username from token store

Calls remove_user_port.sh <username>

nginx config regenerates → route disappears

Usage:
sudo revoke_token.sh <token>

8. tunnel_signer.conf

Nginx snippet providing:

/sign-cert → sign_service.py


Placed at:

/etc/nginx/conf.d/tunnel_signer.conf

⚙️ Setup Procedure (Full System Installation)

Upload all scripts to a folder on the VM

Run:

sudo bash setup_tunnel_signer.sh


Installer performs:

Sets up CA

Installs sign_service + systemd

Creates token storage

Creates port mapping file

Installs admin tools

Prepares nginx per-user directory

Reloads nginx safely

🚀 Operational Workflow
Add a new WSL user
sudo add_token.sh "alice" "bitresearch" 3600


Installer will:

Generate token

Assign port (ex: 9001)

Create /etc/nginx/conf.d/users/alice.conf

Reload nginx

User gets:

Token

Assigned port

Instructions for reverse tunnel

WSL reverse tunnel connection

WSL runs:

ssh -N -R 127.0.0.1:<port>:localhost:8080 bitresearch@bitone.in


Then their live service becomes available at:

https://bitone.in/alice

Revoke a user
sudo revoke_token.sh <token>


Automatically:

Disables token

Removes per-user nginx file

Removes port mapping

Regenerates nginx routing

Route disappears immediately.

🧨 Impact on the System

This system modifies several core subsystems—here is everything it touches.

1. SSHD (server)

Changes applied:

Enables SSH CA authentication

Allows TCP forwarding

Trusted CA file added:

/etc/ssh/trusted_user_ca_keys.pem


Impact:

Does not affect normal SSH password or key logins

Allows signed certs from WSL

2. Nginx

Modifications:

Adds snippet:

/etc/nginx/conf.d/tunnel_signer.conf


Creates dynamic per-user files under:

/etc/nginx/conf.d/users/


On user add/remove, nginx reloads automatically

Impact:

Only per-user routes are updated

Does not modify other virtual hosts

Safe reload (tested via nginx -t)

3. Systemd

Adds service:

sign_service.service


Impact:

Runs a lightweight Flask app

Auto-starts on boot

4. /etc/tunnel directory

Stores:

Token store

User-to-port mapping

Impact:

Only these scripts modify this

Root access only

⚠️ Safety Considerations

All edits are atomic (write to .tmp, then rename).

Nginx reload only occurs if configuration test passes.

Ports are bound only to 127.0.0.1 → not accessible externally.

SSH CA key is stored at /etc/ssh/ca/ssh_ca (permissions locked).

revocation cleans up routing to avoid ghost routes.

🎯 Conclusion

This system provides:

Secure WSL → Cloud VM routing

Automatic port allocation

Per-user SSL-protected URLs

Strong token-based authentication

Clean add/remove with per-user config files