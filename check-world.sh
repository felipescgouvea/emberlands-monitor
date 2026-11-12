#!/usr/bin/env bash
# Is the world up, seen from outside? Fails (exit 1, a line starting with DOWN) when any of these is wrong:
#   1. the game port answers with TLS and shows a certificate the app pins (a player could log in);
#   2. the board answers on its HTTP port (the website's ranking, and the app handed out by hand);
#   3. the board is fresh: the world's own loop rewrites it every minute, so an old one means the world is frozen even
#      though its ports still answer.
# Where the address comes from, one place only: emberlands.serverHost / serverPort / updatePort in gradle.properties and
# the certificate in android/src/main/res/raw/server_cert.crt when run inside the game's repository; world.env and
# server_cert.crt next to this script in the monitor repository (scripts/monitor/publish.sh writes them from the former).
#   scripts/monitor/check-world.sh [--host H] [--port N] [--board-port N] [--cert FILE] [--tries 3] [--wait 30]
# Run by the scheduled monitor (docs/RUNBOOK.md, "Quem é avisado"); the owner can run it by hand from any computer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
host=""; port=""; board_port=""; cert=""; tries=3; wait=30
if [ -f "$here/world.env" ]; then
  . "$here/world.env"
  host="${WORLD_HOST:-}"; port="${WORLD_PORT:-}"; board_port="${WORLD_BOARD_PORT:-}"; cert="$here/server_cert.crt"
elif [ -f "$here/../../gradle.properties" ]; then
  prop() { sed -n "s/^emberlands\.$1=//p" "$here/../../gradle.properties" | tr -d '\r ' | head -1; }
  host="$(prop serverHost)"; port="$(prop serverPort)"; board_port="$(prop updatePort)"
  cert="$here/../../android/src/main/res/raw/server_cert.crt"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="$2" ;; --port) port="$2" ;; --board-port) board_port="$2" ;; --cert) cert="$2" ;;
    --tries) tries="$2" ;; --wait) wait="$2" ;;
    *) sed -n '2,11p' "$0"; exit 2 ;;
  esac
  shift 2
done
port="${port:-7777}"; board_port="${board_port:-8080}"
[ -n "$host" ] && [ -f "$cert" ] || { echo "DOWN: the monitor itself is misconfigured (host '$host', certificate '$cert')"; exit 1; }

# SHA-256 of every certificate in the pinned file (it may hold two while a certificate is being replaced).
pinned="$(awk '/BEGIN CERTIFICATE/ { c="" } { c = c $0 "\n" } /END CERTIFICATE/ { printf "%s", c | "openssl x509 -noout -fingerprint -sha256"; close("openssl x509 -noout -fingerprint -sha256") }' "$cert" | cut -d= -f2)"
[ -n "$pinned" ] || { echo "DOWN: the monitor itself is misconfigured (no certificate in $cert)"; exit 1; }

check() {
  local fp body updated age
  fp="$(timeout 20 openssl s_client -connect "$host:$port" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  [ -n "$fp" ] || { echo "DOWN: the game port $host:$port does not answer with TLS (nobody can log in)"; return 1; }
  printf '%s\n' "$pinned" | grep -qxF "$fp" || { echo "DOWN: $host:$port answers with a certificate the app does not accept ($fp)"; return 1; }
  body="$(curl -fsS -m 15 "http://$host:$board_port/board" 2>/dev/null)" || { echo "DOWN: the board http://$host:$board_port/board does not answer"; return 1; }
  updated="$(printf '%s' "$body" | grep -o '"updatedAt": *[0-9]*' | grep -o '[0-9]*$' | head -1)"
  [ -n "$updated" ] || { echo "DOWN: the board answers but is empty (the world has just started, or its loop never ran)"; return 1; }
  age=$(( $(date +%s) - updated / 1000 ))
  [ "$age" -le 600 ] || { echo "DOWN: the board is $(( age / 60 )) min old: the world's ports answer but the world is frozen"; return 1; }
  echo "OK: world at $host:$port (TLS, pinned certificate), board fresh (${age}s), $(printf '%s' "$body" | grep -o '"online": *[0-9]*' | grep -o '[0-9]*$' | head -1) online"
}

# A blip of the network between here and the world is not an outage: only DOWN several times in a row is.
for i in $(seq 1 "$tries"); do
  if msg="$(check)"; then echo "$msg"; exit 0; fi
  echo "$msg (try $i of $tries)"
  [ "$i" = "$tries" ] || sleep "$wait"
done
echo "DOWN: the world failed $tries checks in a row. What to do: docs/RUNBOOK.md, 'O mundo caiu'."
exit 1
