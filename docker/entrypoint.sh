#!/bin/bash
set -e

CONFIG_DIR="/paperclip/instances/default"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# --- Auto-generate config.json if it doesn't exist ---
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[entrypoint] No config found at ${CONFIG_FILE}, generating one..."
  mkdir -p "$CONFIG_DIR"

  # Resolve the public base URL
  # Railway provides RAILWAY_PUBLIC_DOMAIN automatically
  if [ -n "$PAPERCLIP_PUBLIC_URL" ]; then
    PUBLIC_URL="$PAPERCLIP_PUBLIC_URL"
  elif [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
  else
    PUBLIC_URL=""
  fi

  # Determine auth config based on whether we have a public URL
  if [ -n "$PUBLIC_URL" ]; then
    AUTH_BLOCK="\"baseUrlMode\": \"explicit\", \"publicBaseUrl\": \"${PUBLIC_URL}\""
  else
    AUTH_BLOCK="\"baseUrlMode\": \"auto\""
  fi

  cat > "$CONFIG_FILE" << EOFCONFIG
{
  "\$meta": {
    "version": 1,
    "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
    "source": "configure"
  },
  "database": {
    "mode": "embedded-postgres"
  },
  "logging": {
    "mode": "file",
    "logDir": "/paperclip/instances/default/logs"
  },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "public",
    "host": "0.0.0.0",
    "port": 3100
  },
  "auth": {
    ${AUTH_BLOCK}
  }
}
EOFCONFIG

  echo "[entrypoint] Config generated at ${CONFIG_FILE}"
fi

# --- Auto-generate BETTER_AUTH_SECRET if not set ---
# Persist it to a file on the volume so it survives redeploys
AUTH_SECRET_FILE="/paperclip/.auth_secret"
if [ -z "$BETTER_AUTH_SECRET" ]; then
  if [ -f "$AUTH_SECRET_FILE" ]; then
    export BETTER_AUTH_SECRET="$(cat "$AUTH_SECRET_FILE")"
    echo "[entrypoint] Loaded BETTER_AUTH_SECRET from persistent storage"
  else
    export BETTER_AUTH_SECRET="$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')"
    echo "$BETTER_AUTH_SECRET" > "$AUTH_SECRET_FILE"
    echo "[entrypoint] Generated and persisted BETTER_AUTH_SECRET"
  fi
fi

# --- Auto-set PAPERCLIP_PUBLIC_URL from Railway domain ---
if [ -z "$PAPERCLIP_PUBLIC_URL" ] && [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
  export PAPERCLIP_PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
  echo "[entrypoint] Auto-detected PAPERCLIP_PUBLIC_URL=${PAPERCLIP_PUBLIC_URL}"
fi

# --- Auto-bootstrap CEO invite on first deploy ---
auto_bootstrap() {
  local BOOTSTRAP_MARKER="/paperclip/.bootstrapped"
  if [ -f "$BOOTSTRAP_MARKER" ]; then
    return
  fi

  echo "[entrypoint] First deploy detected — will auto-bootstrap CEO invite after server starts..."
  
  # Wait for the server to be healthy
  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:3100/api/health > /dev/null 2>&1; then
      echo "[entrypoint] Server is healthy, generating CEO bootstrap invite..."
      cd /app
      if [ "$(id -u)" = "0" ]; then
        gosu node node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo --force 2>&1 || true
      else
        node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo --force 2>&1 || true
      fi
      touch "$BOOTSTRAP_MARKER"
      echo "[entrypoint] ============================================="
      echo "[entrypoint] Check the logs above for your CEO invite URL!"
      echo "[entrypoint] ============================================="
      return
    fi
    sleep 2
  done
  echo "[entrypoint] WARNING: Server didn't become healthy in 120s, skipping auto-bootstrap"
}

# --- Fix permissions and start server ---
if [ "$(id -u)" = "0" ]; then
  mkdir -p /paperclip
  chown -R node:node /paperclip

  # Start auto-bootstrap in background (runs after server is healthy)
  auto_bootstrap &

  # Run the server as node user (exec replaces this process)
  exec gosu node node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
else
  auto_bootstrap &
  exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
fi
