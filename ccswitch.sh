#!/usr/bin/env bash
# csw — Multi-Account Switcher for Claude Code (Bash 3.2 compatible)

set -euo pipefail

readonly CSW_VERSION="2.3.0"

# Repo info (used for update checks)
readonly CSW_REPO="siamahnaf/csw"
readonly CSW_DEFAULT_BRANCH="main"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# -----------------------------
# Colors / Styled output
# -----------------------------
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
MAGENTA="$(printf '\033[35m')"
CYAN="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
DIM="$(printf '\033[2m')"
RESET="$(printf '\033[0m')"

info()    { printf "%s%s[INFO]%s %s\n" "$BLUE"   "$BOLD" "$RESET" "$*"; }
warn()    { printf "%s%s[WARN]%s %s\n" "$YELLOW" "$BOLD" "$RESET" "$*"; }
success() { printf "%s%s[OK]%s   %s\n" "$GREEN"  "$BOLD" "$RESET" "$*"; }
error()   { printf "%s%s[ERR]%s  %s\n" "$RED"    "$BOLD" "$RESET" "$*"; }
step()    { printf "%s%s==>%s %s\n"     "$CYAN"   "$BOLD" "$RESET" "$*"; }
title()   { printf "%s%s%s%s\n"         "$MAGENTA" "$BOLD" "$*" "$RESET"; }
dimln()   { printf "%s%s%s\n"           "$DIM" "$*" "$RESET"; }

# -----------------------------
# Container detection
# -----------------------------
is_running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null && return 0
  [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null && return 0
  [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]] && return 0
  return 1
}

# -----------------------------
# Platform detection
# -----------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then echo "wsl"; else echo "linux"; fi
      ;;
    *) echo "unknown" ;;
  esac
}

# -----------------------------
# Claude config path
# -----------------------------
get_claude_config_path() {
  local primary_config="$HOME/.claude/.claude.json"
  local fallback_config="$HOME/.claude.json"

  if [[ -f "$primary_config" ]]; then
    if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
      echo "$primary_config"
      return
    fi
  fi
  echo "$fallback_config"
}

# -----------------------------
# JSON helpers
# -----------------------------
validate_json() {
  local file="$1"
  jq . "$file" >/dev/null 2>&1 || { error "Invalid JSON in $file"; return 1; }
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

write_json() {
  local file="$1" content="$2" temp_file
  temp_file="$(mktemp "${file}.XXXXXX")"
  printf '%s\n' "$content" > "$temp_file"
  if ! jq . "$temp_file" >/dev/null 2>&1; then
    rm -f "$temp_file"
    error "Generated invalid JSON"
    return 1
  fi
  mv "$temp_file" "$file"
  chmod 600 "$file"
}

resolve_account_identifier() {
  local identifier="$1"
  [[ "$identifier" =~ ^[0-9]+$ ]] && { echo "$identifier"; return 0; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { echo ""; return 0; }

  jq -r --arg email "$identifier" '
    (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
  ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1
}

# -----------------------------
# Dependencies
# -----------------------------
check_dependencies() {
  for cmd in jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      error "Required command '$cmd' not found."
      [[ "$cmd" == "jq" ]] && { dimln "  macOS: brew install jq"; dimln "  Ubuntu/Debian: sudo apt-get install -y jq"; }
      exit 1
    }
  done
}

# -----------------------------
# Update helpers
# -----------------------------
_strip_v_prefix() { echo "${1#v}"; }

_semver_gt() {
  local a="$(_strip_v_prefix "$1")"
  local b="$(_strip_v_prefix "$2")"
  awk -v a="$a" -v b="$b" '
    function n(x){ return (x==""?0:x)+0 }
    BEGIN{
      split(a,A,"."); split(b,B,".")
      for(i=1;i<=3;i++){
        ai=n(A[i]); bi=n(B[i])
        if(ai>bi) exit 0
        if(ai<bi) exit 1
      }
      exit 1
    }
  '
}

_get_latest_release_tag() {
  curl -fsSL "https://api.github.com/repos/${CSW_REPO}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null \
    | head -n 1
}

_check_update_available() {
  local tag latest
  tag="$(_get_latest_release_tag)"
  [[ -z "${tag:-}" ]] && return 2
  latest="$(_strip_v_prefix "$tag")"
  _semver_gt "$latest" "$CSW_VERSION" && { echo "$latest"; return 0; }
  return 1
}

cmd_check_update() {
  local latest
  if latest="$(_check_update_available)"; then
    warn "Update available: ${CSW_VERSION} -> ${latest}"
    info "Run: csw --update"
    return 0
  fi

  case "$?" in
    1) success "You are up to date: ${CSW_VERSION}" ;;
    2)
      warn "No GitHub releases found for ${CSW_REPO}."
      info "Tip: create a release tag like v${CSW_VERSION} to enable update checking."
      info "You can still update from branch '${CSW_DEFAULT_BRANCH}' using: csw --update"
      ;;
    *) error "Could not check for updates (network/API issue)."; return 1 ;;
  esac
}

