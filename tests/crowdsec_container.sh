#!/bin/sh
# Runs inside the CrowdSec container for tests/check_crowdsec_docker.sh.
# /t holds the rendered config (etc/), the role's hub items and this script.
set -u

fail=0
ok() { echo "ok   $*"; }
bad() {
  echo "FAIL $*"
  fail=1
}
check() {
  desc=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# --- Configuration as the role writes it ---
mkdir -p /etc/crowdsec /var/lib/crowdsec/data /var/log/caddy
cp -a /staging/etc/crowdsec/. /etc/crowdsec/
cp -a /staging/var/lib/crowdsec/data/. /var/lib/crowdsec/data/
cp -a /t/etc/. /etc/crowdsec/
# Test only: LAPI on a free port, no metrics listener (host network)
cat >>/etc/crowdsec/config.yaml.local <<'EOF'
api:
  server:
    listen_uri: 127.0.0.1:18080
prometheus:
  enabled: false
EOF
# Test only: ntfy messages go to a local listener
sed -i 's|^url: .*|url: http://127.0.0.1:18099/|' /etc/crowdsec/notifications/ntfy.yaml
(while :; do printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n' | nc -l -p 18099 >>/tmp/ntfy.txt; done) &

# The hub fails now and then; retry like the role does
hub() {
  for _ in 1 2 3; do
    cscli "$@" >/tmp/hub.log 2>&1 && return
    sleep 5
  done
  tail -3 /tmp/hub.log
  return 1
}
hub hub update || bad "hub update"
while read -r collection; do
  hub collections install "$collection" || bad "install $collection"
done </t/collections.txt
while read -r parser; do
  hub parsers install "$parser" || bad "install $parser"
done </t/hub_whitelists.txt

check "configuration loads (crowdsec -t)" crowdsec -t
scenarios=$(cscli scenarios list -o json 2>/dev/null)
for name in crowdsecurity/http-generic-bf local/login-bf; do
  case $scenarios in
    *"\"$name\""*) ok "scenario $name installed" ;;
    *) bad "scenario $name installed" ;;
  esac
done

# --- Engine with LAPI ---
cscli machines add -a --force >/dev/null 2>&1
touch /var/log/caddy/test.access.log
crowdsec >/tmp/crowdsec.log 2>&1 &
i=0
until cscli lapi status >/dev/null 2>&1; do
  i=$((i + 1))
  if [ $i -gt 60 ]; then
    bad "LAPI starts"
    tail -20 /tmp/crowdsec.log
    exit 1
  fi
  sleep 1
done
ok "LAPI starts"
sleep 3 # acquisition picks up the log file

# --- Bouncer key check as in roles/crowdsec/tasks/main.yml (HEAD /v1/decisions) ---
key=abcdefghijklmnopqrstuvwxyz012345
cscli bouncers add caddy-bouncer -k "$key" >/dev/null 2>&1
# Keep stdin open: on an early EOF from nc, the LAPI cancels the request and answers 403
http() { (printf "$2"; sleep 1) | nc 127.0.0.1 "$1" | head -1; }
status() { http 18080 "HEAD /v1/decisions HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: ansible-httpget\r\nX-Api-Key: $1\r\nConnection: close\r\n\r\n"; }
case $(status "$key") in *" 200 "*) ok "valid bouncer key: 200" ;; *) bad "valid bouncer key: 200" ;; esac
case $(status wrongkey) in *" 403 "*) ok "wrong bouncer key: 403" ;; *) bad "wrong bouncer key: 403" ;; esac

# --- AppSec as the Caddy bouncer calls it ---
appsec() {
  http 17422 "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Crowdsec-Appsec-Ip: 198.51.100.50\r\nX-Crowdsec-Appsec-Uri: $1\r\nX-Crowdsec-Appsec-Host: app.example.com\r\nX-Crowdsec-Appsec-Verb: GET\r\nX-Crowdsec-Appsec-Api-Key: $key\r\nX-Crowdsec-Appsec-User-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
}
case $(appsec /index.html) in *" 200 "*) ok "AppSec allows a normal request" ;; *) bad "AppSec allows a normal request" ;; esac
case $(appsec /.env) in *" 403 "*) ok "AppSec blocks /.env (virtual patching)" ;; *) bad "AppSec blocks /.env (virtual patching)" ;; esac

