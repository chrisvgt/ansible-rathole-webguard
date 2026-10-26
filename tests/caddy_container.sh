#!/bin/bash
# Runs inside the systemd container for tests/check_caddy_systemd.sh: installs
# the role's Caddy unit with a minimal site and checks Caddy works inside the
# sandbox. /t holds the unit, the Caddy binary and the role's paths.
set -u
. /t/paths.sh

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else
    echo "FAIL $1"
    fail=1
  fi
}

# --- Layout as the role creates it ---
useradd --system --no-create-home --shell /usr/sbin/nologin caddy
install -m 0755 /t/caddy "$install_path"
install -d -o root -g caddy -m 0750 "$(dirname "$config_file")"
install -d -o caddy -g caddy -m 0750 "$data_dir"
install -d -o caddy -g caddy -m 0755 "$log_dir"
install -d -o caddy -g caddy -m 0750 "$log_dir/coraza"
install -o root -g root -m 0600 /dev/null "$env_file"
cat >"$config_file" <<EOF
{
	skip_install_trust
}

https://localhost {
	tls internal
	log {
		format json
		output file $log_dir/test.access.log
	}
	respond "hello"
}
EOF
chgrp caddy "$config_file"
chmod 0640 "$config_file"
install -m 0644 /t/caddy.service /etc/systemd/system/caddy.service
systemctl daemon-reload
systemctl start caddy
sleep 3

# --- Caddy works inside the sandbox ---
pid=$(systemctl show -p MainPID --value caddy)
mount_mode() { awk -v p="$1" '$5 == p {print $6}' "/proc/$pid/mountinfo" | cut -d, -f1; }
check "caddy is active" "systemctl is-active caddy"
check "runs as the caddy user" "test \$(stat -c %U /proc/$pid) = caddy"
check "binds port 443 and answers over HTTPS" "curl -sk https://localhost/ | grep -q hello"
check "stores certificates in the data dir" "find $data_dir -name '*.crt' | grep -q ."
check "writes the access log" "grep -q '\"status\":200' $log_dir/test.access.log"
check "reloads" "systemctl reload caddy && sleep 2 && systemctl is-active caddy"

# --- Sandbox ---
check "root filesystem is read-only" "test \$(mount_mode /) = ro"
check "data dir is writable" "test \$(mount_mode $data_dir) = rw"
check "log dir is writable" "test \$(mount_mode $log_dir) = rw"
check "home directories are hidden" "test -n \"\$(mount_mode /home)\""
check "no permission errors" "! journalctl -u caddy --no-pager | grep -qiE 'permission denied|operation not permitted|read-only file system'"

[ $fail -eq 0 ] || journalctl -u caddy --no-pager | tail -20
exit $fail
