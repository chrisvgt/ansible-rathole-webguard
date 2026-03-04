# Ansible-Rathole-WebGuard

This repository contains Ansible playbooks to deploy and manage a robust and secure web stack, featuring:

- **Rathole**: A lightweight and secure reverse proxy for exposing local services.
- **CrowdSec**: A free, open-source IPS/IDS that detects and blocks malicious IPs.
- **Caddy**: A powerful, auto-HTTPS web server with CrowdSec and Cloudflare integration.
- **Coraza WAF**: Web Application Firewall for advanced request filtering.
- **Go & xcaddy**: Prerequisites for building Caddy with custom modules.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quickstart](#3-quickstart)
4. [Directory Structure](#4-directory-structure)
5. [Configuration](#5-configuration)
6. [Deployment](#6-deployment)
7. [Maintenance](#7-maintenance)
8. [Contribution](#8-contribution)
9. [License](#9-license)

---

## 1. Overview

This Ansible setup automates the deployment and management of Rathole, CrowdSec, Caddy, and Coraza WAF on target servers. It handles:

- System preparation (package updates, utility installation)
- Go and xcaddy installation
- Caddy builds with CrowdSec, Cloudflare, and Coraza WAF plugins
- CrowdSec installation and bouncer registration
- Rathole (server or client mode)
- Systemd service configuration

---

## 2. Prerequisites

Before you start:

- **Ansible**: 2.13+ on your control node
- **SSH Access**: Configured for target servers (SSH keys recommended)
- **Target Servers**: Debian/Ubuntu-based Linux
- **Internet Connectivity**: On target servers for package/binary downloads

---

## 3. Quickstart

Example `group_vars/all.yml`:

```yaml
enable_crowdsec: true
enable_cloudflare: false
enable_coraza_waf: false
cleanup_temp: false
```

Example `host_vars/server.example.yml`:

```yaml
ansible_host: 203.0.113.10
ansible_user: ubuntu
caddy_domain: example.com
rathole_role: server
```

---

## 4. Directory Structure

The project uses a standard Ansible role-based directory structure for modularity:

```
/ansible-rathole-webguard/
├── inventory.ini
├── site.yml
├── group_vars/
│   └── all.yml
├── host_vars/
│   ├── client.example.yml
│   └── server.example.yml
└── roles/
    ├── caddy/
    ├── crowdsec/
    ├── go_lang/
    ├── rathole/
    └── xcaddy/
```

---

## 5. Configuration

All configuration is managed through Ansible variables and templates, ensuring flexibility and dynamic deployment.

### Inventory (`inventory.ini`)

This file lists your target servers and their group memberships.

**Example `inventory.ini`:**

```ini
[webservers]
client.example ansible_host=127.0.0.1 ansible_port=22 ansible_user=ssh_user ansible_ssh_private_key_file=~/.ssh/id_ed25519
server.example ansible_host=127.0.0.1 ansible_port=22 ansible_user=ssh_user ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

### Group Variables (`group_vars/`)

This directory holds YAML files defining variables for specific host groups. `group_vars/all.yml` contains variables that apply to all hosts.

### Host Variables (`host_vars/`)

Variables specific to individual hosts. Each file is named after a host in `inventory.ini` (e.g., `server.example.yml`). Ideal for:

- Connection details (ansible_user, ansible_ssh_private_key_file)
- Application-specific settings (caddy_domain, rathole_role)
- Host-specific secrets (API tokens, passwords)

### Role Variables (`roles/*/vars/main.yml`)

Each role's `vars/main.yml` contains default variables that can be overridden by `group_vars/` or `host_vars/`:

- **`rathole/vars/main.yml`**: Rathole version, paths, user/group, target-triple mapping
- **`go_lang/vars/main.yml`**: Go version and installation details
- **`xcaddy/vars/main.yml`**: xcaddy version, installation path, architecture mapping
- **`caddy/vars/main.yml`**: Caddy version, paths, user/group, `caddy_plugins` list
- **`crowdsec/vars/main.yml`**: CrowdSec version, API/AppSec configuration, bouncer settings

### Templates (`roles/*/templates/`)

Jinja2 templates dynamically generate configuration files using variables from `group_vars/` and `host_vars/`:

- **`caddy/templates/Caddyfile.j2`**: Primary Caddy configuration
- **`caddy/templates/caddy.service.j2`**: Systemd unit file for Caddy
- **`rathole/templates/rathole.toml.j2`**: Rathole configuration

### Feature Flags

- `enable_cloudflare` (default: false): Adds Cloudflare DNS plugin to Caddy. Requires `cloudflare_api_token` in Vault.
- `enable_crowdsec` (default: true): Installs CrowdSec with Caddy bouncer modules.
- `enable_coraza_waf` (default: false): Adds Coraza WAF plugin to Caddy builds.
- `cleanup_temp` (default: false): Cleanup temporary files after deployment.

### Caddy Plugin Management

- Caddy is compiled with plugins from `caddy_plugins` plus conditional flags (`enable_cloudflare`, `enable_crowdsec`, `enable_coraza_waf`).
- Plugin list hash is persisted. Caddy rebuilds when version or plugin list changes.

### Rathole Downloads

- Rathole release assets are downloaded based on `ansible_system` and `ansible_architecture`.
- Optional checksum verification: define `rathole_checksums` map with SHA-256 sums.

```yaml
rathole_checksums:
  "rathole-x86_64-unknown-linux-gnu.zip": "9f6b4b333e4a8577aaddc297b0c00feffd4c1cdc6f92c03622734defb84c5868"
```

### Rolling Updates

For sequential deployments, set `serial` in the play:

```yaml
- hosts: webservers
  roles:
    - caddy
    - crowdsec
    - rathole
```

### Ansible Vault

Store sensitive data in Vault (API tokens, API keys, passphrases):

```bash
ansible-vault create group_vars/all/vault.yml
```

Example vault file:

```yaml
vault_crowdsec_api_key: "YOUR_KEY"
vault_crowdsec_enrollment_key: "YOUR_KEY"
vault_cloudflare_api_token_server: "YOUR_TOKEN"

# Map vault variables to role variables
cloudflare_api_token: "{{ vault_cloudflare_api_token_server }}"
```

---

## 6. Deployment

Run the main playbook from the repository root:

```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

Omit `--ask-vault-pass` if not using Vault.

**Helper script:**

```bash
chmod +x scripts/run-playbook.sh
./scripts/run-playbook.sh                    # with vault prompt
./scripts/run-playbook.sh --no-vault         # without vault
./scripts/run-playbook.sh --vault-file FILE  # with vault file
```

---

## 7. Maintenance

### Updating Software Versions

Edit the version in the role's `vars/main.yml`:

```bash
# Example: Update Caddy version
vi roles/caddy/vars/main.yml  # change caddy_version
```

Then re-run the playbook. Ansible will rebuild and restart only affected services.

### Modifying Configurations

Edit templates in `roles/*/templates/` and re-run the playbook. Ansible detects changes and restarts affected services:

```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

### Adding/Removing Hosts

- **Add**: Add hostname to `inventory.ini`, create `host_vars/<hostname>.yml`, then run the playbook.
- **Remove**: Remove hostname from `inventory.ini` (or create a separate de-provisioning playbook).

### Service Status

Check service status via SSH:

```bash
sudo systemctl status rathole
sudo systemctl status crowdsec
sudo systemctl status caddy
sudo cscli metrics
sudo cscli bouncers list
sudo journalctl -u caddy -f
caddy version
```

### Troubleshooting

- **Playbook Failures**: Check SSH access (`ansible_user`, `ansible_ssh_private_key_file`), variable values, and template syntax.
- **Service Errors**: Check logs with `sudo journalctl -u <service>`.
- **Permissions**: Verify user/group ownership of directories (caddy, rathole users).
- **Firewall**: Ensure ports are open (80, 443 for Caddy, Rathole's configured ports).

---

## 8. Contribution

Issues and pull requests welcome.

---

## 9. License

MIT License
