#!/usr/bin/env bash
# olladar installer — copies bins to ~/.local/bin, installs systemd user unit,
# auto-detects a compatible Node (≥22.5 with experimental sqlite).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="${OLLADAR_BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${OLLADAR_UNIT_DIR:-$HOME/.config/systemd/user}"
STATE_DIR="$HOME/.local/share/olladar"

echo "→ installing bins to $BIN_DIR"
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$STATE_DIR"
install -m 0755 "$REPO_DIR/bin/olladar"              "$BIN_DIR/olladar"
install -m 0755 "$REPO_DIR/bin/olladar-proxy.mjs"    "$BIN_DIR/olladar-proxy.mjs"
install -m 0755 "$REPO_DIR/bin/olladar-stream"       "$BIN_DIR/olladar-stream"

echo "→ detecting Node ≥22.5"
NODE_BIN=""
for candidate in "$HOME"/.nvm/versions/node/v*/bin/node $(command -v node 2>/dev/null || true); do
  [ -x "$candidate" ] || continue
  major=$("$candidate" -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
  minor=$("$candidate" -p "process.versions.node.split('.')[1]" 2>/dev/null || echo 0)
  if [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 5 ]; }; then
    NODE_BIN="$candidate"; break
  fi
done

if [ -z "$NODE_BIN" ]; then
  echo "ERROR: Node ≥22.5 not found. olladar requires node:sqlite (experimental, 22.5+)."
  echo "       Install via nvm: 'nvm install 22 && nvm use 22'"
  exit 1
fi
echo "  → using $NODE_BIN ($("$NODE_BIN" --version))"

echo "→ installing systemd user unit"
install -m 0644 "$REPO_DIR/systemd/olladar-proxy.service" "$UNIT_DIR/olladar-proxy.service"
# Substitute detected node path
sed -i "s|Environment=\"OLLADAR_NODE=node\"|Environment=\"OLLADAR_NODE=$NODE_BIN\"|" "$UNIT_DIR/olladar-proxy.service"

echo "→ reloading systemd and enabling olladar-proxy"
systemctl --user daemon-reload
systemctl --user enable --now olladar-proxy.service

echo "→ verifying"
sleep 2
if systemctl --user is-active --quiet olladar-proxy.service; then
  echo "  ✓ olladar-proxy.service active"
else
  echo "  ✗ service failed — check: journalctl --user -u olladar-proxy.service --since '1 min ago'"
  exit 1
fi

echo
echo "olladar installed. Listens on http://127.0.0.1:11435 → forwards to ollama :11434."
echo
echo "To route your ollama-compat client through olladar, change its baseUrl"
echo "from http://localhost:11434 → http://localhost:11435."
echo
echo "Try:"
echo "  olladar stats --since 1h"
echo "  olladar stream --think off 'di hola'"
echo "  olladar watch"
