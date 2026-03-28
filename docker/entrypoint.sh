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

# --- Fix permissions and start server ---
if [ "$(id -u)" = "0" ]; then
  # Ensure the paperclip directory is owned by node user
  mkdir -p /paperclip
  chown -R node:node /paperclip

  # Run the server as node user
  exec gosu node node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
else
  # Already running as non-root, just start the server
  exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
fi
