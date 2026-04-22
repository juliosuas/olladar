#!/usr/bin/env bash
# Remove olladar cleanly. Keeps the SQLite log unless --purge is passed.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.local/share/olladar"

echo "→ stopping and disabling olladar-proxy.service"
systemctl --user disable --now olladar-proxy.service 2>/dev/null || true

echo "→ removing binaries and unit"
rm -f "$BIN_DIR/olladar" "$BIN_DIR/olladar-proxy.mjs" "$BIN_DIR/olladar-stream"
rm -f "$UNIT_DIR/olladar-proxy.service"
systemctl --user daemon-reload

if [ "${1:-}" = "--purge" ]; then
  echo "→ purging logs at $STATE_DIR"
  rm -rf "$STATE_DIR"
fi

echo "uninstalled. Logs at $STATE_DIR retained (pass --purge to delete)."
