#!/bin/bash
set -e

# Fix permissions on the paperclip data directory if running as root
if [ "$(id -u)" = "0" ]; then
  # Ensure the paperclip directory exists and is owned by node user
  mkdir -p /paperclip
  chown -R node:node /paperclip
  
  # Run the server as node user
  exec gosu node node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
else
  # Already running as non-root, just start the server
  exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js "$@"
fi