_install_from_tarball() {
  local tarball_url="$1"
  local prefix="${PREFIX:-$HOME/.local}"
  local bin_dir="${prefix}/bin"
  local lib_dir="${prefix}/share/csw"

  mkdir -p "$bin_dir" "$lib_dir"

  local tmp repo_dir
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmp\"" EXIT

  curl -fsSL "$tarball_url" -o "$tmp/repo.tar.gz"
  tar -xzf "$tmp/repo.tar.gz" -C "$tmp"

  repo_dir="$(find "$tmp" -maxdepth 1 -type d -name 'csw-*' | head -n 1)"
  if [[ -z "${repo_dir:-}" || ! -d "$repo_dir" ]]; then
    error "Could not locate extracted repo folder."
    return 1
  fi

  cp -f "$repo_dir/ccswitch.sh" "$lib_dir/ccswitch.sh"
  cp -f "$repo_dir/bin/csw" "$bin_dir/csw"
  chmod +x "$lib_dir/ccswitch.sh" "$bin_dir/csw"

  success "Installed/updated: $bin_dir/csw"
  info "Library: $lib_dir/ccswitch.sh"
  return 0
}

cmd_update() {
  local tag latest tarball

  tag="$(_get_latest_release_tag)"
  if [[ -n "${tag:-}" ]]; then
    latest="$(_strip_v_prefix "$tag")"
    if _semver_gt "$latest" "$CSW_VERSION"; then
      step "Updating to release ${tag}..."
    else
      step "Already up to date (${CSW_VERSION}). Reinstalling latest release ${tag}..."
    fi
    tarball="https://codeload.github.com/${CSW_REPO}/tar.gz/${tag}"
    _install_from_tarball "$tarball"
    success "Done."
    return 0
  fi

  warn "No GitHub releases found. Updating from branch '${CSW_DEFAULT_BRANCH}'..."
  tarball="https://codeload.github.com/${CSW_REPO}/tar.gz/refs/heads/${CSW_DEFAULT_BRANCH}"
  _install_from_tarball "$tarball"
  success "Done."
}

# -----------------------------
# Directory setup
# -----------------------------
setup_directories() {
  mkdir -p "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials" "$BACKUP_DIR/settings"
  chmod 700 "$BACKUP_DIR" "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials" "$BACKUP_DIR/settings"
}

# -----------------------------
# Claude process detection
# -----------------------------
is_claude_running() {
  ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" { exit 0 } END { exit 1 }'
}

wait_for_claude_close() {
  if ! is_claude_running; then return 0; fi
  warn "Claude Code is running. Please close it first."
  info "Waiting for Claude Code to close..."
  while is_claude_running; do sleep 1; done
  success "Claude Code closed. Continuing..."
}

