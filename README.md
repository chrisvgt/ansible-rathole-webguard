# Ansible-Rathole-WebGuard

This repository contains Ansible playbooks to deploy and manage a secure web stack featuring:

* **Rathole**: A lightweight and secure reverse proxy for exposing local services.
* **CrowdSec**: A free, open-source, and participative IPS/IDS for detecting and blocking malicious IPs.
* **Caddy**: A powerful, auto-HTTPS web server that integrates with CrowdSec and Cloudflare for DNS challenges.
* **Go & xcaddy**: Prerequisites for building Caddy with custom modules.

-----

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Directory Structure](#3-directory-structure)
4. [Configuration](#4-configuration)
    * [Inventory (`inventory.ini`)](#inventory-inventoryini)
    * [Group Variables (`group_vars/`)](#group-variables-group_vars)
    * [Host Variables (`host_vars/`)](#host-variables-host_vars)
    * [Role Variables (`roles/*/vars/main.yml`)](#role-variables-rolesvarsmainyml)
    * [Templates (`roles/*/templates/`)](#templates-roles-templates)
    * [Ansible Vault](#ansible-vault)
5. [Deployment](#5-deployment)
6. [Maintenance](#6-maintenance)
    * [Updating Software Versions](#updating-software-versions)
    * [Modifying Configurations](#modifying-configurations)
    * [Adding/Removing Hosts](#addingremoving-hosts)
    * [Checking Service Status](#checking-service-status)
    * [Troubleshooting](#troubleshooting)
7. [Contribution](#7-contribution)
8. [License](#8-license)

-----

## 1\. Overview

This Ansible setup automates the full lifecycle of the Rathole, CrowdSec, and Caddy services on your target servers. It handles:

* Initial system preparation, including updating package caches and installing essential utilities.
* Installation of Go and xcaddy.
* Building and configuring Caddy with CrowdSec and Cloudflare DNS modules.
* Installing and setting up CrowdSec, including bouncer registration.
* Installing and configuring Rathole, capable of acting as both server and client.
* Setting up Systemd services for all components.

-----

## 2\. Prerequisites

Before you begin, ensure you have:

* **Ansible**: Installed on your **control node** (the machine you're running Ansible from).
* **SSH Access**: Configured for your **target servers** (e.g., via SSH keys).
* **Target Servers**: Running a Debian/Ubuntu-based Linux distribution.
* **Internet Connectivity**: On your target servers for downloading packages and binaries.

-----

## 3\. Directory Structure

The project follows a standard Ansible role-based structure:

```
~/ansible/
├── inventory.ini             # Defines your target servers and groups
├── site.yml                  # Main playbook that orchestrates all roles
├── group_vars/               # Variables for host groups (e.g., all.yml)
│   └── all.yml
├── host_vars/                # Variables specific to individual hosts
│   ├── client.example.yml
│   └── server.example.yml
└── roles/
    ├── caddy/
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    ├── crowdsec/
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    ├── go_lang/
    │   ├── tasks/
    │   └── vars/
    ├── rathole/
    │   ├── handlers/
    │   ├── tasks/
    │   ├── templates/
    │   └── vars/
    └── xcaddy/
        ├── tasks/
        └── vars/
```

-----

## 4\. Configuration

All configuration is managed through Ansible files, leveraging its variable precedence and templating capabilities.

### Inventory (`inventory.ini`)

This file simply defines your target servers and their group memberships. It **doesn't** contain any variable definitions directly.

**Example `inventory.ini`:**

```ini
[web_servers]
client.example.com
server.example.com
```

### Group Variables (`group_vars/`)

This directory contains YAML files where you define variables that apply to specific **groups of hosts**. For instance, `group_vars/all.yml` holds variables that apply to *all* hosts in your inventory.

### Host Variables (`host_vars/`)

This is where you store variables that are **specific to individual hosts**. Each file in this directory must be named exactly after a host in your `inventory.ini` (e.g., `server.example.yml`). This is the ideal place for:

* **Connection details**: If `ansible_user` or `ansible_ssh_private_key_file` differ per server.
* **Application-specific settings**: Like a Caddy domain (`caddy_domain`), backend details (`caddy_backend_ip`, `caddy_backend_port`), or whether Rathole acts as a server or client (`rathole_role`).
* **Host-specific secrets**: If a particular API token or password is only relevant to one server.

### Role Variables (`roles/*/vars/main.yml`)

Each role's `vars/main.yml` file contains **default** variables specific to that component (e.g., software versions, default installation paths, user/group names). Variables defined here can be overridden by `group_vars/` or `host_vars/`.

* **`rathole/vars/main.yml`**: Rathole version, paths, user/group.
* **`go_lang/vars/main.yml`**: Go version and installation details.
* **`xcaddy/vars/main.yml`**: xcaddy version and installation path.
* **`caddy/vars/main.yml`**: Caddy version, paths, user/group, and the crucial **`caddy_plugins`** list.
* **`crowdsec/vars/main.yml`**: CrowdSec version, installation script URL, and bouncer configuration.

### Templates (`roles/*/templates/`)

Templates are Jinja2 files used to generate configuration files dynamically on the target servers. They use the variables loaded from `group_vars/` and `host_vars/` to create unique configurations for each host.

* **`caddy/templates/Caddyfile.j2`**: Your primary Caddy configuration. This is where you'll define your domains, proxy settings, CrowdSec integration, and Cloudflare DNS challenge.
* **`caddy/templates/caddy.service.j2`**: The Systemd unit file for Caddy.
* **`rathole/templates/rathole.toml.j2`**: Rathole's configuration file, dynamically generated based on `rathole_role` and `rathole_server_config` or `rathole_client_config`.

### Ansible Vault

**It's highly recommended to use Ansible Vault for sensitive data** like Cloudflare API tokens (`cloudflare_api_token`) or SSH private key passphrases.

1. **Create a vault file**: You can have a single vault file (e.g., `group_vars/all/vault.yml`) to store all secrets, or host-specific vault files if secrets vary greatly per host.

    ```bash
    ansible-vault create group_vars/all/vault.yml
    ```

2. **Add your sensitive variables inside**:

    ```yaml
    vault_crowdsec_api_key: "API_KEY"
    vault_crowdsec_enrollment_key: "ENROLLMENT_KEY"
    vault_cloudflare_api_token_server: "CLOUDFARE_TOKEN"
    ```

3. **Remember your vault password\!**

-----

## 5\. Deployment

To deploy the stack on your target servers:

1. Navigate to your `~/ansible/` directory.
2. Run the main playbook:

    ```bash
    ansible-playbook -i inventory.ini site.yml --ask-vault-pass
    ```

    (Omit `--ask-vault-pass` if you aren't using Ansible Vault.)

Ansible will connect to your servers, perform initial system updates and common package installations, then proceed with installing and configuring the relevant software (Rathole, and conditionally Caddy/CrowdSec/Go/xcaddy), setting up all services automatically.

-----

## 6\. Maintenance

### Updating Software Versions

To update Rathole, Go, xcaddy, CrowdSec, or Caddy:

1. **Edit the corresponding `vars/main.yml` file** for the role you want to update (e.g., `roles/caddy/vars/main.yml` for Caddy).
2. Change the `_version` variable to the desired new version number.
3. Re-run the main playbook:

    ```bash
    ansible-playbook -i inventory.ini site.yml --ask-vault-pass
    ```

    Ansible's idempotency ensures only necessary steps are performed (e.g., downloading and reinstalling the new version, restarting services).

### Modifying Configurations

To change a configuration (e.g., Caddyfile, Rathole config):

1. **Edit the relevant Jinja2 template** in `roles/*/templates/`.
2. If the change affects variables, update the appropriate `group_vars/` or `host_vars/` file.
3. Re-run the main playbook:

    ```bash
    ansible-playbook -i inventory.ini site.yml --ask-vault-pass
    ```

    Ansible detects the template change and restarts affected services (e.g., Caddy service will restart if `Caddyfile.j2` changes).

### Adding/Removing Hosts

* **Adding hosts**: Add the new server's hostname to `inventory.ini` under the appropriate group (e.g., `[web_servers]`). Then, create a corresponding YAML file in `host_vars/` (e.g., `host_vars/new_server.yml`) with its specific variables. Re-run the playbook to provision it.
* **Removing hosts**: Remove the host from `inventory.ini`. If you need to uninstall services, you'd create a separate Ansible playbook for de-provisioning.

### Checking Service Status

After deployment or during maintenance, you can check the status of services on your target servers via SSH:

* **Rathole**: `sudo systemctl status rathole`
* **CrowdSec**:
  * `sudo systemctl status crowdsec`
  * `sudo cscli metrics` (to see CrowdSec statistics)
  * `sudo cscli bouncers list` (to verify Caddy bouncer)
* **Caddy**:
  * `sudo systemctl status caddy`
  * `sudo journalctl -u caddy -f` (to view Caddy logs in real-time)
  * `caddy version` (to check Caddy version and compiled modules)
* **Go**: `go version`
* **xcaddy**: `xcaddy version`

### Troubleshooting

* **Playbook Failures**: Review the Ansible output for specific error messages. Common issues include SSH connection problems (check `ansible_user`, `ansible_ssh_private_key_file`), incorrect variable values, or syntax errors in templates.
* **Service Not Starting**: Check the service logs using `sudo journalctl -u <service_name> -f` for detailed error messages (e.g., `journalctl -u caddy -f`).
* **Permission Issues**: Ensure the Caddy user (`caddy`), Rathole user (`rathole`), and their respective groups have appropriate permissions to directories and files.
* **Network/Firewall**: Verify that firewalls (on the server or network) aren't blocking necessary ports (e.g., 80, 443 for Caddy, Rathole's chosen ports).

-----

## 7\. Contribution

Feel free to open issues or submit pull requests if you have suggestions for improvements or bug fixes.

-----

## 8\. License

This project is open-source and available under the **MIT License**.