# --- Caddy access log, read through the role's acquisition ---
n=0
log() {
  n=$((n + 1))
  printf '{"level":"info","ts":%s.%03d,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"%s","remote_port":"51234","client_ip":"%s","proto":"HTTP/2.0","method":"%s","host":"app.example.com","uri":"%s","headers":{"User-Agent":["Mozilla/5.0"]}},"bytes_read":30,"duration":0.01,"size":20,"status":%s,"resp_headers":%s}\n' \
    "$(date +%s)" "$n" "$1" "$1" "$2" "$3" "$4" "${5:-{\}}" >>/var/log/caddy/test.access.log
}
for i in 1 2 3 4 5 6 7 8; do log 198.51.100.7 POST /api/auth/login 400; done
for s in 400 400 400 400 302 400 400 400 400; do log 198.51.100.8 POST /api/auth/login "$s"; done
for i in 1 2 3 4 5 6 7 8; do
  log 198.51.100.9 POST /api/auth/login 400
  log 198.51.100.9 POST /api/auth/logout 200
done
for i in 1 2 3 4 5 6 7 8; do log 198.51.100.10 POST /api/items 400; done
for i in 1 2 3 4 5 6 7 8; do log 198.51.100.20 POST /api/auth/login 400; done
# Normal use of common self-hosted apps that the stock scenarios ban
for i in $(seq 1 15); do log 198.51.100.31 GET "/Items/f6e5d4c3b2a1$i/Images/Thumb?fillWidth=400" 404; done
for i in $(seq 1 8); do log 198.51.100.32 POST /Sessions/Playing/Progress 401; done
for i in $(seq 1 8); do log 198.51.100.33 POST /Sessions/Playing/Progress 403; done
for i in $(seq 1 30); do log 198.51.100.34 PROPFIND "/remote.php/dav/files/user/folder$i/new$i.txt" 404; done
for i in $(seq 1 30); do log 198.51.100.35 GET "/core/preview?fileId=$i&x=250&y=250" 404; done
for i in $(seq 1 60); do log 198.51.100.36 GET "/api/v1/movie/$((1000 + i))" 200; done
for i in $(seq 1 30); do log 198.51.100.37 GET "/library/metadata/$((2000 + i))/thumb/1700000000" 404; done
# Still detected: basic auth guessing, probing for unknown paths
for i in 1 2 3 4 5 6 7 8; do log 198.51.100.40 POST /api/upload 401 '{"Www-Authenticate":["Basic realm=\"x\""]}'; done
for i in $(seq 1 30); do log 198.51.100.41 GET "/backup$i.zip" 404; done
sleep 10

decisions=$(cscli decisions list -o raw 2>/dev/null)
alerts=$(cscli alerts list -o raw -l 0 2>/dev/null)
has_alert() { echo "$alerts" | grep -q ",Ip,$1,$2,"; }
has_ban() { echo "$decisions" | grep -q ",Ip:$1,local/login-bf,ban,"; }
no_decision() { ! echo "$decisions" | grep -q ":$1,"; }
check "brute force on a login path: ban" has_ban 198.51.100.7
check "retry after a successful login: no ban" no_decision 198.51.100.8
check "reset through another endpoint: still ban" has_ban 198.51.100.9
check "failed POSTs elsewhere: no ban" no_decision 198.51.100.10
check "DDNS whitelist: no ban" no_decision 198.51.100.20
check "Jellyfin missing thumbnails: no ban" no_decision 198.51.100.31
check "client with an expired session (401): no ban" no_decision 198.51.100.32
check "Jellyfin progress reports (403): no ban" no_decision 198.51.100.33
check "Nextcloud WebDAV sync: no ban" no_decision 198.51.100.34
check "Nextcloud previews: no ban" no_decision 198.51.100.35
check "Seerr browsing: no ban" no_decision 198.51.100.36
check "Plex missing artwork: no ban" no_decision 198.51.100.37
check "basic auth guessing: ban" has_alert 198.51.100.40 crowdsecurity/http-generic-bf
check "probing unknown paths: ban" has_alert 198.51.100.41 crowdsecurity/http-probing
# profiles.yaml with duration_expr: first ban lasts 4h
# ntfy message for the login ban
# (toJson escapes ">" as >)
ntfy=$(grep -F '198.51.100.7 banned' /tmp/ntfy.txt | sed 's/\\u003e/>/g')
has() { echo "$ntfy" | grep -qF "$1"; }
check "ntfy: service in the title" has '"title":"[app] 198.51.100.7 banned"'
check "ntfy: rule" has '[!] Rule: local/login-bf'
check "ntfy: request" has '> Request: 6x POST /api/auth/login (400)'
check "ntfy: unban command" has '$ cscli decisions delete --ip 198.51.100.7'
check "ntfy: topic" has '"topic":"test"'
check "first ban lasts 4h" sh -c "echo '$decisions' | grep ',Ip:198.51.100.7,' | grep -q ',3h59m'"
check "no fatal errors" sh -c "! grep -q 'level=fatal' /tmp/crowdsec.log"

[ $fail -eq 0 ] || { tail -20 /tmp/crowdsec.log; cat /tmp/ntfy.txt; }
exit $fail