# -----------------------------
# Current account
# -----------------------------
get_current_account() {
  local cfg; cfg="$(get_claude_config_path)"
  [[ ! -f "$cfg" ]] && { echo "none"; return 0; }
  validate_json "$cfg" || { echo "none"; return 0; }
  local email
  email="$(jq -r '.oauthAccount.emailAddress // empty' "$cfg" 2>/dev/null || true)"
  echo "${email:-none}"
}

# -----------------------------
# settings.json auth-conflict fix
# -----------------------------
_get_user_settings_path() {
  echo "$HOME/.claude/settings.json"
}

_sanitize_settings_json() {
  # Removes API-key based auth config that conflicts with OAuth switching:
  # - apiKeyHelper
  # - env keys that inject API keys/tokens
  jq '
    del(.apiKeyHelper)
    | if (.env? and (.env | type) == "object") then
        .env |= del(
          "ANTHROPIC_API_KEY",
          "CLAUDE_API_KEY",
          "CLAUDE_CODE_OAUTH_TOKEN",
          "ANTHROPIC_AUTH_TOKEN"
        )
      else .
      end
  '
}

_apply_oauth_mode_settings() {
  # Ensure user settings do not force API-key auth while we switch OAuth accounts.
  setup_directories

  local settings_path
  settings_path="$(_get_user_settings_path)"

  # Warn if managed settings may be injecting apiKeyHelper (cannot edit without sudo)
  local managed_path="/Library/Application Support/ClaudeCode/managed-settings.json"
  if [[ -f "$managed_path" ]]; then
    if jq -e '.apiKeyHelper? // empty | length > 0' "$managed_path" >/dev/null 2>&1; then
      warn "Managed settings define apiKeyHelper at: $managed_path"
      warn "This can cause the auth conflict warning and cannot be changed by csw without sudo."
    fi
  fi

  [[ ! -f "$settings_path" ]] && return 0

  if ! jq . "$settings_path" >/dev/null 2>&1; then
    warn "Skipping settings.json sanitization (invalid JSON): $settings_path"
    return 0
  fi

  local before after
  before="$(cat "$settings_path")"
  after="$(cat "$settings_path" | _sanitize_settings_json 2>/dev/null || true)"
  [[ -z "$after" ]] && return 0

  # Only write if it actually changes something
  if [[ "$before" != "$after" ]]; then
    local ts backup
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="$BACKUP_DIR/settings/settings.json.${ts}.bak"
    cp -f "$settings_path" "$backup"
    chmod 600 "$backup" || true

    write_json "$settings_path" "$after"
    success "Sanitized user settings to avoid auth conflict: $settings_path"
    dimln "  Backup saved: $backup"
  fi
}

# -----------------------------
# FIX: macOS Keychain credential service mismatch (space-safe)
# -----------------------------
_keychain_services() {
  printf '%s\n' "Claude Code-credentials" "Claude Code"
}

_keychain_read_service() {
  local service="$1"
  security find-generic-password -s "$service" -w 2>/dev/null || echo ""
}

_keychain_write_service() {
  local service="$1" payload="$2"
  security add-generic-password -U -s "$service" -a "$USER" -w "$payload" 2>/dev/null
}

# -----------------------------
# Credentials I/O
# -----------------------------
read_credentials() {
  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos)
      local best="" payload="" service=""
      while IFS= read -r service; do
        payload="$(_keychain_read_service "$service")"
        [[ -z "$payload" ]] && continue
        if printf '%s' "$payload" | jq -e '.claudeAiOauth.refreshToken? // empty | length > 0' >/dev/null 2>&1; then
          best="$payload"; break
        fi
        if [[ -z "$best" ]] && printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
          best="$payload"
        fi
      done < <(_keychain_services)
      printf '%s' "$best"
      ;;
    linux|wsl)
      [[ -f "$HOME/.claude/.credentials.json" ]] && cat "$HOME/.claude/.credentials.json" || echo ""
      ;;
    *) echo "" ;;
  esac
}

