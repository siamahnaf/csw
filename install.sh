#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/csw"

REPO="siamahnaf/csw"
BRANCH="${BRANCH:-main}"
REPO_TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"

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

mkdir -p "$BIN_DIR" "$LIB_DIR"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

info "Downloading csw from ${REPO}@${BRANCH}..."
if ! curl -fsSL "$REPO_TARBALL" -o "$tmp/repo.tar.gz"; then
  error "Download failed. Check your internet or repo/branch name."
  exit 1
fi

info "Extracting..."
tar -xzf "$tmp/repo.tar.gz" -C "$tmp"

REPO_DIR="$(find "$tmp" -maxdepth 1 -type d -name 'csw-*' | head -n 1)"
if [[ -z "${REPO_DIR:-}" || ! -d "$REPO_DIR" ]]; then
  error "Could not locate extracted repo folder."
  exit 1
fi

info "Installing files..."
cp -f "$REPO_DIR/ccswitch.sh" "$LIB_DIR/ccswitch.sh"
cp -f "$REPO_DIR/bin/csw" "$BIN_DIR/csw"

chmod +x "$LIB_DIR/ccswitch.sh" "$BIN_DIR/csw"

# ---- Read installed version from the installed script ----
installed_version="$(
  awk -F'"' '/^[[:space:]]*readonly[[:space:]]+CSW_VERSION=/{print $2; exit}' "$LIB_DIR/ccswitch.sh" 2>/dev/null || true
)"
if [[ -z "${installed_version:-}" ]]; then
  installed_version="unknown"
fi

success "Installed: $BIN_DIR/csw"
success "Library:   $LIB_DIR/ccswitch.sh"
success "Version:   ${installed_version}"

echo
warn "If 'csw' is not found, add to PATH:"
printf "  %sexport PATH=\"\$HOME/.local/bin:\$PATH\"%s\n" "$BOLD" "$RESET"
echo
info "zsh:"
printf "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc\n"