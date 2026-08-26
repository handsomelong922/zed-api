#!/bin/sh
set -eu

cd /data
rm -f setup-complete.flag

# First-run setup for headless Docker/VPS deployments. The setup helper is
# intentionally started only while accounts.json is absent/empty, so port 8002
# disappears automatically after the first account is imported.
if [ ! -s accounts.json ]; then
  /usr/local/bin/zed2api-setup 8002 &
  setup_pid=$!

  /usr/local/bin/zed2api serve 8001 &
  api_pid=$!

  # Wait for browser-only setup to finish. Then restart the API once so its
  # in-memory account manager reloads the newly written accounts.json.
  wait "$setup_pid"
  kill "$api_pid" 2>/dev/null || true
  wait "$api_pid" 2>/dev/null || true
  rm -f setup-complete.flag
  exec /usr/local/bin/zed2api serve 8001
fi

exec /usr/local/bin/zed2api serve 8001