write_credentials() {
  local credentials="$1"
  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos)
      if ! printf '%s' "$credentials" | jq -e . >/dev/null 2>&1; then
        error "Refusing to write invalid JSON credentials to Keychain"
        return 1
      fi
      local service=""
      while IFS= read -r service; do
        _keychain_write_service "$service" "$credentials"
      done < <(_keychain_services)
      ;;
    linux|wsl)
      mkdir -p "$HOME/.claude"
      printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
      chmod 600 "$HOME/.claude/.credentials.json"
      ;;
  esac
}

read_account_credentials() {
  local account_num="$1" email="$2"
  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos) security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo "" ;;
    linux|wsl)
      local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      [[ -f "$cred_file" ]] && cat "$cred_file" || echo ""
      ;;
    *) echo "" ;;
  esac
}

write_account_credentials() {
  local account_num="$1" email="$2" credentials="$3"
  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos)
      if ! printf '%s' "$credentials" | jq -e . >/dev/null 2>&1; then
        error "Refusing to store invalid JSON in Keychain for Account-$account_num"
        return 1
      fi
      security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
      ;;
    linux|wsl)
      local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      printf '%s' "$credentials" > "$cred_file"
      chmod 600 "$cred_file"
      ;;
  esac
}

read_account_config() {
  local account_num="$1" email="$2"
  local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
  [[ -f "$config_file" ]] && cat "$config_file" || echo ""
}

write_account_config() {
  local account_num="$1" email="$2" config="$3"
  local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
  printf '%s\n' "$config" > "$config_file"
  chmod 600 "$config_file"
}

# -----------------------------
# sequence.json lifecycle
# -----------------------------
init_sequence_file() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_json "$SEQUENCE_FILE" '{
  "activeAccountNumber": null,
  "lastUpdated": "'"$now"'",
  "sequence": [],
  "accounts": {}
}'
  fi
}

get_next_account_number() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { echo "1"; return 0; }
  jq -r '(.accounts | keys | map(tonumber) | max // 0) + 1' "$SEQUENCE_FILE"
}

account_exists() {
  local email="$1"
  [[ ! -f "$SEQUENCE_FILE" ]] && return 1
  jq -e --arg email "$email" '.accounts | to_entries[]? | select(.value.email == $email) | .key' \
    "$SEQUENCE_FILE" >/dev/null 2>&1
}

# -----------------------------
# Commands
# -----------------------------
cmd_add_account() {
  setup_directories
  init_sequence_file

  # Ensure settings.json isn't forcing API-key auth when we're in OAuth switching mode
  _apply_oauth_mode_settings

  local current_email; current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found. Please log in first."; exit 1; }

  if account_exists "$current_email"; then
    warn "Account $current_email is already managed."
    exit 0
  fi

  local account_num; account_num="$(get_next_account_number)"
  local cfg_path; cfg_path="$(get_claude_config_path)"

  local current_creds current_config
  current_creds="$(read_credentials)"
  current_config="$(cat "$cfg_path")"

  [[ -z "$current_creds" ]] && { error "No credentials found/readable for current account (Keychain mismatch or permissions)."; exit 1; }

  local account_uuid
  account_uuid="$(jq -r '.oauthAccount.accountUuid' "$cfg_path")"

  write_account_credentials "$account_num" "$current_email" "$current_creds"
  write_account_config "$account_num" "$current_email" "$current_config"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local updated
  updated="$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$now" '
    .accounts[$num] = { email: $email, uuid: $uuid, added: $now }
    | .sequence += [($num|tonumber)]
    | .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Added Account $account_num: $current_email"
}

