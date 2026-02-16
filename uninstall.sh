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
MAGENTA="$(printf '\033[35m')"
CYAN="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
DIM="$(printf '\033[2m')"
RESET="$(printf '\033[0m')"

# ---------- Styled helpers ----------
info()    { printf "%s%s[INFO]%s %s\n"   "$BLUE"   "$BOLD" "$RESET" "$*"; }
warn()    { printf "%s%s[WARN]%s %s\n"   "$YELLOW" "$BOLD" "$RESET" "$*"; }
success() { printf "%s%s[OK]%s   %s\n"   "$GREEN"  "$BOLD" "$RESET" "$*"; }
error()   { printf "%s%s[ERR]%s  %s\n"   "$RED"    "$BOLD" "$RESET" "$*"; }
step()    { printf "%s%s==>%s %s\n"      "$CYAN"   "$BOLD" "$RESET" "$*"; }
kv()      { printf "  %s%s%-10s%s %s\n"  "$DIM"    "$BOLD" "$1:" "$RESET" "$2"; }
hr()      { printf "%s%s────────────────────────────────────────%s\n" "$DIM" "$BOLD" "$RESET"; }

hr
printf "%s%sCSW Uninstaller%s\n" "$MAGENTA" "$BOLD" "$RESET"
hr
kv "Prefix" "$PREFIX"
kv "Bin"    "$BIN_DIR"
kv "Lib"    "$LIB_DIR"
hr

step "Uninstalling csw..."
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
hr
if [[ "$removed_any" -eq 1 ]]; then
  success "csw uninstalled."
else
  warn "Nothing to uninstall (csw not found under $PREFIX)."
fi
hr

warn "Note: this does NOT delete your backups:"
printf "  %srm -rf ~/.claude-switch-backup%s\n" "$BOLD" "$RESET"