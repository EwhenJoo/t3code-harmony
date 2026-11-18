#!/usr/bin/env bash
# Installs the push helper on a Linux machine from a bundle made by `pack-for-linux.mjs`:
#   app/                    the helper (bin, src, node_modules)
#   seed/config.json        listen 127.0.0.1:8790, a bind key, and the phones already bound elsewhere
#   seed/service-account.json   the Push Kit service account (deleted after import)
# It watches only this machine's T3 (over 127.0.0.1), so nothing T3-related crosses the network.
# Secrets are never printed.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/.local/share/t3-push"
APP="$BASE/app"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/t3-push"
PROJECT_ID="${T3_PUSH_PROJECT_ID:-101653523865618575}"
TS_SOCKET="${TS_SOCKET:-}"
if [ -z "$TS_SOCKET" ] && [ -S "$HOME/.local/share/tailscale/tailscaled.sock" ]; then
  TS_SOCKET="$HOME/.local/share/tailscale/tailscaled.sock"
fi
ts() { if [ -n "$TS_SOCKET" ]; then tailscale --socket="$TS_SOCKET" "$@"; else tailscale "$@"; fi; }

step() { printf '\n== %s\n' "$*"; }

step "Node.js 22+"
NODE="$(command -v node || true)"
major() { "$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [ -z "$NODE" ] || [ "$(major "$NODE")" -lt 22 ]; then
  NODE="$BASE/node/bin/node"
  if [ ! -x "$NODE" ] || [ "$(major "$NODE")" -lt 22 ]; then
    VER="v22.20.0"
    ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=x64;; aarch64) ARCH=arm64;; esac
    TAR="node-$VER-linux-$ARCH.tar.xz"
    mkdir -p "$BASE"
    for MIRROR in "https://npmmirror.com/mirrors/node" "https://nodejs.org/dist"; do
      if curl -fsSL --max-time 300 -o "$BASE/$TAR" "$MIRROR/$VER/$TAR"; then break; fi
    done
    rm -rf "$BASE/node" && mkdir -p "$BASE/node"
    tar -xJf "$BASE/$TAR" -C "$BASE/node" --strip-components=1
    rm -f "$BASE/$TAR"
  fi
fi
echo "node: $NODE ($("$NODE" -v))"

step "Helper files"
rm -rf "$APP" && mkdir -p "$APP"
cp -r "$SRC/app/." "$APP/"
HELPER=("$NODE" "$APP/bin/t3-push.mjs")

step "Config"
mkdir -p "$CONF" && chmod 700 "$CONF"
if [ ! -f "$CONF/config.json" ]; then
  install -m 600 "$SRC/seed/config.json" "$CONF/config.json"
  echo "seeded $CONF/config.json"
else
  echo "keeping existing $CONF/config.json"
fi
"${HELPER[@]}" setup --project-id "$PROJECT_ID" --service-account "$SRC/seed/service-account.json"
rm -f "$SRC/seed/service-account.json"

step "Pair with this machine's T3"
RUNTIME="${T3CODE_HOME:-$HOME/.t3}/userdata/server-runtime.json"
read -r T3_VERSION T3_PORT < <("$NODE" -e 'const r=require(process.argv[1]);console.log(r.serverVersion+" "+r.port)' "$RUNTIME")
T3_CLI="${T3CODE_HOME:-$HOME/.t3}/runtime/versions/$T3_VERSION/t3"
[ -x "$T3_CLI" ] || T3_CLI="$(command -v t3)"
PAIR_URL="$("$T3_CLI" auth pairing create --ttl 10m --label 推送小助手 --base-url "http://127.0.0.1:$T3_PORT" --json \
  | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=s.match(/\{[\s\S]*\}/);process.stdout.write(JSON.parse(m[0]).pairUrl)})')"
"${HELPER[@]}" add "$PAIR_URL"
unset PAIR_URL

step "Start at boot"
if ! "${HELPER[@]}" install; then
  echo "systemd user service unavailable; using cron @reboot + nohup instead"
  LINE="@reboot $NODE $APP/bin/t3-push.mjs run >> $CONF/t3-push.out.log 2>&1"
  ( crontab -l 2>/dev/null | grep -v 't3-push.mjs run' ; echo "$LINE" ) | crontab -
  pkill -f "$APP/bin/t3-push.mjs run" 2>/dev/null || true
  setsid nohup "$NODE" "$APP/bin/t3-push.mjs" run >> "$CONF/t3-push.out.log" 2>&1 < /dev/null &
fi

step "Tailnet-only forward for the bind endpoint (8790)"
ts serve --bg --tcp=8790 tcp://127.0.0.1:8790
ts serve status || true

step "Check"
sleep 8
"${HELPER[@]}" list | sed -n '1,20p'
"${HELPER[@]}" test || true
tail -n 8 "$CONF/t3-push.log" 2>/dev/null || true
echo "DONE"