cmd_remove_account() {
  if [[ $# -eq 0 ]]; then error "Usage: $0 --remove-account <account_number|email>"; exit 1; fi
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }

  local identifier="$1" account_num
  if [[ "$identifier" =~ ^[0-9]+$ ]]; then
    account_num="$identifier"
  else
    validate_email "$identifier" || { error "Invalid email format: $identifier"; exit 1; }
    account_num="$(resolve_account_identifier "$identifier")"
    [[ -z "$account_num" ]] && { error "No account found with email: $identifier"; exit 1; }
  fi

  local account_info; account_info="$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")"
  [[ -z "$account_info" ]] && { error "Account-$account_num does not exist"; exit 1; }

  local email; email="$(printf '%s' "$account_info" | jq -r '.email')"

  local active_account; active_account="$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
  [[ "$active_account" == "$account_num" ]] && warn "Account-$account_num ($email) is currently active"

  printf "%s%sAre you sure you want to permanently remove Account-%s (%s)?%s [y/N] " \
    "$YELLOW" "$BOLD" "$account_num" "$email" "$RESET"
  local confirm; read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Cancelled"; exit 0; }

  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos) security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true ;;
    linux|wsl) rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json" ;;
  esac
  rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local updated
  updated="$(jq --arg num "$account_num" --arg now "$now" '
    del(.accounts[$num])
    | .sequence = (.sequence | map(select(. != ($num|tonumber))))
    | .lastUpdated = $now
    | if .activeAccountNumber == ($num|tonumber) then .activeAccountNumber = null else . end
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Account-$account_num ($email) has been removed"
}

first_run_setup() {
  local current_email; current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found. Please log in first."; return 1; }

  printf "%s%sNo managed accounts found.%s Add current account (%s) to managed list? [Y/n] %s" \
    "$CYAN" "$BOLD" "$RESET" "$current_email" "$RESET"
  local response; read -r response
  if [[ "$response" == "n" || "$response" == "N" ]]; then
    warn "Setup cancelled. You can run '$0 --add-account' later."
    return 1
  fi

  cmd_add_account
  return 0
}

cmd_list() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    warn "No accounts are managed yet."
    first_run_setup || true
    exit 0
  fi

  local current_email; current_email="$(get_current_account)"

  local active_account_num=""
  if [[ "$current_email" != "none" ]]; then
    active_account_num="$(jq -r --arg email "$current_email" '
      (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
    ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  fi

  title "Accounts:"
  jq -r --arg active "$active_account_num" '
    .sequence[]? as $num
    | .accounts[($num|tostring)]
    | if ($active != "" and ($num|tostring) == $active) then
        "  \($num): \(.email) (active)"
      else
        "  \($num): \(.email)"
      end
  ' "$SEQUENCE_FILE"
}

get_next_in_sequence() {
  jq -r '
    (.sequence // []) as $s
    | if ($s|length) == 0 then empty
      else
        (.activeAccountNumber) as $a
        | ($s | index($a)) as $i
        | if $i == null then $s[0]
          else $s[ (($i+1) % ($s|length)) ]
          end
      end
  ' "$SEQUENCE_FILE"
}

cmd_switch() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }

  local current_email; current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found"; exit 1; }

  if ! account_exists "$current_email"; then
    warn "Active account '$current_email' was not managed."
    info "Adding it automatically..."
    cmd_add_account
    local account_num; account_num="$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
    success "Added as Account-$account_num."
    info "Please run '$0 --switch' again to switch to the next account."
    exit 0
  fi

  local next_account; next_account="$(get_next_in_sequence)"
  [[ -z "$next_account" ]] && { error "No accounts in sequence."; exit 1; }
  perform_switch "$next_account"
}

