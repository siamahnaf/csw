#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"

NO_COLOR="${NO_COLOR:-0}"
if [[ "$NO_COLOR" -eq 0 ]] && [[ -t 1 ]]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  MAGENTA="$(printf '\033[35m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

info()    { printf "%s%s[INFO]%s %s\n"   "$BLUE"   "$BOLD" "$RESET" "$*"; }
warn()    { printf "%s%s[WARN]%s %s\n"   "$YELLOW" "$BOLD" "$RESET" "$*"; }
success() { printf "%s%s[OK]%s   %s\n"   "$GREEN"  "$BOLD" "$RESET" "$*"; }
error()   { printf "%s%s[ERR]%s  %s\n"   "$RED"    "$BOLD" "$RESET" "$*"; }
step()    { printf "%s%s==>%s %s\n"      "$CYAN"   "$BOLD" "$RESET" "$*"; }
kv()      { printf "  %s%s%-10s%s %s\n"  "$DIM"    "$BOLD" "$1:" "$RESET" "$2"; }
hr()      { printf "%s%s────────────────────────────────────────%s\n" "$DIM" "$BOLD" "$RESET"; }

SPINNER_PID=""
spinner_start() {
  local msg="${1:-Working...}"
  [[ ! -t 1 ]] && { step "$msg"; return 0; }
  step "$msg"
  (
    local chars='|/-\'
    local i=0
    while :; do
      i=$(( (i + 1) % 4 ))
      printf "\r%s%s... %s%s" "$DIM" "$msg" "${chars:$i:1}" "$RESET"
      sleep 0.12
    done
  ) &
  SPINNER_PID="$!"
}
spinner_stop() {
  local msg="${1:-Done}"
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" >/dev/null 2>&1 || true
    SPINNER_PID=""
    [[ -t 1 ]] && printf "\r%s\r" "                                "
  fi
  success "$msg"
}

hr
printf "%s%sCSW Uninstaller%s\n" "$MAGENTA" "$BOLD" "$RESET"
hr
kv "Prefix" "$PREFIX"
kv "Bin"    "$BIN_DIR"
kv "Lib"    "$LIB_DIR"
hr

step "Uninstalling csw..."
removed_any=0

spinner_start "Removing files"
if [[ -f "$BIN_DIR/csw" ]]; then
  rm -f "$BIN_DIR/csw"
  removed_any=1
fi

if [[ -d "$LIB_DIR" ]]; then
  rm -rf "$LIB_DIR"
  removed_any=1
fi
spinner_stop "Removal complete"

hr
if [[ "$removed_any" -eq 1 ]]; then
  success "csw uninstalled."
else
  warn "Nothing to uninstall (csw not found under $PREFIX)."
fi
hr

warn "Note: this does NOT delete your backups:"
printf "  %srm -rf ~/.claude-switch-backup%s\n" "$BOLD" "$RESET"
