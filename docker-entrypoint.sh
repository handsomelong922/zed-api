#!/bin/sh
set -eu

cd /data
rm -f setup-complete.flag

# 1Panel exposes exactly one container port: 8001. On a fresh install the
# browser-only login helper owns that port directly and serves /login.
if [ ! -s accounts.json ]; then
  echo "[entrypoint] no account configured; open /login on the mapped service port"
  /usr/local/bin/zed2api-setup 8001
  rm -f setup-complete.flag
fi

# The upstream program intentionally binds loopback only. Keep that native
# safety behavior unchanged, and bridge the single Docker-facing port to an
# internal loopback listener. No second port needs to be exposed or configured
# in 1Panel.
/usr/local/bin/zed2api serve 8002 &
api_pid=$!
socat TCP-LISTEN:8001,reuseaddr,fork,bind=0.0.0.0 TCP:127.0.0.1:8002 &
proxy_pid=$!

cleanup() {
  kill "$proxy_pid" "$api_pid" 2>/dev/null || true
  wait "$proxy_pid" "$api_pid" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

while kill -0 "$api_pid" 2>/dev/null && kill -0 "$proxy_pid" 2>/dev/null; do
  sleep 2
done

exit 1
