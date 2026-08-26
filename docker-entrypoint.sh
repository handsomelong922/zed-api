#!/bin/sh
set -eu

cd /data
rm -f setup-complete.flag

# 1Panel exposes exactly one container port: 8001. On a fresh install the
# browser-only login helper owns that port directly and serves /login.
#
# Do not treat a merely non-empty accounts.json as configured. Existing
# volumes may contain {"accounts":{}} (or another file that parses to zero
# accounts), which previously skipped setup and started the API with 0 accounts.
needs_setup=0
if [ ! -s accounts.json ]; then
  needs_setup=1
elif /usr/local/bin/zed2api accounts 2>&1 | grep -q '^No accounts\.'; then
  needs_setup=1
fi

if [ "$needs_setup" -eq 1 ]; then
  echo "[entrypoint] no account configured; open /login on the mapped service port"
  /usr/local/bin/zed2api-setup 8001
  rm -f setup-complete.flag
fi

# The Docker build is compiled to listen on 0.0.0.0:8001, so no additional
# internal/external port and no forwarding process are needed.
exec /usr/local/bin/zed2api serve 8001
