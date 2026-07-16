# Ansible-Rathole-WebGuard

[![Lint Ansible](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml/badge.svg)](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml)

Deploy a complete, hardened web infrastructure with one command. This Ansible playbook sets up **Caddy** (auto-HTTPS), **CrowdSec** (IPS/IDS), **Rathole** (reverse tunnel), and optional **Coraza WAF** (lightweight ruleset) + **Cloudflare** on Debian/Ubuntu servers.

```
ansible-playbook -i inventory.ini site.yml
```

---

## Quickstart

### 1. Clone and configure inventory

```bash
git clone https://github.com/chrisvgt/ansible-rathole-webguard.git
cd ansible-rathole-webguard
cp inventory.example.ini inventory.ini
```

Create `inventory.ini` with your server IPs:

```ini
[webservers]
server ansible_host=203.0.113.10 ansible_user=ubuntu
client ansible_host=203.0.113.20 ansible_user=ubuntu
```

### 2. Configure your server

```bash
cp host_vars/server.example.yml host_vars/server.yml
```

Edit `host_vars/server.yml` — the essentials:

```yaml
rathole_role: "server"

# Wildcard domains this server handles (see server.example.yml for full options)
wildcard_sites:
  - domain: "*.example.com"
    sites:
      - name: jellyfin
        subdomain: "watch"
        port: 8096
```

### 3. Configure your client (optional)

```bash
cp host_vars/client.example.yml host_vars/client.yml
```

Edit `host_vars/client.yml`:

```yaml
rathole_role: "client"
rathole_client_config:
  remote_addr: "203.0.113.10:62917"
  services:
    - name: "jellyfin"
      local_addr: "192.168.1.10:8096"
```

### 4. Deploy

```bash
# With Ansible Vault (recommended for secrets)
ansible-playbook -i inventory.ini site.yml --ask-vault-pass

# Without Vault
ansible-playbook -i inventory.ini site.yml
```

> 💡 **Tip:** Use the helper script: `./scripts/run-playbook.sh`

---

## What's Included

### Core (enabled by default)

| Component    | What it does                                                     |
| ------------ | ---------------------------------------------------------------- |
| **Rathole**  | Secure reverse tunnel — exposes local services through a server  |
| **Caddy**    | Auto-HTTPS web server with CrowdSec bouncer and rate limiting    |
| **CrowdSec** | Intrusion detection, IP banning, AppSec attack surface reduction |

### Extensions (opt-in via feature flags)

| Extension            | What it adds                           | Enable with                 |
| -------------------- | -------------------------------------- | --------------------------- |
| **Cloudflare**       | DNS-01 ACME challenges via Cloudflare  | `enable_cloudflare`         |
| **Blocklist Import** | 28+ threat feeds auto-imported         | `enable_crowdsec_import`    |
| **Coraza WAF**       | Web Application Firewall (lightweight) | `enable_coraza_waf`         |
| **Ntfy**             | Push notifications on blocked IPs      | `ntfy_enabled`              |
| **DDNS Whitelist**   | Auto-whitelist dynamic DNS hosts       | `dynamic_whitelist_enabled` |

---

## Architecture

```
                      Internet
                         │
                    ┌────▼────┐
                    │  Caddy  │  (TLS termination, CrowdSec bouncer, WAF)
                    │ :443    │
                    └────┬────┘
                         │ proxy_pass localhost:N
              ┌──────────┼──────────┐
              │          │          │
         ┌────▼────┐ ┌──▼───┐ ┌───▼───┐
         │ Jellyfin│ │Nextcl│ │...    │  (local services)
         │ :8096   │ │:11000│ │       │
         └─────────┘ └──────┘ └───────┘

  Rathole server ◄──── Rathole tunnel ──── Rathole client
  (VPS / public)                           (home LAN)
```

---

## Configuration

### Feature flags (in `group_vars/all.yml`)

| Variable                 | Default       | Description                                        |
| ------------------------ | ------------- | -------------------------------------------------- |
| `enable_crowdsec`        | `true`        | CrowdSec IPS/IDS with Caddy bouncer                |
| `enable_cloudflare`      | `false`       | Cloudflare DNS-01 ACME plugin                      |
| `enable_wildcard`        | `false`       | Wildcard domain support                            |
| `enable_crowdsec_import` | `false`       | Auto-import 28+ threat blocklists                  |
| `enable_coraza_waf`      | `false`       | Coraza WAF global toggle                           |
| `enable_rate_limit`      | `true`        | Per-service rate limiting                          |
| `coraza_mode_default`    | `recommended` | Default WAF mode when site doesn't specify its own |

