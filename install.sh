#!/usr/bin/env bash
# olladar installer — copies bins to ~/.local/bin, installs systemd user unit (if available),
# auto-detects a compatible Node (≥22.5 with built-in node:sqlite).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="${OLLADAR_BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${OLLADAR_UNIT_DIR:-$HOME/.config/systemd/user}"
STATE_DIR="$HOME/.local/share/olladar"

FORCE="${OLLADAR_FORCE:-0}"
NO_SYSTEMD="${OLLADAR_NO_SYSTEMD:-0}"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-systemd) NO_SYSTEMD=1 ;;
    -h|--help)
      echo "Usage: $0 [--force] [--no-systemd]"
      echo "  --force       overwrite existing files without prompting"
      echo "  --no-systemd  skip the systemd user service install (for containers/WSL)"
      exit 0 ;;
  esac
done

check_collision() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ "$FORCE" = "1" ]; then
    echo "  → overwriting existing $path (--force)"
  else
    echo "ERROR: $path already exists. Re-run with --force to overwrite, or remove it manually."
    exit 1
  fi
}

echo "→ target: $BIN_DIR"
mkdir -p "$BIN_DIR" "$STATE_DIR"

for f in olladar olladar-proxy.mjs olladar-stream; do
  check_collision "$BIN_DIR/$f"
done
install -m 0755 "$REPO_DIR/bin/olladar"            "$BIN_DIR/olladar"
install -m 0755 "$REPO_DIR/bin/olladar-proxy.mjs"  "$BIN_DIR/olladar-proxy.mjs"
install -m 0755 "$REPO_DIR/bin/olladar-stream"     "$BIN_DIR/olladar-stream"

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
  echo "ERROR: Node ≥22.5 not found. olladar uses node:sqlite (stable in 22.5+)."
  echo "       Install via nvm: 'nvm install 22 && nvm use 22'"
  exit 1
fi
echo "  → using $NODE_BIN ($("$NODE_BIN" --version))"

# Detect node:sqlite: stable in 22.18+, experimental flag required in 22.5-22.17
NEEDS_EXP_FLAG=0
"$NODE_BIN" -e "require('node:sqlite')" 2>/dev/null || NEEDS_EXP_FLAG=1

if [ "$NO_SYSTEMD" = "1" ]; then
  echo "→ skipping systemd user service (--no-systemd)"
  echo
  echo "Run manually:"
  if [ "$NEEDS_EXP_FLAG" = "1" ]; then
    echo "  $NODE_BIN --experimental-sqlite $BIN_DIR/olladar-proxy.mjs"
  else
    echo "  $NODE_BIN $BIN_DIR/olladar-proxy.mjs"
  fi
  exit 0
fi

# Detect systemd user availability
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "→ systemd user not available (container/WSL?). Skipping service install."
  echo
  echo "Run manually:"
  if [ "$NEEDS_EXP_FLAG" = "1" ]; then
    echo "  $NODE_BIN --experimental-sqlite $BIN_DIR/olladar-proxy.mjs"
  else
    echo "  $NODE_BIN $BIN_DIR/olladar-proxy.mjs"
  fi
  exit 0
fi

echo "→ installing systemd user unit at $UNIT_DIR"
mkdir -p "$UNIT_DIR"
check_collision "$UNIT_DIR/olladar-proxy.service"
install -m 0644 "$REPO_DIR/systemd/olladar-proxy.service" "$UNIT_DIR/olladar-proxy.service"

# Substitute detected node path
sed -i "s|Environment=\"OLLADAR_NODE=node\"|Environment=\"OLLADAR_NODE=$NODE_BIN\"|" "$UNIT_DIR/olladar-proxy.service"
# Add --experimental-sqlite if needed
if [ "$NEEDS_EXP_FLAG" = "1" ]; then
  sed -i 's|%h/\.local/bin/olladar-proxy\.mjs|--experimental-sqlite %h/.local/bin/olladar-proxy.mjs|' "$UNIT_DIR/olladar-proxy.service"
fi

echo "→ reloading systemd and enabling olladar-proxy"
systemctl --user daemon-reload
systemctl --user enable --now olladar-proxy.service

sleep 2
if systemctl --user is-active --quiet olladar-proxy.service; then
  echo "  ✓ olladar-proxy.service active"
else
  echo "  ✗ service failed — journalctl --user -u olladar-proxy.service --since '1 min ago'"
  exit 1
fi

cat <<EOF

olladar installed. Listens on http://127.0.0.1:11435 → forwards to ollama :11434.

To route your ollama-compat client through olladar, change its baseUrl
from http://localhost:11434 → http://localhost:11435.

Try:
  olladar stats --since 1h
  olladar stream --think off 'di hola'
  olladar watch
EOF
