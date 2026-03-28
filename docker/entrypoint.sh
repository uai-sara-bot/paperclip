#!/bin/bash
set -e

CONFIG_DIR="/paperclip/instances/default"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# --- Auto-generate config.json if it doesn't exist or is incomplete ---
# Regenerate if config is missing embeddedPostgresDataDir (old format that causes data loss)
if [ -f "$CONFIG_FILE" ] && ! grep -q 'embeddedPostgresDataDir' "$CONFIG_FILE" 2>/dev/null; then
  echo "[entrypoint] Detected old config without explicit data paths, regenerating..."
  rm -f "$CONFIG_FILE"
  rm -f "/paperclip/.bootstrapped"
fi

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
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "/paperclip/instances/default/db",
    "embeddedPostgresPort": 54329,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "/paperclip/instances/default/data/backups"
    }
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
  },
  "storage": {
    "provider": "local_disk",
    "localDisk": {
      "baseDir": "/paperclip/instances/default/data/storage"
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "/paperclip/instances/default/secrets/master.key"
    }
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
        gosu node env HOME=/paperclip node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo --force 2>&1 || true
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

# --- Auto-install Claude native binary on first deploy ---
CLAUDE_NATIVE="/paperclip/.local/bin/claude"
if [ ! -f "$CLAUDE_NATIVE" ]; then
  echo "[entrypoint] Installing Claude Code native binary..."
  mkdir -p /paperclip/.local/bin
  if [ "$(id -u)" = "0" ]; then
    chown -R node:node /paperclip/.local
    gosu node env HOME=/paperclip claude install --yes 2>&1 || true
  else
    claude install --yes 2>&1 || true
  fi
  if [ -f "$CLAUDE_NATIVE" ]; then
    echo "[entrypoint] Claude native binary installed at ${CLAUDE_NATIVE}"
  fi
fi

# Ensure claude is always findable at /usr/local/bin/claude (symlink to native)
# 'claude install' removes the npm version from /usr/local/bin, so we restore access
if [ -f "$CLAUDE_NATIVE" ] && [ ! -f /usr/local/bin/claude ]; then
  ln -sf "$CLAUDE_NATIVE" /usr/local/bin/claude
  echo "[entrypoint] Symlinked /usr/local/bin/claude -> ${CLAUDE_NATIVE}"
fi

# --- Sync Claude credentials from any location to /paperclip/.claude ---
# Railway shell may save credentials to /root/.claude or /home/node/.claude
# The server (node user with HOME=/paperclip) looks in /paperclip/.claude
sync_claude_credentials() {
  local synced=false
  for src in /root/.claude /home/node/.claude; do
    if [ -d "$src" ] && [ -f "$src/.credentials.json" ] 2>/dev/null; then
      if [ "$src" != "/paperclip/.claude" ]; then
        mkdir -p /paperclip/.claude
        cp -a "$src/." /paperclip/.claude/ 2>/dev/null || true
        chown -R node:node /paperclip/.claude 2>/dev/null || true
        echo "[entrypoint] Synced Claude credentials from $src to /paperclip/.claude/"
        synced=true
      fi
    fi
  done
  # Also symlink so any future login from any HOME saves to the right place
  for link_src in /root/.claude /home/node/.claude; do
    if [ "$link_src" != "/paperclip/.claude" ] && [ ! -L "$link_src" ]; then
      rm -rf "$link_src" 2>/dev/null || true
      ln -sf /paperclip/.claude "$link_src" 2>/dev/null || true
    fi
  done
}
sync_claude_credentials

# Ensure PATH includes the local bin
export PATH="/paperclip/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# --- Fix permissions and start server ---
if [ "$(id -u)" = "0" ]; then
  mkdir -p /paperclip
  chown -R node:node /paperclip

  # Start auto-bootstrap in background (runs after server is healthy)
  auto_bootstrap &

  # Run the server as node user with HOME=/paperclip so all data paths resolve to the volume
  export HOME=/paperclip
  exec gosu node env HOME=/paperclip node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
else
  auto_bootstrap &
  exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
fi