### Host variables (`host_vars/`)

Per-server settings. Start from the example files:

- **Server**: `cp host_vars/server.example.yml host_vars/server.yml`
- **Client**: `cp host_vars/client.example.yml host_vars/client.yml`

#### Server essentials

```yaml
rathole_role: "server"

# CrowdSec API key (generate with: head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
crowdsec_api_key: "{{ vault_crowdsec_api_key }}"

# Cloudflare API token (optional)
cloudflare_api_token: "{{ vault_cloudflare_api_token }}"

# Rathole tunnel definition
rathole_server_config:
  listen_addr: "0.0.0.0:62917"
  transport:
    type: "noise"
    noise:
      local_private_key: "your_base64_private_key"

# Wildcard site definitions
wildcard_sites:
  - domain: "*.example.com"
    sites:
      - name: jellyfin
        subdomain: "jellyfin" # jellyfin.example.com
        port: 8096
```

#### Client essentials

```yaml
rathole_role: "client"
rathole_client_config:
  remote_addr: "203.0.113.10:62917"
  transport:
    type: "noise"
    noise:
      remote_public_key: "server_public_key_base64"
  services:
    - name: "jellyfin"
      local_addr: "192.168.1.10:8096"
```

### Security: Ansible Vault

Store secrets (API keys, passwords) outside your config files:

```bash
ansible-vault create group_vars/all/vault.yml
```

```yaml
vault_crowdsec_api_key: "your-api-key"
vault_cloudflare_api_token_server: "your-token"
vault_crowdsec_machine_password: "your-password"
```

---

## Coraza WAF: Per-Site Control

The WAF is a **custom lightweight ruleset** (not the full OWASP CRS) for efficient CPU usage. Each site can independently choose its protection level:

| Variable                     | Effect                                                           |
| ---------------------------- | ---------------------------------------------------------------- |
| `coraza_mode: "off"`         | WAF **disabled** for this site                                   |
| `coraza_mode: "minimal"`     | WAF enabled — method enforcement, file upload blocking           |
| `coraza_mode: "recommended"` | WAF enabled — null bytes, SQLi, XSS, path traversal              |
| `coraza_mode: "moderate"`    | WAF enabled — + command injection, RFI, Content-Type check       |
| `coraza_mode: "strict"`      | WAF enabled — + SSTI, aggressive SQLi/XSS/CMD rules              |
| _not set_                    | Falls back to global `enable_coraza_waf` + `coraza_mode_default` |

Set globally in `group_vars/all.yml`:

```yaml
enable_coraza_waf: false # Global default: WAF off for all sites
coraza_mode_default: "recommended"
```

### WAF Rule Coverage by Mode

| Threat                      | `minimal` | `recommended` | `moderate` | `strict`      |
| --------------------------- | --------- | ------------- | ---------- | ------------- |
| HTTP Method enforcement     | ✅        | ✅            | ✅         | ✅            |
| File upload blocking        | ✅ opt    | —             | —          | —             |
| Null bytes / control chars  | —         | ✅            | ✅         | ✅            |
| SQL Injection               | —         | ✅ basic      | ✅         | ✅ aggressive |
| XSS                         | —         | ✅ basic      | ✅         | ✅ aggressive |
| Path Traversal              | —         | ✅            | ✅         | ✅            |
| Command Injection           | —         | —             | ✅         | ✅ aggressive |
| Remote/Local File Inclusion | —         | —             | ✅         | ✅            |
| Content-Type enforcement    | —         | —             | ✅         | ✅            |
| Template Injection (SSTI)   | —         | —             | —          | ✅            |

> **Note:** The lightweight ruleset does NOT load the full OWASP CRS. This significantly reduces CPU and memory usage (measured: ~224MB RAM instead of ~1.4GB with CRS) while still blocking real attacks.

### Design Fixes

The Caddyfile template includes these security corrections:

