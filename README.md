# Ansible-Rathole-WebGuard

[![Lint Ansible](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml/badge.svg)](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml)

Ansible playbook that publishes services from a home network through a small VPS:

- **Rathole** tunnels the services from your LAN (client) to the VPS (server).
- **Caddy** on the VPS terminates TLS, sets security headers (HSTS, no-sniff, frame and referrer policy) and reverse-proxies to the tunnel.
- **CrowdSec** (optional, on by default) blocks bad IPs and inspects requests (AppSec).
- **Coraza WAF**, **Cloudflare DNS-01**, wildcard certificates and blocklist import are opt-in.

Supported: Debian (bullseye, bookworm, trixie) and Ubuntu (focal, jammy, noble) on x86_64, arm64 and armv6/armv7, and Arch Linux on x86_64. Server and client may run different systems. The playbook stops on other OS families. See [Arch Linux](#arch-linux) for what differs there.

Target server size: 2 vCPU, 2 GB RAM, about 10 GB disk. See [Resource footprint](#resource-footprint).

## How it works

```
Internet ──► VPS (rathole server)                      Home LAN (rathole client)
             Caddy :443 ──► 127.0.0.1:<port> ◄── tunnel :2333 ──► 192.168.1.10:<port>
             (TLS, CrowdSec, rate limit, WAF)                       (your service)
```

Caddy proxies each site to a local port on the VPS. Rathole binds that port to `127.0.0.1` and forwards it through the tunnel to the service at home.

## Quickstart

A **tuple** is one server (VPS) and one client (home server) connected by one tunnel. You configure a tuple in two places: a group in `inventory.ini` and one file `group_vars/tunnel_<name>.yml`. Global switches live in `group_vars/all.yml`.

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
./scripts/run-playbook.sh --no-vault
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

| Secret                            | Stored on the server                                   | Set it yourself with        |
| --------------------------------- | ------------------------------------------------------ | --------------------------- |
| Rathole Noise keys and token      | `/etc/rathole/noise.key`, `noise.pub`, `default_token` | see below                   |
| CrowdSec bouncer key for Caddy    | `/etc/crowdsec/caddy.bouncer.key`                      | `crowdsec_api_key`          |
| Blocklist import machine password | `/etc/crowdsec/blocklist-import.machine.password`      | `crowdsec_machine_password` |

A value set in the tuple file always wins. If you change it later, the next run registers the new key or password with CrowdSec.

Only these come from you:

| Variable                  | Needed when                |
| ------------------------- | -------------------------- |
| `cloudflare_api_token`    | `enable_cloudflare: true`  |
| `crowdsec_enrollment_key` | optional, CrowdSec Console |

The Rathole client reads the public key and the token from its server, also with `--limit <client>`. To keep existing tunnel values, set `rathole_noise_private_key`, `rathole_noise_public_key` and `rathole_default_token` in the tuple file. To rotate, delete the three files on the server and run the playbook for both hosts. For the CrowdSec values, delete the file and run the playbook for the server.

Two ways to store your own secrets:

**Plaintext (simple).** Write the value into `group_vars/tunnel_<name>.yml` and run `./scripts/run-playbook.sh --no-vault`. The file is gitignored.

**Ansible Vault.** Reference a vault variable in the tuple file (`cloudflare_api_token: "{{ vault_cloudflare_api_token_server }}"`) and define it in an encrypted file:

```bash
mkdir -p group_vars/webservers
ansible-vault create group_vars/webservers/vault.yml
```

```yaml
vault_cloudflare_api_token_server: "..."
```

Run `./scripts/run-playbook.sh` (prompts) or `./scripts/run-playbook.sh --vault-file ~/.vault_pass`. Do not create a directory with the same name as one of your files (`group_vars/all/`, `group_vars/tunnel_home/`): Ansible then ignores the file of that name.

The Cloudflare token only needs to be set as `cloudflare_api_token`. Ansible writes it to `/etc/caddy/caddy.env` (root, mode 0600) on the server, and systemd passes it to Caddy. No manual env file is needed.

## Configuration

### Feature flags (`group_vars/all.yml`)

| Variable                 | Default       | Effect                                                                                            |
| ------------------------ | ------------- | ------------------------------------------------------------------------------------------------- |
| `enable_crowdsec`        | `true`        | CrowdSec engine, firewall bouncer, AppSec and the Caddy bouncer plugin                            |
| `enable_firewall`        | `false`       | nftables firewall on the server, see [Firewall](#firewall)                                        |
| `enable_rate_limit`      | `true`        | Per-site rate limit (default 500 requests per minute per IP) and the ratelimit plugin             |
| `enable_cloudflare`      | `false`       | Cloudflare DNS-01 challenge for all certificates (plugin + `cloudflare_api_token`)                |
| `enable_wildcard`        | `false`       | One wildcard certificate per base domain, see [Services](#services). Requires `enable_cloudflare` |
| `enable_coraza_waf`      | `false`       | WAF for every site that does not set `coraza_mode` itself                                         |
| `coraza_mode_default`    | `recommended` | WAF mode used by `enable_coraza_waf`                                                              |
| `enable_crowdsec_import` | `false`       | Hourly import of public blocklists into CrowdSec. Requires `enable_crowdsec`                      |
| `enable_system_tuning`   | `true`        | `system` role: journald size limit, optional swap file, automatic security updates                |
| `apt_upgrade_mode`       | `safe`        | `apt upgrade` mode on every run: `safe`, `full`, `dist`, `yes`, or `no` to skip                   |
| `enable_auto_reboot`     | `true`        | Reboot only if package upgrades require it. `false` only reports a pending reboot                 |

Without `group_vars/all.yml` these defaults apply. Flags can also be set per tuple in `group_vars/tunnel_<name>.yml` or per host in `host_vars/<host>.yml`. The same goes for every role setting in `roles/<role>/defaults/main.yml`, for example the CrowdSec limits (`crowdsec_memory_max`, `crowdsec_db_flush_max_age`), the Rathole memory limit (`rathole_memory_max`) or the Caddy build settings.

Server options in the tuple file: `ntfy_enabled` (CrowdSec alerts via ntfy), `dynamic_whitelist_enabled` with `dynamic_ddns_hostnames` (never ban your own DDNS IPs), `duration_expr` (longer bans for repeat offenders). See `group_vars/tunnel.example.yml`.

### Services

Each entry in `tunnel_services`:

| Key                                  | Required | Effect                                                                                               |
| ------------------------------------ | -------- | ---------------------------------------------------------------------------------------------------- |
| `name`                               | yes      | Unique service name                                                                                  |
| `local_addr`                         | yes      | Where the service runs, seen from the client (`192.168.1.10:8096`)                                   |
| `bind_addr`                          | no       | Where Rathole exposes it on the server, default `127.0.0.1:<port of local_addr>`. Caddy proxies here |
| `domain`                             | no       | One domain or a list. Without a domain the service is tunnel-only (no Caddy site)                    |
| `type`                               | no       | `tcp` (default) or `udp`                                                                             |
| `token`, `nodelay`, `retry_interval` | no       | Rathole settings for this service                                                                    |

Keep `bind_addr` on `127.0.0.1` for web services, so they are only reachable through Caddy. Use `0.0.0.0:<port>` only for tunnel-only services that must be reachable directly (VPN, game servers). The same port may be used once for `tcp` and once for `udp`. Ports the server needs itself are rejected: 80 and 443 (Caddy), the Rathole port, SSH and, with CrowdSec, 8080, 7422 and 6060. For an app on port 80 or 8080 at home, set a free port on the server, e.g. `bind_addr: 127.0.0.1:18080`.

All other keys are Caddy site options:

| Key                                                                 | Effect                                                                                |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `coraza_mode`                                                       | `off`, `minimal`, `recommended`, `moderate`, `strict` (see below)                     |
| `stream: true`                                                      | No response buffering (media), also disables AppSec                                   |
| `disable_appsec: true`                                              | Skip CrowdSec AppSec for this site                                                    |
| `rate_limit_events`, `rate_limit_window`                            | Rate limit, default `500` per `1m`                                                    |
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

WebSocket upgrades skip rate limiting, WAF and AppSec (they cannot inspect the stream); the CrowdSec IP check still applies.

### Legacy configuration

Configurations from older versions keep working: `rathole_server_config` / `rathole_client_config` and `caddy_sites` / `wildcard_sites` in `host_vars/<host>.yml`, with `rathole_role` per host. A host uses either `tunnel_services` or these variables, not both; the preflight check stops otherwise. To migrate, move the services of both hosts into one `tunnel_services` list and keep the existing keys and token with `rathole_noise_private_key`, `rathole_noise_public_key` and `rathole_default_token`, so the running tunnel does not change.

### Small host tuning (`system` role)

| Variable                        | Default     | Effect                                                                                                                |
| ------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- |
| `system_journald_max_use`       | `200M`      | Cap for persistent journal logs                                                                                       |
| `system_swap_enabled`           | `false`     | Create and enable a swap file                                                                                         |
| `system_swap_file`              | `/swapfile` | Swap file path                                                                                                        |
| `system_swap_size`              | `1G`        | Swap size (not resized once created)                                                                                  |
| `system_swappiness`             | `10`        | `vm.swappiness`, set only when swap is enabled                                                                        |
| `system_unattended_upgrades`    | `true`      | Debian/Ubuntu: install security updates daily with `unattended-upgrades`; `false` leaves the host's setting untouched |
| `system_unattended_reboot`      | `false`     | Reboot automatically when such an update requires it                                                                  |
| `system_unattended_reboot_time` | `04:00`     | Time of that reboot                                                                                                   |

The role runs before Caddy, so swap is available for the Caddy build.

## Arch Linux

Server and client can run Arch Linux (x86_64), mixed with Debian or Ubuntu. The configuration files are the same.

- **Login**: as `root` with an SSH key works without `sudo`. A fresh install needs nothing else; Python is installed by the playbook.
- **Packages** come from the official repositories, not from the AUR. CrowdSec and its firewall bouncer are not in the official repositories: they are installed from the vendors' release archives on GitHub, checked against the SHA256 that GitHub shows. Their versions are set in `roles/crowdsec/defaults/main.yml` (`crowdsec_version`, `crowdsec_firewall_bouncer_version`) and updated on the next run.
- **Updates**: there are no automatic updates. Arch Linux has no separate security updates and an unattended full upgrade can need manual steps, so each playbook run upgrades the whole system (`pacman -Syu`). Run it regularly.
- **Logs**: CrowdSec and the firewall bouncer log to the journal, which the `system` role limits in size.
- Needs the `community.general` collection on the Ansible computer (part of the `ansible` package; with `ansible-core` only: `ansible-galaxy collection install community.general`).

Moving the VPS to another system: install the new system, keep the inventory entry, run the playbook. The server creates new tunnel keys, tokens and the bouncer key and passes them to the client in the same run; Caddy requests new certificates. Only a CrowdSec Console enrollment has to be repeated.

## What happens on every run

1. **Preflight checks** (before anything changes): Debian, Ubuntu or Arch Linux (x86_64), `rathole_role` is `server` or `client`, `enable_wildcard` has `enable_cloudflare`, `cloudflare_api_token` is set when Cloudflare is enabled, `enable_crowdsec_import` has `enable_crowdsec`, a server in traditional mode has at least one site. With `tunnel_services`: `tunnel_id` is set, the tuple has one server and at most one client, service names are unique, each `bind_addr` and `type` is used once (`0.0.0.0:<port>` counts for every address on that port), both Noise keys are set together, and no legacy Rathole or Caddy site variables are mixed in. The roles also check that `rathole_server_config` / `rathole_client_config` exist (legacy), that the CPU architecture is supported and that the import password is set.
2. **System upgrade**: `apt upgrade` (mode `apt_upgrade_mode`) and `autoremove`; on Arch Linux `pacman -Syu`, and with a new kernel a reboot right away (if `enable_auto_reboot` is true), because Arch Linux removes the modules of the running kernel that the firewall needs.
3. **Roles**: `system`, then on the server `caddy` (with `go_lang` and `xcaddy`), `crowdsec`, `crowdsec_import`, `rathole` on both hosts, and `firewall` on the server if enabled.
4. **Reboot** if an upgrade requires it (`/var/run/reboot-required`; on Arch Linux a new kernel) and `enable_auto_reboot` is true.

Hosts are processed one at a time and the play stops on the first error. Run single parts with tags, for example `./scripts/run-playbook.sh --no-vault --tags caddy`. Tags: `system`, `caddy`, `crowdsec`, `crowdsec_import`, `rathole`, `firewall`, `reboot`, `cleanup`. The `firewall` tag needs `rathole` too (`--tags rathole,firewall`).

## Caddy build

Caddy is built on the server with xcaddy, because the plugins are not in the stock binary. The plugin list follows the flags:

| Plugin                                  | Included when                                                         |
| --------------------------------------- | --------------------------------------------------------------------- |
| CrowdSec bouncer (HTTP, layer4, AppSec) | `enable_crowdsec`                                                     |
| caddy-ratelimit                         | `enable_rate_limit`                                                   |
| Cloudflare DNS                          | `enable_cloudflare`                                                   |
| Coraza WAF                              | `enable_coraza_waf` or any site with a `coraza_mode` other than `off` |
| anything in `caddy_plugins`             | always (default: empty list)                                          |

Caddy is only rebuilt when `caddy_version` or the plugin list changes. The Caddyfile is validated before it is written and Caddy is reloaded, not restarted.

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

Audit logs (relevant events only, no bodies) are written to `/var/log/caddy/coraza/modsec_<site>.log` and rotated by `/etc/logrotate.d/caddy-coraza` (10 MB, 3 rotations). They are kept outside `/var/log/caddy/*.log`, which CrowdSec parses.

## CrowdSec

With `enable_crowdsec: true` the server gets the CrowdSec engine, the firewall bouncer (iptables; nftables on Arch Linux), the Caddy collection, AppSec (virtual patching, generic rules, HTTP CVEs) and the Caddy bouncer. The database is flushed (5000 alerts, 7 days) and the service is limited to 400 MB RAM.

Failed logins are detected without any setup. CrowdSec reads the Caddy access logs and bans an IP after 5 failed `POST`s (`400`, `401`, `403`) to a login-like path (`login`, `sign-in`, `auth`, `token`); one attempt is forgotten per minute. A successful login on the same path resets the count, so users who retry after a dropped connection are not banned. Apps that answer a wrong password with `200` or a redirect cannot be told apart from a successful login in the access log. Turn it off with `crowdsec_login_detection: false`; check with `sudo cscli alerts list`.

Normal use of common self-hosted apps does not get users banned: the official CrowdSec whitelists for Nextcloud, Jellyfin, Jellyseerr, Overseerr and a few others are installed (`crowdsec_hub_whitelists`), and a `POST` answered with `401` outside a login path counts as an expired session, not as an attack. The package's `crowdsec-hubupdate.timer` updates collections and whitelists daily.

`enable_crowdsec_import: true` adds [crowdsec-blocklist-import](https://github.com/wolffcatskyy/crowdsec-blocklist-import), which imports 28+ public feeds (IPsum, Spamhaus DROP, Blocklist.de, Firehol, Abuse.ch, DShield, Tor exit nodes and others) every hour:

- installed with pipx into `/opt/crowdsec-blocklist-import`, owned by root, version pinned by `crowdsec_import_version`
- runs as the system user `crowdsec-import` from a sandboxed systemd service and timer
- creates its own LAPI machine and bouncer, with a generated password (or `crowdsec_machine_password`)
- feeds can be switched off one by one, e.g. `crowdsec_enable_tor: false`; all options and their defaults are in `roles/crowdsec_import/defaults/main.yml`

## Firewall

With `enable_firewall: true` the server drops all incoming connections except:

- SSH: every port `sshd` listens on (including `ListenAddress` with its own port), `ansible_port` and the port Ansible is connected on, so a non-default port set only in `~/.ssh/config` is kept open too
- 80/tcp, 443/tcp and 443/udp (HTTP/3) for Caddy (`firewall_web_ports: false` closes them)
- the Rathole port and services with a public `bind_addr`, e.g. `0.0.0.0:30000`
- `firewall_allowed_tcp_ports` / `firewall_allowed_udp_ports`

Use it if the provider firewall is not used or not trusted. The home server (client) is not touched. The rules live in their own nftables table (`inet webguard`, file `/etc/nftables.d/webguard.nft`), loaded at boot by `webguard-firewall.service`, so the CrowdSec bouncer keeps working. When the rules change, or are no longer loaded, a timer removes them again after `firewall_rollback_seconds` (120) unless Ansible can open a new SSH connection, and they are then not loaded at boot either, so a mistake does not lock you out.

To remove the firewall, set `enable_firewall: false` and run the playbook: it deletes the table, the boot unit and the rules file. The ICMP rule uses protocol numbers, so minimal images without `netbase` (`/etc/protocols`) work too. On container VPS (LXC, OpenVZ) without their own kernel, nftables may not be available; the rules are checked with `nft -c` before anything is loaded.

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
- The build runs with one compile job and a low GC target (`caddy_build_jobs`, `caddy_build_gogc`) to fit into 2 GB RAM. On 2 GB hosts, set `system_swap_enabled: true` as a safety margin.
- Steady state limits: CrowdSec 400 MB, blocklist import 300 MB, Rathole 256 MB (systemd `MemoryMax`), journald 200 MB on disk.

## Updating

Pinned versions are role defaults (`roles/<role>/defaults/main.yml`) and can be overridden in `group_vars/all.yml`, `group_vars/tunnel_<name>.yml` or `host_vars/<host>.yml`, without editing role code:

| Variable                            | Component                 |
| ----------------------------------- | ------------------------- |
| `caddy_version`                     | Caddy (triggers rebuild)  |
| `go_lang_version`                   | Go toolchain              |
| `xcaddy_version`                    | xcaddy                    |
| `rathole_version`                   | Rathole                   |
| `crowdsec_import_version`           | crowdsec-blocklist-import |
| `crowdsec_version`                  | CrowdSec                  |
| `crowdsec_firewall_bouncer_version` | CrowdSec firewall bouncer |

Then run the playbook again. System packages are updated on every run; CrowdSec and its firewall bouncer stay at these versions (on Debian and Ubuntu with an APT pin, so `apt upgrade` and unattended-upgrades leave them alone) until the version changes.

With the [Renovate](https://github.com/apps/renovate) app installed on the repository, `renovate.json` opens a pull request against `develop` whenever one of these versions, a GitHub Action or a pre-commit hook has a new release (weekly, Monday morning). A version set in your own files overrides the role default, so remove such overrides to follow these updates.

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

| Problem                      | Check                                                                      |
| ---------------------------- | -------------------------------------------------------------------------- |
| Host key verification failed | `ssh` to the host once and accept the fingerprint                          |
| Preflight assertion fails    | The message names the missing or conflicting variable                      |
| Service won't start          | `sudo journalctl -u <service> -n 50`                                       |
| Caddy gets no certificate    | DNS points to the server? Ports 80/443 open? Cloudflare token permissions? |
| Caddyfile validation fails   | Run with `-e caddy_no_log=false` to see the error                          |
| Rathole tunnel down          | Client reaches server port? Service names, tokens and keys match?          |
| Rathole permission denied    | Referenced files under `/home`? Move them, e.g. to `/etc/rathole`          |

## Directory structure

```
├── ansible.cfg
├── inventory.example.ini       # Copy to inventory.ini
├── site.yml                    # Main playbook (preflight, upgrade, roles, reboot)
├── group_vars/
│   ├── all.example.yml         # Copy to all.yml: feature flags
│   └── tunnel.example.yml      # Copy to tunnel_<name>.yml: one tuple
├── host_vars/                  # Optional per-host overrides
├── tasks/global_defaults.yml   # Defaults when group_vars/all.yml is missing
├── tasks/preflight.yml         # Configuration checks, also run on the examples
├── tests/                      # Derivation tests (tests/run.sh)
├── roles/
│   ├── system/                 # journald limit, optional swap, security updates
│   ├── caddy/                  # Caddy build, Caddyfile, service
│   ├── go_lang/                # Go toolchain for the Caddy build
│   ├── xcaddy/                 # Caddy builder
│   ├── crowdsec/               # CrowdSec engine, AppSec, bouncers
│   ├── crowdsec_import/        # Blocklist importer
│   ├── python/                 # pipx for the importer
│   ├── rathole/                # Tunnel server and client
│   └── firewall/               # Optional nftables firewall on the server
└── scripts/run-playbook.sh     # Wrapper with vault options
```

## License

MIT, see [LICENSE](LICENSE).
