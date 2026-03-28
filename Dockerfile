FROM node:lts-trixie-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY patches/ patches/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
WORKDIR /app
COPY --chown=node:node --from=build /app /app

# Install system tools: gosu (privilege dropping), xxd (secret gen), gh (GitHub CLI), git
RUN apt-get update && apt-get install -y --no-install-recommends \
    gosu xxd gh openssh-client \
  && rm -rf /var/lib/apt/lists/*

# Install Claude Code and Codex CLIs globally and ensure they're in PATH
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest \
  && echo "Claude CLI installed at: $(which claude)" \
  && claude --version || true

# Ensure npm global bin is in PATH for all users (node user especially)
ENV PATH="/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# Create paperclip data dir
RUN mkdir -p /paperclip && chown node:node /paperclip

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV NODE_ENV=production \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=public \
  NPM_CONFIG_CACHE=/tmp/.npm \
  HOST=0.0.0.0

EXPOSE 3100

# Run as root initially so entrypoint can fix volume permissions
ENTRYPOINT ["/entrypoint.sh"]
