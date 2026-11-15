# Ansible-Rathole-WebGuard

[![Lint Ansible](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml/badge.svg)](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml)

Ansible playbook that publishes services from a home network through a small VPS:

- **Rathole** tunnels the services from your LAN (client) to the VPS (server).
- **Caddy** on the VPS terminates TLS, sets security headers (HSTS, no-sniff, frame and referrer policy) and reverse-proxies to the tunnel.
- **CrowdSec** (optional, on by default) blocks bad IPs and inspects requests (AppSec).
- **Coraza WAF**, **Cloudflare DNS-01**, wildcard certificates, blocklist import and the **CrowdSec Web UI** are opt-in.

Supported: Debian 12 and 13 and Ubuntu 22.04 and 24.04 LTS on x86_64, arm64 and armv7, and Arch Linux on x86_64. Server and client may run different systems. The playbook stops on other OS families. See [Arch Linux](#arch-linux) for what differs there.

Target server size: 2 vCPU, 2 GB RAM, about 10 GB disk. See [Resource footprint](#resource-footprint).

## How it works

```
Internet ──► VPS (rathole server)                      Home LAN (rathole client)
             Caddy :443 ──► 127.0.0.1:<port> ◄── tunnel :2333 ──► 192.168.1.10:<port>
             (TLS, CrowdSec, rate limit, WAF)                       (your service)
```

Caddy proxies each site to a local port on the VPS. Rathole binds that port to `127.0.0.1` and forwards it through the tunnel to the service at home.

## Quickstart

A **tuple** is one server (VPS) and one client (home server) connected by one tunnel. You configure a tuple in two places: a group in `inventory.ini` and one file `group_vars/tunnel_<name>.yml`. Global settings (feature flags, Coraza WAF) live in `group_vars/all.yml`; everything that belongs to one tuple (tunnel, services, CrowdSec, Web UI ports, Cloudflare token, swap) lives in the tuple file.

### Before you start

- A computer with Ansible (`ansible-core`, tested with 2.21) that reaches both hosts over SSH, as `root` or as a user with `sudo`. Python is installed on the hosts if it is missing.
- A VPS and a home server with a supported OS (see above).
- For each domain a DNS record that points to the VPS (A, and AAAA if the VPS has IPv6). Without Cloudflare, Caddy needs it before the first run to get its certificates.
- On the VPS, these ports reachable from the internet: 80/tcp, 443/tcp and 443/udp for Caddy, and the Rathole port (default 2333/tcp). Open them in the provider firewall, or let the playbook manage the host firewall (`enable_firewall: true`, see [Firewall](#firewall)).

### 1. Copy the example files

```bash
git clone https://github.com/chrisvgt/ansible-rathole-webguard.git
cd ansible-rathole-webguard
cp -n inventory.example.ini inventory.ini
cp -n group_vars/all.example.yml group_vars/all.yml
cp -n group_vars/tunnel.example.yml group_vars/tunnel_home.yml
```

Only the `*.example*` files are tracked. Your copies (`inventory.ini`, everything else in `group_vars/` and `host_vars/`) are gitignored and are never committed.

### 2. Inventory

```ini
[tunnel_home]
vps ansible_host=203.0.113.10 rathole_role=server ansible_user=ubuntu
home ansible_host=192.168.1.20 rathole_role=client ansible_user=ubuntu

[webservers:children]
tunnel_home
```

The group name (`tunnel_home`) selects `group_vars/tunnel_home.yml`. The client connects to the server's `ansible_host` (or its inventory name if there is none; IPv6 works too); set `rathole_public_addr` in the tuple file if the client must use another address. List the server first: on a new tuple the server creates the tunnel keys.

`host_key_checking` is enabled in `ansible.cfg`. Connect to each host once with `ssh` and verify the fingerprint, so it is in `~/.ssh/known_hosts`.

### 3. Services

In `group_vars/tunnel_home.yml`, set `tunnel_id` and list your services once:

```yaml
tunnel_id: home

tunnel_services:
  - name: jellyfin
    domain: jellyfin.example.com
    local_addr: 192.168.1.10:8096 # Where the service runs, seen from the client
    stream: true
```

From this, the playbook builds the Rathole server and client configuration and the Caddy site. See [Services](#services) for all keys. The list stays the same with or without Cloudflare and wildcard certificates; those are switched in `group_vars/all.yml`.

### 4. Run

No secrets are needed for the default settings: the tunnel keys and the CrowdSec credentials are created on the server (see [Secrets](#secrets)). With `enable_cloudflare: true`, set `cloudflare_api_token` in the tuple file first.

```bash
./run-playbook.sh --no-vault
```

The script runs `ansible-playbook -i inventory.ini site.yml`. Without `--no-vault` it asks for the vault password, for secrets kept in Ansible Vault. Use `--vault-file <file>`, `--inventory <file>` or `--playbook <file>` to change the defaults. All other options are passed on to `ansible-playbook`, for example `--limit home`, `--tags caddy`, or `-K` if `sudo` asks for a password. Before later changes, `--check --diff` shows what would change without changing anything.

The first run takes a while: Caddy is built from source on the VPS (see [Caddy build](#caddy-build)).

### 5. Check

Open one of your domains in a browser. If it does not load, look at the services:

```bash
sudo systemctl status rathole caddy crowdsec   # on the VPS
sudo journalctl -u rathole -n 20               # on both hosts: is the tunnel connected?
```

See [Maintenance](#maintenance) for more commands and common problems.

### More tuples

Add another group to `inventory.ini`, add it to `[webservers:children]`, and copy `group_vars/tunnel.example.yml` to `group_vars/tunnel_<group>.yml` with its own `tunnel_id`.

## Secrets

With the default settings you set no secrets. The server creates them on the first run and keeps them in root-only files:

| Secret                            | Stored on the server                                   | Set it yourself with               |
| --------------------------------- | ------------------------------------------------------ | ---------------------------------- |
| Rathole Noise keys and token      | `/etc/rathole/noise.key`, `noise.pub`, `default_token` | see below                          |
| CrowdSec bouncer key for Caddy    | `/etc/crowdsec/caddy.bouncer.key`                      | `crowdsec_api_key`                 |
| Blocklist import machine password | `/etc/crowdsec/blocklist-import.machine.password`      | `crowdsec_machine_password`        |
| CrowdSec Web UI machine password  | `/etc/crowdsec/web-ui.machine.password`                | `crowdsec_web_ui_machine_password` |

A value set in the tuple file always wins. If you change it later, the next run registers the new key or password with CrowdSec.

Only these come from you:

| Variable                  | Needed when                |
| ------------------------- | -------------------------- |
| `cloudflare_api_token`    | `enable_cloudflare: true`  |
| `crowdsec_enrollment_key` | optional, CrowdSec Console |

The Rathole client reads the public key and the token from its server, also with `--limit <client>`. To keep existing tunnel values, set `rathole_noise_private_key`, `rathole_noise_public_key` and `rathole_default_token` in the tuple file. To rotate, delete the three files on the server and run the playbook for both hosts. For the CrowdSec values, delete the file and run the playbook for the server.

Two ways to store your own secrets:

**Plaintext (simple).** Write the value into `group_vars/tunnel_<name>.yml` and run `./run-playbook.sh --no-vault`. The file is gitignored.

**Ansible Vault.** Reference a vault variable in the tuple file (`cloudflare_api_token: "{{ vault_cloudflare_api_token_server }}"`) and define it in an encrypted file:

```bash
mkdir -p group_vars/webservers
ansible-vault create group_vars/webservers/vault.yml
```

```yaml
vault_cloudflare_api_token_server: "..."
```

Run `./run-playbook.sh` (prompts) or `./run-playbook.sh --vault-file ~/.vault_pass`. Do not create a directory with the same name as one of your files (`group_vars/all/`, `group_vars/tunnel_home/`): Ansible then ignores the file of that name.

The Cloudflare token only needs to be set as `cloudflare_api_token`. Ansible writes it to `/etc/caddy/caddy.env` (root, mode 0600) on the server, and systemd passes it to Caddy. No manual env file is needed.

## Configuration

### Feature flags (`group_vars/all.yml`)

| Variable                 | Default       | Effect                                                                                            |
| ------------------------ | ------------- | ------------------------------------------------------------------------------------------------- |
| `enable_crowdsec`        | `true`        | CrowdSec engine, firewall bouncer, AppSec and the Caddy bouncer plugin                            |
| `enable_firewall`        | `false`       | nftables firewall on the server, see [Firewall](#firewall)                                        |
| `enable_rate_limit`      | `true`        | Per-site rate limit (see [Services](#services)) and the ratelimit plugin                          |
| `enable_cloudflare`      | `false`       | Cloudflare DNS-01 challenge for all certificates (plugin + `cloudflare_api_token`)                |
| `enable_wildcard`        | `false`       | One wildcard certificate per base domain, see [Services](#services). Requires `enable_cloudflare` |
| `enable_coraza_waf`      | `false`       | WAF for every site that does not set `coraza_mode` itself                                         |
| `coraza_mode_default`    | `recommended` | WAF mode used by `enable_coraza_waf`                                                              |
| `enable_crowdsec_import` | `false`       | Hourly import of public blocklists into CrowdSec. Requires `enable_crowdsec`                      |
| `enable_crowdsec_web_ui` | `false`       | CrowdSec Web UI in a Podman container, see [CrowdSec Web UI](#crowdsec-web-ui). Needs more RAM    |
| `enable_system_tuning`   | `true`        | `system` role, see [Small host tuning](#small-host-tuning-system-role)                            |
| `apt_upgrade_mode`       | `safe`        | `apt upgrade` mode on every run: `safe`, `full`, `dist`, `yes`, or `no` to skip                   |
| `enable_auto_reboot`     | `true`        | Reboot only if package upgrades require it. `false` only reports a pending reboot                 |

Without `group_vars/all.yml` these defaults apply. Flags can also be set per tuple in `group_vars/tunnel_<name>.yml` or per host in `host_vars/<host>.yml`. The same goes for every role setting in `roles/<role>/defaults/main.yml` (memory limits, Caddy build settings, ...). Settings of the Coraza WAF (`coraza_file_whitelist_*`, audit log, body limits) are in `group_vars/all.example.yml`.

Settings that belong to one tuple are in `group_vars/tunnel.example.yml`: the tunnel (`rathole_*`), `tunnel_services`, the CrowdSec keys, `crowdsec_web_ui_*`, `cloudflare_api_token` and the [swap](#small-host-tuning-system-role) settings. Server options there: `ntfy_enabled` (a push message per ban with service, rule, request, origin and the `cscli decisions delete --ip` command to lift it), `dynamic_whitelist_enabled` with `dynamic_ddns_hostnames` (never ban your own DDNS IPs), `duration_expr` (longer bans for repeat offenders).

### Services

Each entry in `tunnel_services`:

| Key                                  | Required | Effect                                                                                               |
| ------------------------------------ | -------- | ---------------------------------------------------------------------------------------------------- |
| `name`                               | yes      | Unique service name                                                                                  |
| `local_addr`                         | yes      | Where the service runs, seen from the client (`192.168.1.10:8096`)                                   |
| `bind_addr`                          | no       | Where Rathole exposes it on the server, default `127.0.0.1:<port of local_addr>`. Caddy proxies here |
| `domain`                             | no       | One domain or a list. Without a domain the service is tunnel-only (no Caddy site)                    |
| `type`                               | no       | `tcp` (default) or `udp`                                                                             |
| `mode`                               | no       | `forward` (default) or `reverse`, see [Reverse services](#reverse-services)                          |
| `token`, `nodelay`, `retry_interval` | no       | Rathole settings for this service                                                                    |

Keep `bind_addr` on `127.0.0.1` for web services, so they are only reachable through Caddy. Use `0.0.0.0:<port>` only for tunnel-only services that must be reachable directly (VPN, game servers): they need no `domain`, only a DNS record; the run warns about a service with both. The same port may be used once for `tcp` and once for `udp`. Ports the server needs itself are rejected: 80 and 443 (Caddy), the Rathole port, SSH and, with CrowdSec, 8080, 7422 and 6060. For an app on port 80 or 8080 at home, set a free port on the server, e.g. `bind_addr: 127.0.0.1:18080`.

All other keys are Caddy site options:

| Key                                                                 | Effect                                                                                |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `coraza_mode`                                                       | `off`, `minimal`, `recommended`, `moderate`, `strict` (see below)                     |
| `stream: true`                                                      | No response buffering (media), also disables AppSec                                   |
| `disable_appsec: true`                                              | Skip CrowdSec AppSec for this site                                                    |
| `rate_limit_events`, `rate_limit_window`                            | Rate limit per IP, default `500` per `1m`                                             |
| `cache_paths`                                                       | Paths that get `Cache-Control: max-age=86400` (Jellyfin defaults)                     |
| `proxy_timeout`                                                     | Dial and response header timeout for the backend                                      |
| `enable_forward`, `forward_path`, `forward_path_port`, `forward_ip` | Send `forward_path*` to another local port, optionally with a fixed `X-Forwarded-For` |
| `log_file`, `log_roll_size`, `log_roll_keep`, `log_roll_keep_for`   | Access log settings (traditional mode only)                                           |

How Caddy serves the domains depends on `enable_wildcard`:

|                                  | `enable_wildcard: false`                           | `enable_wildcard: true` (requires `enable_cloudflare`)           |
| -------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------- |
| Site blocks                      | One per domain                                     | One per base domain (`*.example.com`), one handler per subdomain |
| Certificates                     | One per domain, HTTP/TLS-ALPN or Cloudflare DNS-01 | One wildcard certificate per base domain, Cloudflare DNS-01      |
| Access log                       | One per site                                       | One per base domain                                              |
| Unknown subdomain                | -                                                  | `404 Service not found`                                          |
| `example.com`, `a.b.example.com` | One per domain                                     | Own site block (not covered by `*.example.com`)                  |

The base domain is the domain without its first label, so wildcard mode does not suit domains under a two-part suffix such as `example.co.uk` (it would ask for `*.co.uk`); use `enable_wildcard: false` for them.

A service with several domains gets one site per domain, named `<name>_<domain>` (dots replaced by `_`). Site names are used for log files and rate limit zones.

WebSocket upgrades skip WAF and AppSec (they cannot inspect the stream); the CrowdSec IP check and the rate limit (own zone `<site>_ws`, one event per upgrade) still apply. Only a complete handshake counts as an upgrade (`GET`, `Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`); a request that only carries an `Upgrade` header goes through the full pipeline.

Behind a CDN or another proxy (e.g. the Cloudflare proxy), set `caddy_trusted_proxies` (CIDRs) and `caddy_client_ip_headers` (e.g. `[CF-Connecting-IP]`). Otherwise the rate limit and CrowdSec see only the proxy's addresses and ban it for all users. Without these settings a client's `X-Forwarded-For` is ignored.

#### Reverse services

With `mode: reverse` a service goes the other way: the **server** exposes one of its own local services and the **client** listens for it, e.g. to reach a dashboard that only listens on `127.0.0.1` of the VPS from the home network. Nothing is opened on the server, the connection goes through the Rathole port with the same transport and keys.

```yaml
tunnel_services:
  - name: crowdsec-dashboard
    mode: reverse
    local_addr: 127.0.0.1:3000 # Where the service runs, seen from the server
    bind_addr: 0.0.0.0:3000 # Where the client listens, default 127.0.0.1:<port of local_addr>
```

`local_addr` and `bind_addr` swap sides: the server connects to `local_addr`, the client binds `bind_addr`. A reverse service has no Caddy site, so `domain` is rejected. Its `bind_addr` is checked for conflicts only against other reverse services (all on the client); the ports the server needs itself are allowed as `local_addr`. The firewall opens nothing for it. Both hosts need Rathole 0.7.0 or later (the default); an older Rathole rejects the config.

### Small host tuning (`system` role)

| Variable                        | Default     | Effect                                                                                                                                                                                                                |
| ------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `system_journald_max_use`       | `200M`      | Cap for persistent journal logs                                                                                                                                                                                       |
| `system_swap_enabled`           | `false`     | Create and enable a swap file (server only)                                                                                                                                                                           |
| `system_swap_file`              | `/swapfile` | Swap file path                                                                                                                                                                                                        |
| `system_swap_size`              | `1G`        | Swap size (not resized once created)                                                                                                                                                                                  |
| `system_swappiness`             | `10`        | `vm.swappiness`, set only when swap is enabled                                                                                                                                                                        |
| `system_unattended_upgrades`    | `true`      | Debian/Ubuntu: install security updates daily with `unattended-upgrades`; `false` leaves the host's setting untouched                                                                                                 |
| `system_sysctl_hardening`       | `true`      | Kernel and network hardening in `/etc/sysctl.d/60-webguard-hardening.conf` (no redirects or source routing, SYN cookies, loose `rp_filter`, restricted kernel pointers/dmesg/BPF); IPv6 and forwarding stay untouched |
| `system_unattended_reboot`      | `false`     | Reboot automatically when such an update requires it                                                                                                                                                                  |
| `system_unattended_reboot_time` | `04:00`     | Time of that reboot                                                                                                                                                                                                   |

The role runs before Caddy, so swap is available for the Caddy build.

The swap file is set up on the **server only**: the client runs just Rathole and needs none, so the setting can stay in the tuple file. Servers with 2 GB RAM or less should enable it, mainly for the Caddy build, and also when the Web UI runs. In an LXC or OpenVZ container the role skips it with a message (the container host decides about swap); when `swapon` is not permitted on other virtualised hosts, the run warns instead of failing and leaves `/etc/fstab` alone. A swap file created on a client by an older version is not removed: `swapoff /swapfile`, delete it and its line in `/etc/fstab`.

## Arch Linux

Server and client can run Arch Linux (x86_64), mixed with Debian or Ubuntu. The configuration files are the same.

- **Login**: as `root` with an SSH key works without `sudo`. A fresh install needs nothing else; Python is installed by the playbook.
- **Packages** come from the official repositories, not from the AUR. CrowdSec and its firewall bouncer are not in the official repositories: they are installed from the vendors' release archives on GitHub, checked against the SHA256 that GitHub shows. Their versions are set in `roles/crowdsec/defaults/main.yml` (`crowdsec_version`, `crowdsec_firewall_bouncer_version`) and updated on the next run.
- **Updates**: there are no automatic updates. Arch Linux has no separate security updates and an unattended full upgrade can need manual steps, so each playbook run upgrades the whole system (`pacman -Syu`). Run it regularly.
- **Logs**: CrowdSec and the firewall bouncer log to the journal, which the `system` role limits in size.
- Needs the `community.general` collection on the Ansible computer (part of the `ansible` package; with `ansible-core` only: `ansible-galaxy collection install community.general`).

Moving the VPS to another system: install the new system, keep the inventory entry, run the playbook. The server creates new tunnel keys, tokens and the bouncer key and passes them to the client in the same run; Caddy requests new certificates. Only a CrowdSec Console enrollment has to be repeated.

## What happens on every run

1. **Preflight checks** (before anything changes): Debian, Ubuntu or Arch Linux (x86_64), `rathole_role` is `server` or `client`, `enable_wildcard` has `enable_cloudflare`, `cloudflare_api_token` is set when Cloudflare is enabled, `enable_crowdsec_import` has `enable_crowdsec`, a server in traditional mode has at least one site, `tunnel_id` and `tunnel_services` are set, the tuple has one server and at most one client, service names are unique, `mode` is `forward` or `reverse` and reverse services have no `domain`, each `bind_addr` and `type` is used once per side (`0.0.0.0:<port>` counts for every address on that port), `enable_crowdsec_web_ui` has `enable_crowdsec`, an x86_64 or arm64 server, free ports and a valid client address (and no service named `crowdsec-web-ui`), both Noise keys are set together, and the server's `/etc/resolv.conf` lists a nameserver (Caddy reads only that file). The roles also check that the CPU architecture is supported and that the import password is set.
2. **System upgrade**: `apt upgrade` (mode `apt_upgrade_mode`) and `autoremove`; on Arch Linux `pacman -Syu`, and with a new kernel a reboot right away (if `enable_auto_reboot` is true), because Arch Linux removes the modules of the running kernel that the firewall needs.
3. **Roles**: `system`, then on the server `caddy` (with `go_lang` and `xcaddy`), `crowdsec`, `crowdsec_import`, `crowdsec_web_ui` (also to remove it again), `rathole` on both hosts, and `firewall` on the server if enabled.
4. **Reboot** if an upgrade requires it (`/var/run/reboot-required`; on Arch Linux a new kernel) and `enable_auto_reboot` is true.

Hosts are processed one at a time and the play stops on the first error. Run single parts with tags, for example `./run-playbook.sh --no-vault --tags caddy`. Tags: `system`, `caddy`, `crowdsec`, `crowdsec_import`, `crowdsec_web_ui`, `rathole`, `firewall`, `reboot`, `cleanup`. A change of the Web UI ports or client address also needs `rathole` (`--tags crowdsec_web_ui,rathole`). The `firewall` tag needs `rathole` too (`--tags rathole,firewall`).

## Caddy build

Caddy is built on the server with xcaddy, because the plugins are not in the stock binary. The plugin list follows the flags:

| Plugin                                  | Included when                                                         |
| --------------------------------------- | --------------------------------------------------------------------- |
| CrowdSec bouncer (HTTP, layer4, AppSec) | `enable_crowdsec`                                                     |
| caddy-ratelimit                         | `enable_rate_limit`                                                   |
| Cloudflare DNS                          | `enable_cloudflare`                                                   |
| Coraza WAF                              | `enable_coraza_waf` or any site with a `coraza_mode` other than `off` |
| anything in `caddy_plugins`             | always (default: empty list)                                          |

Plugin versions are pinned (`caddy_plugin_*_version` in `roles/caddy/defaults/main.yml`, updated by Renovate). Caddy is only rebuilt when `caddy_version`, the plugin list or a plugin version changes. The Caddyfile is validated before it is written and Caddy is reloaded, not restarted.

## Coraza WAF

A small custom ruleset, not the full OWASP CRS, to keep CPU and memory low (measured: about 224 MB RAM instead of about 1.4 GB with CRS).

| `coraza_mode` | Rules                                                          |
| ------------- | -------------------------------------------------------------- |
| `off`         | WAF disabled for this site                                     |
| `minimal`     | HTTP method allowlist (incl. WebDAV), optional upload blocking |
| `recommended` | + null bytes, control characters, SQLi, XSS, path traversal    |
| `moderate`    | + command injection, file inclusion, Content-Type check        |
| `strict`      | + template injection, more aggressive SQLi/XSS/command rules   |
| not set       | `enable_coraza_waf` + `coraza_mode_default`                    |

Static files (`GET` with a whitelisted extension) skip the WAF; see `coraza_file_whitelist_*` in `group_vars/all.yml`.

Static files are matched by path only, and only with a plain query string (cache busters like `?v=3`); a query string such as `?x=.txt` or one with other characters does not skip the WAF.

Audit logs (relevant events only, no request headers or bodies, so no cookies or tokens) are written to `/var/log/caddy/coraza/modsec_<site>.log` and rotated by `/etc/logrotate.d/caddy-coraza` (10 MB, 3 rotations). They are kept outside `/var/log/caddy/*.log`, which CrowdSec parses. `/var/log/caddy` is readable only by `caddy` and root (mode 0750, `UMask=0027`); add other log readers (e.g. promtail) to the `caddy` group.

## CrowdSec

With `enable_crowdsec: true` the server gets the CrowdSec engine, the firewall bouncer (iptables; nftables on Arch Linux), the Caddy collection, AppSec (virtual patching, generic rules, HTTP CVEs) and the Caddy bouncer. Bans apply to IPv4 and IPv6. Private, loopback and link-local addresses are never banned. On Debian and Ubuntu without `/var/log/auth.log`, SSH logins are read from the journal. The Local API and AppSec must listen on loopback (`crowdsec_lapi_ip`, `crowdsec_appsec_ip`); the preflight checks reject other addresses. The database is flushed (5000 alerts, 7 days: `crowdsec_db_flush_max_items`, `crowdsec_db_flush_max_age`). Memory limits: see [Resource footprint](#resource-footprint).

Failed logins are detected without any setup. CrowdSec reads the Caddy access logs and bans an IP after 5 failed `POST`s (`400`, `401`, `403`) to a login-like path (a path segment such as `login`, `sign-in`, `auth`, `AuthenticateByName` or `token`; `/api/token-refresh` or `/author/` do not count); one attempt is forgotten per minute. A successful login on the same path resets the count, so users who retry after a dropped connection are not banned. Apps that answer a wrong password with `200` or a redirect cannot be told apart from a successful login in the access log. Turn it off with `crowdsec_login_detection: false`; check with `sudo cscli alerts list`.

Failed handshakes on the Rathole port are detected the same way: CrowdSec reads the Rathole log from the journal and bans an IP after 20 failed handshakes (wrong key or token, another protocol); one is forgotten per minute. Timeouts do not count, so your own client on a slow connection is not banned. Neither do a wrong token or an unknown service: they need the server's key, so they come from your own client while server and client configs differ (token rotation, removed service). To be safe from a wrong key after a config change, set `dynamic_ddns_hostnames`. Turn it off with `crowdsec_rathole_detection: false`.

Normal use of common self-hosted apps does not get users banned: the official CrowdSec whitelists for Nextcloud, Jellyfin, Plex, Jellyseerr, Overseerr and a few others are installed (`crowdsec_hub_whitelists`), and a `POST` answered with `401` outside a login path counts as an expired session, not as an attack. The package's `crowdsec-hubupdate.timer` updates collections and whitelists daily.

`enable_crowdsec_import: true` adds [crowdsec-blocklist-import](https://github.com/wolffcatskyy/crowdsec-blocklist-import), which imports 28+ public feeds (IPsum, Spamhaus DROP, Blocklist.de, Firehol, Abuse.ch, DShield, Tor exit nodes and others) every hour:

- installed with pipx into `/opt/crowdsec-blocklist-import`, owned by root, pinned to the commit `crowdsec_import_commit` (the commit of the tag `crowdsec_import_version`; a tag can be moved, so it is only used to check the installed version)
- runs as the system user `crowdsec-import` from a sandboxed systemd service and timer
- creates its own LAPI machine and bouncer, with a generated password (or `crowdsec_machine_password`)
- imported bans bypass the DDNS whitelist of the engine, so the importer gets its own allowlist: the IPs of `dynamic_ddns_hostnames` (resolved on each playbook run; a changed DDNS address is picked up on the next run) and `crowdsec_import_extra_allowlist` (IPs or CIDRs, e.g. your home or office)
- feeds can be switched off one by one, e.g. `crowdsec_enable_tor: false`; all options and their defaults are in `roles/crowdsec_import/defaults/main.yml`

## CrowdSec Web UI

[crowdsec-web-ui](https://github.com/TheDuffman85/crowdsec-web-ui) is a dashboard for CrowdSec: alerts, decisions, statistics, metrics, allowlists and manual bans. It is optional and off by default. It needs **more resources** than the rest of the server, see below.

```yaml
# group_vars/all.yml
enable_crowdsec_web_ui: true
```

Requires `enable_crowdsec: true` and an x86_64 or arm64 server (the upstream image exists for these only; the playbook stops on others). After the run:

- The server runs the image `ghcr.io/theduffman85/crowdsec-web-ui` with **Podman** as the systemd service `crowdsec-web-ui` (a hand-written unit, so it works from Podman 3.4 on Ubuntu 22.04 to current versions). The image is pinned by tag and digest (`crowdsec_web_ui_image`, updated by Renovate; `dev-*` tags are ignored) and pulled once per version.
- The app listens on `127.0.0.1:<crowdsec_web_ui_port>` of the server **only**. It has no listen address setting, so a small script (`/etc/crowdsec-web-ui/loopback.cjs`, preloaded into Node) binds it to loopback; the run checks with `ss` that nothing else listens and fails otherwise. The firewall opens nothing for it.
- A **Rathole reverse service** named `crowdsec-web-ui` is added to the tuple (no entry in `tunnel_services` needed): the client listens on `crowdsec_web_ui_client_listen:crowdsec_web_ui_client_port` and forwards to the server through the tunnel.
- The playbook creates the LAPI machine `crowdsec-web-ui` with a generated password (`/etc/crowdsec/web-ui.machine.password`, root only; the container gets it from `/etc/crowdsec-web-ui/env`, mode 0600).

**First use**: open `http://<client>:<client port>` (default `http://127.0.0.1:3000` on the client itself, or the client's LAN address with `0.0.0.0`). The first visit asks you to create the admin account; do it right away. Users, settings and the alert cache are in `/var/lib/crowdsec-web-ui` (back it up).

| Variable                          | Default                                                  | Effect                                                                                               |
| --------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `crowdsec_web_ui_port`            | `3000`                                                   | Port on the server (127.0.0.1)                                                                       |
| `crowdsec_web_ui_client_port`     | `3000`                                                   | Port the client listens on                                                                           |
| `crowdsec_web_ui_client_listen`   | `127.0.0.1`                                              | Client address: `127.0.0.1` (the client only), `0.0.0.0` (whole LAN) or one of its IPv4 addresses    |
| `crowdsec_web_ui_memory_max`      | `512m`                                                   | Container memory limit (`podman --memory`); `crowdsec_web_ui_node_heap_mb` (256) keeps Node below it |
| `crowdsec_web_ui_metrics`         | `true`                                                   | Show the CrowdSec Prometheus metrics (`127.0.0.1:6060`) in the UI                                    |
| `crowdsec_web_ui_include_origins` | `[crowdsec, cscli]` with the blocklist import, else `[]` | Origins of the alerts the UI loads, all others are hidden; `[]` is the app's default feed            |

The ports and the client address are read by the server **and** the client, so set them in the tuple file `group_vars/tunnel_<name>.yml` (they are per tuple, not global). The run rejects collisions before anything changes: the client port against other reverse services on the client, the server port against forward services bound on the server's loopback or all addresses and against the ports the server needs itself (80, 443, the Rathole port, SSH, 8080, 7422, 6060). Use another port, e.g. `crowdsec_web_ui_port: 13000`, when your own service uses 3000.

> **Warning:** with `crowdsec_web_ui_client_listen: "0.0.0.0"` everybody in the client's network can open the UI. There is no TLS, and the only protection is the admin login. Use `127.0.0.1` unless you need LAN access, and put it behind a VPN or an own reverse proxy with TLS if the LAN is not trusted. Whoever logs in can ban and unban IPs.

**Resources** (the reason this is opt-in):

- **RAM**: about 100 MB right after the start and, depending on how many alerts and decisions CrowdSec has, roughly 250-400 MB in steady state, plus Podman's small overhead (it is daemonless). The container is limited to 512 MB (`crowdsec_web_ui_memory_max`), so it is restarted rather than starving CrowdSec or Caddy. Together with the limits in [Resource footprint](#resource-footprint), a 2 GB host with CrowdSec, the blocklist import and the WAF gets tight; use **at least 2 GB RAM plus [swap](#small-host-tuning-system-role)** or 4 GB without swap, or skip the import.
- **Blocklist import**: the imported lists hold tens of thousands of decisions, and loading them all exceeds the Node heap (`JavaScript heap out of memory`, the service restarts in a loop). With `enable_crowdsec_import` the UI therefore loads only the engine's own alerts and manual bans (`crowdsec_web_ui_include_origins: [crowdsec, cscli]`). Every other origin is hidden: `blocklist-import`, `lists` (blocklists subscribed in the CrowdSec Console), `console`, and CAPI as without the filter. They still block, they are only not shown; check them with `cscli decisions list --origin <origin>`. An include list is used rather than excluding `blocklist-import`, because the app passes includes to the Local API, while excludes are applied after everything has been loaded into memory. To see them too, add their origin (`crowdsec_import_blocklist_decision_origin`, default `blocklist-import`) and raise the memory, e.g. `crowdsec_web_ui_node_heap_mb: 768` with `crowdsec_web_ui_memory_max: "1g"` (not measured). When the filter changes, the UI drops cached entries that no longer match on its next start.
- **Disk**: about 0.5 GB for the image (463 MB measured), plus Podman's storage in `/var/lib/containers` and the databases in `/var/lib/crowdsec-web-ui`. Plan for about 1 GB.
- **Network**: one pull of the image on the first run and for every new version.

Maintenance:

```bash
sudo systemctl status crowdsec-web-ui
sudo journalctl -u crowdsec-web-ui -f
sudo podman ps
```

**Update**: change `crowdsec_web_ui_image` (Renovate does it) and run the playbook; the new image is pulled, the service restarts and the images of earlier versions are removed (`crowdsec_web_ui_image_repo`).

**Remove**: set `enable_crowdsec_web_ui: false` and run the playbook for the server and the client (`--tags crowdsec_web_ui,rathole`). The service, its unit, env file and the LAPI machine are removed and the client stops listening. The images are removed too. The data in `/var/lib/crowdsec-web-ui` and Podman stay: `sudo rm -rf /var/lib/crowdsec-web-ui` and removing the `podman` package free the rest.

## Firewall

With `enable_firewall: true` the server drops all incoming connections except:

- SSH: every port `sshd` listens on (including `ListenAddress` with its own port), `ansible_port` and the port Ansible is connected on, so a non-default port set only in `~/.ssh/config` is kept open too
- 80/tcp, 443/tcp and 443/udp (HTTP/3) for Caddy (`firewall_web_ports: false` closes them)
- the Rathole port and services with a public `bind_addr`, e.g. `0.0.0.0:30000` (not reverse services, they listen on the client)
- `firewall_allowed_tcp_ports` / `firewall_allowed_udp_ports`

New connections to SSH are limited per source address (IPv6 per /64 prefix, so rotating addresses inside a prefix does not help; `firewall_conn_limit_rate` 120/minute, burst 120; `firewall_conn_limit_enabled: false` turns it off). The Rathole port, the web ports and public services have no such limit, so many visitors never cut the tunnel; the Rathole port is protected by its keys and CrowdSec. Dropped packets are logged with the prefix `webguard drop: ` (at most 10 per minute, `firewall_log_drops`).

Use it if the provider firewall is not used or not trusted. The home server (client) is not touched. The rules live in their own nftables table (`inet webguard`, file `/etc/nftables.d/webguard.nft`), loaded at boot by `webguard-firewall.service`, so the CrowdSec bouncer keeps working. When the rules change, or are no longer loaded, a timer removes them again after `firewall_rollback_seconds` (120) unless Ansible can open a new SSH connection, and they are then not loaded at boot either, so a mistake does not lock you out.

To remove the firewall, set `enable_firewall: false` and run the playbook: it deletes the table, the boot unit and the rules file. ICMP, ICMPv6 and DHCPv6 replies are always allowed, so the VPS keeps its IPv6 address. The ICMP rule uses protocol numbers, so minimal images without `netbase` (`/etc/protocols`) work too. On container VPS (LXC, OpenVZ) without their own kernel, nftables may not be available; the rules are checked with `nft -c` before anything is loaded.

## Rathole

| Transport   | Encryption        | Notes                                 |
| ----------- | ----------------- | ------------------------------------- |
| `noise`     | yes               | Recommended. Needs `pattern` and keys |
| `tls`       | yes, certificates | Needs a PKCS#12 file / CA certificate |
| `websocket` | with `tls: true`  | For networks that only allow HTTP(S)  |
| `tcp`       | no                | Only for trusted networks             |

With `tunnel_services` the transport is `noise` and the keys are generated automatically (see [Secrets](#secrets)). Set `rathole_transport` in the tuple file to use another transport. On the server, bind web services to `127.0.0.1` so they are only reachable through Caddy.

The service runs as user `rathole` with systemd sandboxing (`ProtectHome`, `ProtectSystem=strict`). Files it needs, such as TLS certificates, must not be under `/home`; `/etc/rathole` works.

## Resource footprint

- Caddy is compiled on the server with Go. The build needs about 2.5-3 GB of free disk space for the module and build caches in `/var/tmp/caddy-build`, which is removed after the build. The Go toolchain stays in `/usr/local/go`.
- The build runs with one compile job and a low GC target (`caddy_build_jobs`, `caddy_build_gogc`) to fit into 2 GB RAM. On 2 GB hosts, enable [swap](#small-host-tuning-system-role) as a safety margin.
- Steady state limits (systemd `MemoryMax`): CrowdSec 800 MB (`crowdsec_memory_max`; `GOMEMLIMIT=500MiB` keeps it below that without throttling), blocklist import 300 MB (`crowdsec_import_memory_max`), Rathole 256 MB (`rathole_memory_max`); journald 200 MB on disk (`system_journald_max_use`).
- The optional CrowdSec Web UI adds a container of up to 512 MB and about 1 GB of disk; see [CrowdSec Web UI](#crowdsec-web-ui).

## Updating

Pinned versions are role defaults (`roles/<role>/defaults/main.yml`) and can be overridden in `group_vars/all.yml`, `group_vars/tunnel_<name>.yml` or `host_vars/<host>.yml`, without editing role code:

| Variable                            | Component                                                                                     |
| ----------------------------------- | --------------------------------------------------------------------------------------------- |
| `caddy_version`                     | Caddy (triggers rebuild)                                                                      |
| `go_lang_version`                   | Go toolchain                                                                                  |
| `xcaddy_version`                    | xcaddy                                                                                        |
| `rathole_version`                   | Rathole                                                                                       |
| `crowdsec_import_version`           | crowdsec-blocklist-import                                                                     |
| `crowdsec_import_commit`            | crowdsec-blocklist-import (commit of the tag, from `git ls-remote <repo> 'refs/tags/<tag>*'`) |
| `crowdsec_version`                  | CrowdSec                                                                                      |
| `crowdsec_firewall_bouncer_version` | CrowdSec firewall bouncer                                                                     |
| `crowdsec_web_ui_image`             | CrowdSec Web UI (container image, tag and digest; Renovate updates both)                      |

Then run the playbook again. System packages are updated on every run; CrowdSec and its firewall bouncer stay at these versions (on Debian and Ubuntu with an APT pin, so `apt upgrade` and unattended-upgrades leave them alone) until the version changes. Hub rules (whitelists, AppSec and CVE rules) are only updated for the latest CrowdSec version, so keep `crowdsec_version` current.

On Debian and Ubuntu, CrowdSec comes from its APT repository on packagecloud.io, set up without the vendor's install script: the signing key is checked against the pinned fingerprint `crowdsec_apt_key_fingerprint` and stored as `/etc/apt/keyrings/crowdsec.asc`, the source is `/etc/apt/sources.list.d/crowdsec.sources` with `Signed-By`. A different key stops the run. Hosts set up by older versions are migrated (the script's `crowdsec_crowdsec.list` and keyring are removed). If CrowdSec ever rotates its key, check the new fingerprint independently before changing the variable.

With the [Renovate](https://github.com/apps/renovate) app installed on the repository, `renovate.json` opens a pull request against `develop` whenever one of these versions, a GitHub Action or a pre-commit hook has a new release (weekly, Monday morning). A version set in your own files overrides the role default, so remove such overrides to follow these updates.

Container images (development image, test images, gitleaks) are pinned by `tag@sha256` digest; Renovate updates tag and digest together. pre-commit runs gitleaks on staged changes, and CI scans the whole git history.

### Upgrading existing hosts

`group_vars/all.yml` was part of the repository in older versions and is now your own, gitignored file (template: `group_vars/all.example.yml`). If you changed it, keep your copy before pulling:

```bash
cp group_vars/all.yml /tmp/all.yml && git checkout -- group_vars/all.yml
git pull
cp /tmp/all.yml group_vars/all.yml
```

Hosts deployed with an older version of this playbook need a few one-time manual steps on the server:

```bash
# Older versions made the Caddy data dir (TLS keys) world-readable
sudo chmod -R o-rwx /var/lib/caddy

# Older versions of the import role overwrote the agent's LAPI credentials.
# If this prints "login: blocklist-import", recreate the agent machine:
sudo grep '^login:' /etc/crowdsec/local_api_credentials.yaml
sudo cscli machines add -a --force && sudo systemctl restart crowdsec

# Coraza audit logs moved to /var/log/caddy/coraza/, the old files can go
sudo rm -f /var/log/caddy/modsec_*.log
```

## Maintenance

```bash
sudo systemctl status rathole caddy crowdsec
sudo journalctl -u caddy -f
sudo cscli metrics
sudo cscli decisions list
sudo cscli decisions list --origin blocklist-import
sudo systemctl list-timers crowdsec-blocklist-import.timer
sudo journalctl -u crowdsec-blocklist-import.service
```

Commands for the Web UI are in [CrowdSec Web UI](#crowdsec-web-ui).

| Problem                      | Check                                                                      |
| ---------------------------- | -------------------------------------------------------------------------- |
| Host key verification failed | `ssh` to the host once and accept the fingerprint                          |
| Preflight assertion fails    | The message names the missing or conflicting variable                      |
| Service won't start          | `sudo journalctl -u <service> -n 50`                                       |
| Caddy gets no certificate    | DNS points to the server? Ports 80/443 open? Cloudflare token permissions? |
| Caddyfile validation fails   | Run with `-e caddy_no_log=false` to see the error                          |
| Rathole tunnel down          | Client reaches server port? Service names, tokens and keys match?          |
| Rathole permission denied    | Referenced files under `/home`? Move them, e.g. to `/etc/rathole`          |

## Development

Lint, tests and pre-commit can run locally in a Docker image. On the host you need Linux with a local, rootful Docker Engine, plus `git` and `bash`. Ansible and the linters are not needed on the host. The integration test runs in GitHub Actions only.

```bash
./docker.sh build        # build the development image
./docker.sh lint         # yamllint, ansible-lint and a playbook syntax check
./docker.sh test         # test suite (tests/run.sh)
./docker.sh pre-commit   # format checks over the repository
./docker.sh all          # lint, test and pre-commit in one container
./docker.sh shell        # interactive bash in the container
```

- Only Linux with a local, rootful Docker daemon is supported. macOS, Windows, Docker Desktop, remote `DOCKER_HOST`, rootless Docker and SELinux-enforcing hosts are not.
- The container runs as root and mounts the host's Docker socket. Whoever can run `./docker.sh` can control the Docker daemon of the host. Use it only on a checkout you trust.
- The image is built from `docker/` only, so `inventory.ini`, `group_vars/` and `host_vars/` never end up in it.
- After each command the wrapper gives the repository back to your user, so no root-owned files stay behind.
- Tool versions are pinned in `docker/requirements.txt` and kept current by Renovate.

## Directory structure

```
├── ansible.cfg
├── inventory.example.ini       # Copy to inventory.ini
├── site.yml                    # Main playbook (preflight, upgrade, roles, reboot)
├── group_vars/
│   ├── all.example.yml         # Copy to all.yml: global settings (feature flags, WAF)
│   └── tunnel.example.yml      # Copy to tunnel_<name>.yml: one tuple (tunnel, services, CrowdSec, swap)
├── host_vars/                  # Optional per-host overrides
├── tasks/global_defaults.yml   # Defaults when group_vars/all.yml is missing
├── tasks/preflight.yml         # Configuration checks, also run on the examples
├── docker/                     # Development image (Dockerfile, pinned tools)
├── tests/                      # Test playbooks and scripts (tests/run.sh)
├── roles/
│   ├── system/                 # journald limit, optional swap, sysctl hardening, security updates
│   ├── caddy/                  # Caddy build, Caddyfile, service
│   ├── go_lang/                # Go toolchain for the Caddy build
│   ├── xcaddy/                 # Caddy builder
│   ├── crowdsec/               # CrowdSec engine, AppSec, bouncers
│   ├── crowdsec_import/        # Blocklist importer
│   ├── crowdsec_web_ui/        # Optional CrowdSec Web UI (Podman)
│   ├── python/                 # pipx for the importer
│   ├── rathole/                # Tunnel server and client
│   └── firewall/               # Optional nftables firewall on the server
├── docker.sh                   # Local checks in Docker (development)
└── run-playbook.sh             # Playbook wrapper with vault options (production)
```

## License

MIT, see [LICENSE](LICENSE).
