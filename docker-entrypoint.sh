#!/bin/sh
set -eu

cd /data
rm -f setup-complete.flag

# 1Panel/Docker deployments expose exactly one container port. During first
# run the setup helper temporarily owns port 8001 and serves /login. After an
# account is imported it exits, then the normal API takes over the same port.
if [ ! -s accounts.json ]; then
  echo "[entrypoint] no account configured; open /login on the mapped service port"
  /usr/local/bin/zed2api-setup 8001
  rm -f setup-complete.flag
fi

exec /usr/local/bin/zed2api serve 8001
