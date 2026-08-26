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

# The Docker build is compiled to listen on 0.0.0.0:8001, so no additional
# internal/external port and no forwarding process are needed.
exec /usr/local/bin/zed2api serve 8001
