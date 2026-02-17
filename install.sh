#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"

REPO="siamahnaf/csw"
BRANCH="${BRANCH:-main}"
REPO_TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"

# ---------- Colors (ANSI) ----------
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

mkdir -p "$BIN_DIR" "$LIB_DIR"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

hr
printf "%s%sCSW Installer%s %s%s(%s@%s)%s\n" \
  "$MAGENTA" "$BOLD" "$RESET" \
  "$DIM" "$BOLD" "$REPO" "$BRANCH" "$RESET"
hr
kv "Prefix" "$PREFIX"
kv "Bin"    "$BIN_DIR"
kv "Lib"    "$LIB_DIR"
hr

spinner_start "Downloading csw"
info "Source: ${REPO}@${BRANCH}"
if ! curl -fsSL "$REPO_TARBALL" -o "$tmp/repo.tar.gz"; then
  error "Download failed. Check internet or repo/branch name."
  exit 1
fi
spinner_stop "Downloaded tarball"

spinner_start "Extracting"
tar -xzf "$tmp/repo.tar.gz" -C "$tmp"
spinner_stop "Extracted"

REPO_DIR="$(find "$tmp" -maxdepth 1 -type d -name 'csw-*' | head -n 1)"
if [[ -z "${REPO_DIR:-}" || ! -d "$REPO_DIR" ]]; then
  error "Could not locate extracted repo folder."
  exit 1
fi
info "Repo dir: $REPO_DIR"

spinner_start "Installing files"
cp -f "$REPO_DIR/ccswitch.sh" "$LIB_DIR/ccswitch.sh"
cp -f "$REPO_DIR/bin/csw" "$BIN_DIR/csw"
chmod +x "$LIB_DIR/ccswitch.sh" "$BIN_DIR/csw"
spinner_stop "Installed"

installed_version="$(
  awk -F'"' '/^[[:space:]]*readonly[[:space:]]+CSW_VERSION=/{print $2; exit}' "$LIB_DIR/ccswitch.sh" 2>/dev/null || true
)"
[[ -z "${installed_version:-}" ]] && installed_version="unknown"

hr
success "Installed:"
kv "Binary"   "$BIN_DIR/csw"
kv "Library"  "$LIB_DIR/ccswitch.sh"
kv "Version"  "$installed_version"
hr

echo
warn "If 'csw' is not found, add to PATH:"
printf "  %sexport PATH=\"\$HOME/.local/bin:\$PATH\"%s\n" "$BOLD" "$RESET"

echo
info "zsh:"
printf "  %secho 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc%s\n" "$BOLD" "$RESET"