| #   | Issue                                                         | Fix                                                        |
| --- | ------------------------------------------------------------- | ---------------------------------------------------------- |
| 1   | `{http.request.uuid}` is not a valid Caddy placeholder        | → `{http.request.id}` + global `request_id` directive      |
| 2   | Missing explicit order between rate_limit, coraza_waf, appsec | → `rate_limit → coraza_waf → appsec → reverse_proxy` chain |
| 3   | Forward path could match all routes if not configured         | → `site.forward_path is defined` guard added               |
| 4   | Static assets cache paths hardcoded for Jellyfin              | → `site.cache_paths` configurable per site                 |
| 5   | `SecDefaultAction` with wrong phase for phase:1 rules         | → Removed explicit phase from SecDefaultAction             |
| 6   | Request-ID header generator missing                           | → Global `request_id` directive enabled                    |

---

## CrowdSec Blocklist Sources (28+ feeds)

Automatically imported when `enable_crowdsec_import: true`:

| Source                 | Description                       |
| ---------------------- | --------------------------------- |
| IPsum                  | IPs seen on 3+ blocklists         |
| Spamhaus DROP          | Known hijacked netblocks          |
| Blocklist.de           | SSH/Apache/Mail attack sources    |
| Firehol level1/2       | Aggregated threat intelligence    |
| Abuse.ch Feodo/URLhaus | Botnet C2 and malware URLs        |
| Emerging Threats       | Compromised IPs                   |
| Binary Defense         | Known attacker IPs                |
| DShield                | Top attackers                     |
| CI Army                | Bad reputation networks           |
| Tor exit nodes         | (may cause false positives)       |
| +18 more...            | Scanner IPs, C2 trackers, botnets |

## Caddy Plugin System

Caddy is compiled with xcaddy to include only the plugins you need:

- **Always**: CrowdSec bouncer (HTTP + layer4 + AppSec), rate limiting
- **Conditional**: Cloudflare DNS, Coraza WAF — based on feature flags
- Plugin changes trigger an automatic rebuild (hash-tracked)

## Rathole Transport Options

| Transport   | Security             | Performance | Use case                    |
| ----------- | -------------------- | ----------- | --------------------------- |
| `noise`     | ✅ Strong encryption | ⚡ Fast     | **Recommended default**     |
| `tls`       | ✅ Certificate-based | 🐢 Slower   | When PKI is required        |
| `tcp`       | ❌ Plaintext         | ⚡ Fastest  | Internal/untrusted networks |
| `websocket` | ✅ TLS-wrapped       | 🐢 Slower   | Through strict firewalls    |

---

## Deployment

### First time

```bash
./scripts/run-playbook.sh
```

### Updating

```bash
# Update a software version in vars/main.yml, then:
ansible-playbook -i inventory.ini site.yml
```

### Maintenance commands

```bash
# Service status
ssh user@server sudo systemctl status rathole caddy crowdsec

# CrowdSec decisions
ssh user@server sudo cscli decisions list
ssh user@server sudo cscli decisions list --origin blocklist-import

# Logs
ssh user@server sudo journalctl -u caddy -f
ssh user@server sudo journalctl -u crowdsec-blocklist-import.service

# Check CrowdSec metrics
ssh user@server sudo cscli metrics
```

### Troubleshooting

| Problem                     | Check                                                      |
| --------------------------- | ---------------------------------------------------------- |
| Playbook fails              | `ansible_user`, SSH key path, variable values in host_vars |
| Service won't start         | `sudo journalctl -u <service> -n 50`                       |
| Caddy can't get certificate | DNS records point to server? Port 80/443 reachable?        |
| CrowdSec not banning        | `sudo cscli metrics`, `sudo cscli decisions list`          |
| Rathole tunnel down         | Client can reach server:port? Tokens match?                |
| Permission errors           | Systemd unit user/group ownership                          |

---

## Directory Structure

```
ansible-rathole-webguard/
├── ansible.cfg                 # Ansible configuration
├── inventory.example.ini       # Example inventory
├── site.yml                    # Main playbook
├── group_vars/all.yml          # Global feature flags
├── host_vars/
│   ├── server.example.yml      # Server configuration template
│   ├── client.example.yml      # Client configuration template
│   └── .gitignore              # Ignores *.yml, keeps *.example.yml
├── roles/
│   ├── caddy/                  # Auto-HTTPS web server
│   ├── crowdsec/               # IPS/IDS + AppSec
│   ├── crowdsec_import/        # Threat feed importer
│   ├── go_lang/                # Go toolchain (for Caddy builds)
│   ├── python/                 # Python + pipx (for blocklist import)
│   ├── rathole/                # Reverse tunnel
│   └── xcaddy/                 # Caddy builder
└── scripts/
    └── run-playbook.sh         # Helper with vault support
```

---

## License

MIT — see [LICENSE](LICENSE)
