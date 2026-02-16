#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"
REPO_TARBALL="https://github.com/siamahnaf/csw/archive/refs/heads/main.tar.gz"

mkdir -p "$BIN_DIR" "$LIB_DIR"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Downloading csw..."

curl -fsSL "$REPO_TARBALL" -o "$tmp/repo.tar.gz"
tar -xzf "$tmp/repo.tar.gz" -C "$tmp"

REPO_DIR="$(find "$tmp" -maxdepth 1 -type d -name '*-main' | head -n 1)"

cp -f "$REPO_DIR/ccswitch.sh" "$LIB_DIR/ccswitch.sh"
cp -f "$REPO_DIR/bin/csw" "$BIN_DIR/csw"

chmod +x "$LIB_DIR/ccswitch.sh" "$BIN_DIR/csw"

echo ""
echo "✅ Installed: $BIN_DIR/csw"
echo ""
echo "If 'csw' is not found, add to PATH:"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
echo ""
echo "zsh:"
echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"