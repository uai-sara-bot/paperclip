#!/bin/bash
# Helper script for Railway shell users to log in to Claude Code
# Usage: /claude-login.sh
#
# This ensures credentials are saved to the volume (/paperclip/.claude/)
# so both the server (node user) and shell (root user) can find them.

export HOME=/paperclip
export PATH="/paperclip/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "=== Claude Code Login Helper ==="
echo "HOME=$HOME"
echo "Credentials will be saved to: /paperclip/.claude/"
echo ""

claude login "$@"

# Ensure node user can read the credentials
if [ -d /paperclip/.claude ]; then
  chown -R node:node /paperclip/.claude 2>/dev/null || true
  echo ""
  echo "✅ Credentials saved and permissions fixed."
  echo "   Agents will use these credentials automatically."
fi
