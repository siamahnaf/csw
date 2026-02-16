#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"

# ---------- Colors (ANSI) ----------
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

info()    { printf "%s%s[INFO]%s %s\n"   "$BLUE"  "$BOLD" "$RESET" "$*"; }
warn()    { printf "%s%s[WARN]%s %s\n"   "$YELLOW" "$BOLD" "$RESET" "$*"; }
success() { printf "%s%s[OK]%s   %s\n"   "$GREEN" "$BOLD" "$RESET" "$*"; }
error()   { printf "%s%s[ERR]%s  %s\n"   "$RED"   "$BOLD" "$RESET" "$*"; }

info "Uninstalling csw..."
info "Target prefix: $PREFIX"

removed_any=0

if [[ -f "$BIN_DIR/csw" ]]; then
  rm -f "$BIN_DIR/csw"
  success "Removed: $BIN_DIR/csw"
  removed_any=1
else
  warn "Not found: $BIN_DIR/csw"
fi

if [[ -d "$LIB_DIR" ]]; then
  rm -rf "$LIB_DIR"
  success "Removed: $LIB_DIR"
  removed_any=1
else
  warn "Not found: $LIB_DIR"
fi

echo
if [[ "$removed_any" -eq 1 ]]; then
  success "csw uninstalled."
else
  warn "Nothing to uninstall (csw not found under $PREFIX)."
fi

warn "Note: this does NOT delete your backups:"
printf "  %srm -rf ~/.claude-switch-backup%s\n" "$BOLD" "$RESET"