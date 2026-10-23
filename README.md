# Ansible-Rathole-WebGuard

[![Lint Ansible](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml/badge.svg)](https://github.com/chrisvgt/ansible-rathole-webguard/actions/workflows/lint.yml)

Ansible playbook that publishes services from a home network through a small VPS:

- **Rathole** tunnels the services from your LAN (client) to the VPS (server).
- **Caddy** on the VPS terminates TLS and reverse-proxies to the tunnel.
- **CrowdSec** (optional, on by default) blocks bad IPs and inspects requests (AppSec).
- **Coraza WAF**, **Cloudflare DNS-01**, wildcard certificates and blocklist import are opt-in.

Supported: Debian (bullseye, bookworm) and Ubuntu (focal, jammy, noble) on x86_64, arm64 and armv6/armv7. The playbook stops on other OS families. Arch Linux support may follow later.

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

The group name (`tunnel_home`) selects `group_vars/tunnel_home.yml`. The client connects to the server's `ansible_host`; set `rathole_public_addr` in the tuple file if the client must use another address. List the server first: on a new tuple the server creates the tunnel keys.

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

From this, the playbook builds the Rathole server and client configuration and the Caddy site. See [Services](#services) for all keys.

### 4. Secrets and run

Put the secrets in place (see [Secrets](#secrets)), then:

```bash
./scripts/run-playbook.sh --no-vault   # secrets in plaintext, gitignored files
./scripts/run-playbook.sh              # secrets in Ansible Vault, prompts for the password
```

The script runs `ansible-playbook -i inventory.ini site.yml` with the matching vault option. Use `--vault-file <file>`, `--inventory <file>` or `--playbook <file>` to change the defaults.

Open these ports on the server: 80 and 443 (Caddy), and the Rathole port (`rathole_port`, default 2333).

### More tuples

Add another group to `inventory.ini`, add it to `[webservers:children]`, and copy `group_vars/tunnel.example.yml` to `group_vars/tunnel_<group>.yml` with its own `tunnel_id`.

## Secrets

| Variable                    | Vault name                          | Needed when                    |
| --------------------------- | ----------------------------------- | ------------------------------ |
| `crowdsec_api_key`          | `vault_crowdsec_api_key`            | `enable_crowdsec: true`        |
| `crowdsec_enrollment_key`   | `vault_crowdsec_enrollment_key`     | optional, CrowdSec Console     |
| `crowdsec_machine_password` | `vault_crowdsec_machine_password`   | `enable_crowdsec_import: true` |
| `cloudflare_api_token`      | `vault_cloudflare_api_token_server` | `enable_cloudflare: true`      |

Generate random values with `head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32`.

The tunnel needs no secrets from you. On the first run the server creates a Noise key pair and a default token in `/etc/rathole/` (`noise.key`, `noise.pub`, `default_token`, readable by root and the `rathole` group only). The client reads the public key and the token from its server, also with `--limit <client>`. To keep existing values, set `rathole_noise_private_key`, `rathole_noise_public_key` and `rathole_default_token` in the tuple file. To rotate, delete the three files on the server and run the playbook for both hosts.

Two ways to store the other secrets:

**Plaintext (simple).** Replace each `"{{ vault_* }}"` in `group_vars/tunnel_<name>.yml` with the value itself and run `./scripts/run-playbook.sh --no-vault`. The file is gitignored.

**Ansible Vault.** Keep the `"{{ vault_* }}"` references and define the values in an encrypted file:

```bash
mkdir -p group_vars/webservers
ansible-vault create group_vars/webservers/vault.yml
```

```yaml
vault_crowdsec_api_key: "..."
vault_crowdsec_enrollment_key: "..."
vault_crowdsec_machine_password: "..."
vault_cloudflare_api_token_server: "..."
```

Run `./scripts/run-playbook.sh` (prompts) or `./scripts/run-playbook.sh --vault-file ~/.vault_pass`. Do not create a directory with the same name as one of your files (`group_vars/all/`, `group_vars/tunnel_home/`): Ansible then ignores the file of that name.

The Cloudflare token only needs to be set as `cloudflare_api_token`. Ansible writes it to `/etc/caddy/caddy.env` (root, mode 0600) on the server, and systemd passes it to Caddy. No manual env file is needed.

## Configuration

### Feature flags (`group_vars/all.yml`)

| Variable                 | Default       | Effect                                                                                            |
| ------------------------ | ------------- | ------------------------------------------------------------------------------------------------- |
| `enable_crowdsec`        | `true`        | CrowdSec engine, firewall bouncer, AppSec and the Caddy bouncer plugin                            |
| `enable_rate_limit`      | `true`        | Per-site rate limit (default 500 requests per minute per IP) and the ratelimit plugin             |
| `enable_cloudflare`      | `false`       | Cloudflare DNS-01 challenge for all certificates (plugin + `cloudflare_api_token`)                |
| `enable_wildcard`        | `false`       | One wildcard certificate per base domain, see [Services](#services). Requires `enable_cloudflare` |
| `enable_coraza_waf`      | `false`       | WAF for every site that does not set `coraza_mode` itself                                         |
| `coraza_mode_default`    | `recommended` | WAF mode used by `enable_coraza_waf`                                                              |
| `enable_crowdsec_import` | `false`       | Hourly import of public blocklists into CrowdSec. Requires `enable_crowdsec`                      |
| `enable_system_tuning`   | `true`        | `system` role: journald size limit, optional swap file                                            |
| `apt_upgrade_mode`       | `safe`        | `apt upgrade` mode on every run: `safe`, `full`, `dist`, `yes`, or `no` to skip                   |
| `enable_auto_reboot`     | `true`        | Reboot only if `/var/run/reboot-required` exists. `false` only reports a pending reboot           |

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

Keep `bind_addr` on `127.0.0.1` for web services, so they are only reachable through Caddy. Use `0.0.0.0:<port>` only for tunnel-only services that must be reachable directly (VPN, game servers). The same port may be used once for `tcp` and once for `udp`.

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

A service with several domains gets one site per domain, named `<name>_<domain>` (dots replaced by `_`). Site names are used for log files and rate limit zones.

WebSocket upgrades skip rate limiting, WAF and AppSec (they cannot inspect the stream); the CrowdSec IP check still applies.

### Legacy configuration

Configurations from older versions keep working: `rathole_server_config` / `rathole_client_config` and `caddy_sites` / `wildcard_sites` in `host_vars/<host>.yml`, with `rathole_role` per host. A host uses either `tunnel_services` or these variables, not both; the preflight check stops otherwise. To migrate, move the services of both hosts into one `tunnel_services` list and keep the existing keys and token with `rathole_noise_private_key`, `rathole_noise_public_key` and `rathole_default_token`, so the running tunnel does not change.

### Small host tuning (`system` role)

| Variable                  | Default     | Effect                                         |
| ------------------------- | ----------- | ---------------------------------------------- |
| `system_journald_max_use` | `200M`      | Cap for persistent journal logs                |
| `system_swap_enabled`     | `false`     | Create and enable a swap file                  |
| `system_swap_file`        | `/swapfile` | Swap file path                                 |
| `system_swap_size`        | `1G`        | Swap size (not resized once created)           |
| `system_swappiness`       | `10`        | `vm.swappiness`, set only when swap is enabled |

The role runs before Caddy, so swap is available for the Caddy build.

## What happens on every run

1. **Preflight checks** (before anything changes): Debian-based OS, `rathole_role` is `server` or `client`, `enable_wildcard` has `enable_cloudflare`, `cloudflare_api_token` is set when Cloudflare is enabled, `enable_crowdsec_import` has `enable_crowdsec`. The roles also check that `rathole_server_config` / `rathole_client_config` exist, that the CPU architecture is supported and that the import password is set.
2. **System upgrade**: `apt upgrade` (mode `apt_upgrade_mode`) and `autoremove`.
3. **Roles**: `system`, then on the server `caddy` (with `go_lang` and `xcaddy`), `crowdsec`, `crowdsec_import`, and `rathole` on both hosts.
4. **Reboot** if `/var/run/reboot-required` exists and `enable_auto_reboot` is true.

Hosts are processed one at a time and the play stops on the first error. Run single parts with tags, for example `ansible-playbook -i inventory.ini site.yml --tags caddy`. Tags: `system`, `caddy`, `crowdsec`, `crowdsec_import`, `rathole`, `reboot`, `cleanup`.

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

With `enable_crowdsec: true` the server gets the CrowdSec engine, the iptables firewall bouncer, the Caddy collection, AppSec (virtual patching, generic rules, HTTP CVEs) and the Caddy bouncer. The database is flushed (5000 alerts, 7 days) and the service is limited to 400 MB RAM.

`enable_crowdsec_import: true` adds [crowdsec-blocklist-import](https://github.com/wolffcatskyy/crowdsec-blocklist-import), which imports 28+ public feeds (IPsum, Spamhaus DROP, Blocklist.de, Firehol, Abuse.ch, DShield, Tor exit nodes and others) every hour:

- installed with pipx into `/opt/crowdsec-blocklist-import`, owned by root, version pinned by `crowdsec_import_version`
- runs as the system user `crowdsec-import` from a sandboxed systemd service and timer
- creates its own LAPI machine and bouncer; you only set `crowdsec_machine_password`
- feeds can be switched off one by one (`crowdsec_enable_*`, see `group_vars/tunnel.example.yml`)

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

| Variable                  | Component                 |
| ------------------------- | ------------------------- |
| `caddy_version`           | Caddy (triggers rebuild)  |
| `go_lang_version`         | Go toolchain              |
| `xcaddy_version`          | xcaddy                    |
| `rathole_version`         | Rathole                   |
| `crowdsec_import_version` | crowdsec-blocklist-import |

Then run the playbook again. CrowdSec and system packages are updated by `apt` on every run.

### Upgrading existing hosts

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
├── tests/                      # Derivation tests (tests/run.sh)
├── roles/
│   ├── system/                 # journald limit, optional swap
│   ├── caddy/                  # Caddy build, Caddyfile, service
│   ├── go_lang/                # Go toolchain for the Caddy build
│   ├── xcaddy/                 # Caddy builder
│   ├── crowdsec/               # CrowdSec engine, AppSec, bouncers
│   ├── crowdsec_import/        # Blocklist importer
│   ├── python/                 # pipx for the importer
│   └── rathole/                # Tunnel server and client
└── scripts/run-playbook.sh     # Wrapper with vault options
```

## License

MIT, see [LICENSE](LICENSE).
