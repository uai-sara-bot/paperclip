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

# Install Claude Code and Codex CLIs globally
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest \
  && echo "Claude CLI (npm) installed at: $(which claude)" \
  && claude --version || true

# Run 'claude install' to set up the native binary, then make it accessible system-wide
RUN mkdir -p /usr/local/share/.claude-home/.local/bin \
  && HOME=/usr/local/share/.claude-home claude install --yes 2>/dev/null || true \
  && if [ -f /usr/local/share/.claude-home/.local/bin/claude ]; then \
       cp /usr/local/share/.claude-home/.local/bin/claude /usr/local/bin/claude-native; \
     fi \
  && rm -rf /usr/local/share/.claude-home

# Ensure all CLI paths are available
ENV PATH="/paperclip/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# Create paperclip data dir and set it as node user's home directory
# This ensures gosu/su won't reset HOME to /home/node
RUN mkdir -p /paperclip && chown node:node /paperclip \
  && sed -i 's|node:/home/node|node:/paperclip|' /etc/passwd

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set HOME=/paperclip for ALL users system-wide via /etc/environment
# This is the most reliable way — it's read by PAM, login shells, and non-interactive shells
# Also set it in every possible profile location for Railway shell compatibility
RUN echo 'HOME=/paperclip' >> /etc/environment \
  && echo 'export HOME=/paperclip' >> /etc/profile.d/paperclip.sh \
  && echo 'export PATH="/paperclip/.local/bin:$PATH"' >> /etc/profile.d/paperclip.sh \
  && echo 'export HOME=/paperclip' >> /root/.bashrc \
  && echo 'export PATH="/paperclip/.local/bin:$PATH"' >> /root/.bashrc \
  && echo 'export HOME=/paperclip' >> /etc/bash.bashrc \
  && echo 'export PATH="/paperclip/.local/bin:$PATH"' >> /etc/bash.bashrc \
  && sed -i 's|root:/root|root:/paperclip|' /etc/passwd

ENV NODE_ENV=production \
  HOME=/paperclip \
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
