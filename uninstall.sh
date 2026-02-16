#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"

rm -f "$BIN_DIR/csw"
rm -rf "$LIB_DIR"

echo "🗑️ Uninstalled csw from $PREFIX"