cmd_switch_to() {
  [[ $# -eq 0 ]] && { error "Usage: $0 --switch-to <account_number|email>"; exit 1; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }

  local identifier="$1" target_account
  if [[ "$identifier" =~ ^[0-9]+$ ]]; then
    target_account="$identifier"
  else
    validate_email "$identifier" || { error "Invalid email format: $identifier"; exit 1; }
    target_account="$(resolve_account_identifier "$identifier")"
    [[ -z "$target_account" ]] && { error "No account found with email: $identifier"; exit 1; }
  fi

  local account_info; account_info="$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")"
  [[ -z "$account_info" ]] && { error "Account-$target_account does not exist"; exit 1; }

  perform_switch "$target_account"
}

get_current_managed_account_num() {
  local email="$1"
  [[ "$email" == "none" || ! -f "$SEQUENCE_FILE" ]] && { echo ""; return 0; }
  jq -r --arg email "$email" '
    (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
  ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1
}

perform_switch() {
  local target_account="$1"

  wait_for_claude_close

  # Ensure settings.json isn't forcing API-key auth while we switch OAuth accounts
  _apply_oauth_mode_settings

  local target_email
  target_email="$(jq -r --arg num "$target_account" '.accounts[$num].email // empty' "$SEQUENCE_FILE")"
  [[ -z "$target_email" ]] && { error "Could not resolve target account email."; exit 1; }

  local current_email; current_email="$(get_current_account)"
  local current_account; current_account="$(get_current_managed_account_num "$current_email")"
  [[ -z "$current_account" ]] && current_account="$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE")"

  local cfg_path; cfg_path="$(get_claude_config_path)"
  local current_creds current_config
  current_creds="$(read_credentials)"
  current_config="$(cat "$cfg_path")"

  if [[ -n "$current_account" && "$current_account" != "null" && "$current_email" != "none" ]]; then
    step "Saving current account backup..."
    if [[ -n "$current_creds" ]]; then
      write_account_credentials "$current_account" "$current_email" "$current_creds"
    else
      warn "Could not read current credentials; skipping credentials backup."
    fi
    write_account_config "$current_account" "$current_email" "$current_config"
    success "Backed up: Account-$current_account ($current_email)"
  fi

  local target_creds target_config
  target_creds="$(read_account_credentials "$target_account" "$target_email")"
  target_config="$(read_account_config "$target_account" "$target_email")"
  [[ -z "$target_creds" || -z "$target_config" ]] && { error "Missing backup data for Account-$target_account"; exit 1; }

  step "Applying target credentials/config..."
  write_credentials "$target_creds"

  local oauth_section
  oauth_section="$(printf '%s' "$target_config" | jq '.oauthAccount' 2>/dev/null || true)"
  [[ -z "$oauth_section" || "$oauth_section" == "null" ]] && { error "Invalid oauthAccount in backup"; exit 1; }

  local merged_config
  merged_config="$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$cfg_path" 2>/dev/null)" \
    || { error "Failed to merge config"; exit 1; }

  write_json "$cfg_path" "$merged_config"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local updated
  updated="$(jq --arg num "$target_account" --arg now "$now" '
    .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"

  success "Switched to Account-$target_account ($target_email)"
  cmd_list
  echo ""
  warn "Please restart Claude Code to use the new authentication."
  echo ""
}

show_usage() {
  title "csw — Multi-Account Switcher for Claude Code"
  dimln "Usage: $0 [COMMAND]"
  echo ""
  title "Commands:"
  dimln "  --add-account                    Add current account to managed accounts"
  dimln "  --remove-account <num|email>     Remove account by number or email"
  dimln "  --list                           List all managed accounts"
  dimln "  --switch                         Rotate to next account in sequence"
  dimln "  --switch-to <num|email>          Switch to specific account number or email"
  dimln "  --check-update                   Check for updates"
  dimln "  --update                         Update csw to the latest version"
  dimln "  -v, --version                    Show csw version"
  dimln "  --help                           Show this help message"
}

main() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && ! is_running_in_container; then
    error "Do not run this script as root (unless running in a container)"
    exit 1
  fi

  check_dependencies

  case "${1:-}" in
  -v|--version|version) success "csw version ${CSW_VERSION}" ;;
  -check-update|--check-update|check-update) cmd_check_update ;;
  --update|update) cmd_update ;;
  --add-account|add-account) cmd_add_account ;;
  --remove-account|remove-account|rm-account) shift; cmd_remove_account "$@" ;;
  --list|list|ls) cmd_list ;;
  --switch|switch|next) cmd_switch ;;
  --switch-to|switch-to|to) shift; cmd_switch_to "$@" ;;
  --help|help|-h|"") show_usage ;;
  *) error "Unknown command '$1'"; show_usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
