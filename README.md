# Ansible-Rathole-WebGuard 🚀

This repository contains Ansible playbooks to deploy and manage a robust and secure web stack, featuring:

- **Rathole**: A lightweight and secure reverse proxy for exposing local services. 🛡️
- **CrowdSec**: A free, open-source, and participative IPS/IDS that detects and blocks malicious IPs. 🚫
- **Caddy**: A powerful, auto-HTTPS web server seamlessly integrating with CrowdSec and Cloudflare for DNS challenges. 🌐
- **Go & xcaddy**: Essential prerequisites for building Caddy with custom modules. 🛠️

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Directory Structure](#3-directory-structure)
4. [Configuration](#4-configuration)
   - [Inventory (`inventory.ini`)](#inventory-inventoryini)
   - [Group Variables (`group_vars/`)](#group-variables-group_vars)
   - [Host Variables (`host_vars/`)](#host-variables-host_vars)
   - [Role Variables (`roles/*/vars/main.yml`)](#role-variables-rolesvarsmainyml)
   - [Templates (`roles/*/templates/`)](#templates-roles-templates)
   - [Ansible Vault](#ansible-vault)
5. [Deployment](#5-deployment)
6. [Maintenance](#6-maintenance)
   - [Updating Software Versions](#updating-software-versions)
   - [Modifying Configurations](#modifying-configurations)
   - [Adding/Removing Hosts](#addingremoving-hosts)
   - [Checking Service Status](#checking-service-status)
   - [Troubleshooting](#troubleshooting)
7. [Contribution](#7-contribution)
8. [License](#8-license)

---

## 1\. Overview

This Ansible setup fully automates the deployment and management of Rathole, CrowdSec, and Caddy on your target servers. It handles:

- Initial system preparation, including package cache updates and essential utility installations. ⚙️
- Installation of Go and xcaddy.
- Building and configuring Caddy with integrated CrowdSec and Cloudflare DNS modules.
- Installing and setting up CrowdSec, including bouncer registration and AppSec configuration.
- Installing and configuring Rathole, which can operate in both server and client modes.
- Setting up and managing Systemd services for all components. 🚀

---

## 2\. Prerequisites

Before you start, make sure you have:

- **Ansible**: Installed on your **control node** (the machine running Ansible). 💻
- **SSH Access**: Configured for your **target servers**, ideally using SSH keys. 🔑
- **Target Servers**: Running a Debian/Ubuntu-based Linux distribution. 🐧
- **Internet Connectivity**: On your target servers to download packages and binaries. 🔗

---

## 3\. Directory Structure

The project uses a standard Ansible role-based directory structure for modularity:

```BASH
/ansible-rathole-webguard/
├── inventory.ini             # Defines target servers and groups
├── site.yml                  # Main playbook orchestrating all roles
├── group_vars/               # Variables for host groups (e.g., all.yml)
│   └── all.yml
├── host_vars/                # Variables specific to individual hosts
│   ├── client.example.yml
│   └── server.example.yml
└── roles/
    ├── caddy/                # Role for Caddy web server 🌐
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    ├── crowdsec/             # Role for CrowdSec IPS/IDS 🚫
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    ├── go_lang/              # Role for Go programming language installation 🛠️
    │   ├── tasks/
    │   └── vars/
    ├── rathole/              # Role for Rathole reverse proxy 🛡️
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    └── xcaddy/               # Role for xcaddy (Caddy custom builder) 🚀
        ├── tasks/
        └── vars/
```

---

## 4\. Configuration

All configuration is managed through Ansible variables and templates, ensuring flexibility and dynamic deployment.

### Inventory (`inventory.ini`)

This file simply lists your target servers and their group memberships. It's for host definitions, not variable assignments.

**Example `inventory.ini`:**

```ini
[webservers]
client.example ansible_host=127.0.0.1 ansible_port=22 ansible_user=ssh_user ansible_ssh_private_key_file=~/.ssh/id_ed25519
server.example ansible_host=127.0.0.1 ansible_port=22 ansible_user=ssh_user ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

### Group Variables (`group_vars/`)

This directory holds YAML files defining variables that apply to specific **groups of hosts**. For example, `group_vars/all.yml` contains variables that apply to _all_ hosts in your inventory.

### Host Variables (`host_vars/`)

Here, you'll find variables **specific to individual hosts**. Each file must be named after a host in your `inventory.ini` (e.g., `server.example.yml`). This is the ideal place for:

- **Connection details**: If `ansible_user` or `ansible_ssh_private_key_file` vary per server.
- **Application-specific settings**: Like a Caddy domain (`caddy_domain`), backend details (`caddy_backend_ip`, `caddy_backend_port`), or whether Rathole acts as a server or client (`rathole_role`).
- **Host-specific secrets**: If an API token or password is only relevant to one server.

### Role Variables (`roles/*/vars/main.yml`)

Each role's `vars/main.yml` file contains **default** variables for that component (e.g., software versions, default installation paths, user/group names). These can be overridden by `group_vars/` or `host_vars/`.

- **`rathole/vars/main.yml`**: Rathole version, paths, user/group, and target-triple mapping used to download the correct release asset for your OS/architecture.
- **`go_lang/vars/main.yml`**: Go version and installation details.
- **`xcaddy/vars/main.yml`**: xcaddy version, installation path, and architecture mapping for the correct binary.
- **`caddy/vars/main.yml`**: Caddy version, paths, user/group, and the crucial **`caddy_plugins`** list for custom builds.
- **`crowdsec/vars/main.yml`**: CrowdSec version, installation script URL, API/AppSec configuration (IPs, ports, ticker interval), and bouncer settings.

### Templates (`roles/*/templates/`)

Templates are Jinja2 files that dynamically generate configuration files on the target servers. They use variables from `group_vars/` and `host_vars/` to create host-specific configurations.

- **`caddy/templates/Caddyfile.j2`**: Your primary Caddy configuration. This is where you define domains, proxy settings, CrowdSec integration, and Cloudflare DNS challenge.
- **`caddy/templates/caddy.service.j2`**: The Systemd unit file for Caddy.
- **`rathole/templates/rathole.toml.j2`**: Rathole's configuration file, dynamically generated based on `rathole_role` and specific server/client configurations.

### Global toggles and useful variables

- `enable_cloudflare` (bool, default false): Adds the Cloudflare DNS plugin to Caddy builds. If enabled, set `caddy_cloudflare_api_token` with a Cloudflare API token (store it in Vault). The Caddy systemd unit injects it as `CLOUDFLARE_API_TOKEN`.
- `enable_crowdsec` (bool, default true): Installs and configures CrowdSec and related Caddy bouncer modules.
- `cleanup_temp` (bool, default false): Performs optional cleanup of temporary files at the end of the play.
- CrowdSec extras (all optional; guarded to avoid undefined-variable failures):
  - `ntfy_enabled`
  - `duration_expr`
  - `dynamic_whitelist_enabled`
  - `crowdsec_api_key` (required if registering the Caddy bouncer)

### Caddy plugins and rebuild behavior

- The Caddy role compiles Caddy with a combined plugin list based on `caddy_plugins` plus flags like `enable_cloudflare` and `enable_crowdsec`.
- A hash of the effective plugin list is persisted. Caddy is rebuilt when either the version changes or the plugin list changes, ensuring consistent binaries across runs.

### Rathole downloads and checksums

- The Rathole role downloads zipped release assets based on a target-triple mapping derived from `ansible_system` and `ansible_architecture` (e.g., `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-musl`). Common Linux targets and macOS (Darwin) are supported; `amd64` is aliased to `x86_64`.
- Optional checksum verification is supported. Define a map of filenames to SHA-256 sums, for example:

  ```yaml
  # group_vars/all.yml or host_vars/<host>.yml
  rathole_checksums:
    "rathole-x86_64-unknown-linux-gnu.zip": "9f6b4b333e4a8577aaddc297b0c00feffd4c1cdc6f92c03622734defb84c5868"
    "rathole-aarch64-unknown-linux-musl.zip": "219226a2cf32a0a74735bcb4b315b7f087fa8a3fb448509ff77fad2d8415bd4b"
  ```

  When provided, downloads are verified automatically.

### Rolling updates

- The main play uses `serial: 1` to roll out changes one host at a time, minimizing downtime during upgrades and reboots.

### Ansible Vault

**It's highly recommended to use Ansible Vault for sensitive data** like Cloudflare API tokens (`cloudflare_api_token`), CrowdSec API keys (`crowdsec_api_key`), or SSH private key passphrases.

1. **Create a vault file**: You can use a single vault file (e.g., `group_vars/all/vault.yml`) or host-specific vault files if secrets vary per host.

   ```bash
   ansible-vault create group_vars/all/vault.yml
   ```

2. **Add your sensitive variables inside**:

   ```yaml
   vault_crowdsec_api_key: "YOUR_CROWDSEC_API_KEY"
   vault_crowdsec_enrollment_key: "YOUR_CROWDSEC_ENROLLMENT_KEY"
   vault_cloudflare_api_token_server: "YOUR_CLOUDFLARE_TOKEN"
   # Optionally map to the Caddy role variable expected by the systemd unit
   caddy_cloudflare_api_token: "{{ vault_cloudflare_api_token_server }}"
   ```

3. **Remember your vault password\!** 🔑

---

## 5\. Deployment

To deploy the stack on your target servers:

1. Navigate to your `~/ansible/` directory.

2. Run the main playbook:

   ```bash
   ansible-playbook -i inventory.ini site.yml --ask-vault-pass
   ```

   (Omit `--ask-vault-pass` if you're not using Ansible Vault.)

Ansible will connect to your servers, perform initial system updates and common package installations, then proceed with installing and configuring the relevant software (Rathole, and conditionally Caddy/CrowdSec/Go/xcaddy), setting up all services automatically. ✨

---

## 6\. Maintenance

### Updating Software Versions

To update Rathole, Go, xcaddy, CrowdSec, or Caddy:

1. **Edit the corresponding `vars/main.yml` file** for the role you want to update (e.g., `roles/caddy/vars/main.yml` for Caddy).

2. Change the `_version` variable to the desired new version number.

3. Re-run the main playbook:

   ```bash
   ansible-playbook -i inventory.ini site.yml --ask-vault-pass
   ```

   Ansible's idempotency ensures only necessary steps are performed (e.g., downloading and reinstalling the new version, restarting affected services). 🔄

### Modifying Configurations

To change a configuration (e.g., Caddyfile, Rathole config):

1. **Edit the relevant Jinja2 template** in `roles/*/templates/`.

2. If the change affects variables, update the appropriate `group_vars/` or `host_vars/` file.

3. Re-run the main playbook:

   ```bash
   ansible-playbook -i inventory.ini site.yml --ask-vault-pass
   ```

   Ansible detects template changes and restarts affected services (e.g., Caddy service will restart if `Caddyfile.j2` changes). 📝

### Adding/Removing Hosts

- **Adding hosts**: Add the new server's hostname to `inventory.ini` under the appropriate group (e.g., `[webservers]`). Then, create a corresponding YAML file in `host_vars/` (e.g., `host_vars/new_server.yml`) with its specific variables. Re-run the playbook to provision it.
- **Removing hosts**: Simply remove the host from `inventory.ini`. For full de-provisioning (uninstalling services and cleaning up), you'd typically create a separate Ansible playbook.

### Checking Service Status

After deployment or during maintenance, you can check the status of services on your target servers via SSH:

- **Rathole**: `sudo systemctl status rathole`
- **CrowdSec**:
  - `sudo systemctl status crowdsec`
  - `sudo cscli metrics` (to see CrowdSec statistics) 📊
  - `sudo cscli bouncers list` (to verify Caddy bouncer registration)
- **Caddy**:
  - `sudo systemctl status caddy`
  - `sudo journalctl -u caddy -f` (to view Caddy logs in real-time) 👁️
  - `caddy version` (to check Caddy version and compiled modules)
- **Go**: `go version`
- **xcaddy**: `xcaddy version`

### Troubleshooting 🩺

- **Playbook Failures**: Review the Ansible output for specific error messages. Common issues include SSH connection problems (check `ansible_user`, `ansible_ssh_private_key_file`), incorrect variable values, or syntax errors in templates.
- **Service Not Starting**: Check the service logs using `sudo journalctl -u <service_name> -f` for detailed error messages (e.g., `journalctl -u caddy -f`).
- **Permission Issues**: Ensure the Caddy user (`caddy`), Rathole user (`rathole`), and their respective groups have appropriate permissions to directories and files.
- **Network/Firewall**: Verify that firewalls (on the server or network) aren't blocking necessary ports (e.g., 80, 443 for Caddy, Rathole's configured ports). 🚧

---

## 7\. Contribution

Feel free to open issues or submit pull requests if you have suggestions for improvements or bug fixes. Your contributions are welcome\! 🤝

---

## 8\. License

This project is open-source and available under the **MIT License**. 📝
