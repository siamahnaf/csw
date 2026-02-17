#!/usr/bin/env bash
# csw — Multi-Account Switcher for Claude Code (Bash 3.2 compatible)
# Fixes macOS Keychain service mismatch + v2 UX features (interactive, colors, progress)

set -euo pipefail

readonly CSW_VERSION="2.1.2"
readonly CSW_REPO="siamahnaf/csw"
readonly CSW_DEFAULT_BRANCH="main"

readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly MAX_HISTORY=12
readonly SCHEMA_VERSION="2.0"

# -----------------------------
# Pre-parse flags before color init
# -----------------------------
NO_COLOR="${NO_COLOR:-0}"
for _arg in "$@"; do
  if [[ "$_arg" == "--no-color" ]]; then
    NO_COLOR=1
    break
  fi
done

# -----------------------------
# Color / Styled output (toggle)
# -----------------------------
_apply_colors() {
  if [[ "${NO_COLOR:-0}" -eq 0 ]] && [[ -t 1 ]]; then
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
}
_apply_colors

info()    { printf "%s%s[INFO]%s %s\n" "$BLUE"   "$BOLD" "$RESET" "$*"; }
warn()    { printf "%s%s[WARN]%s %s\n" "$YELLOW" "$BOLD" "$RESET" "$*"; }
success() { printf "%s%s[OK]%s   %s\n" "$GREEN"  "$BOLD" "$RESET" "$*"; }
error()   { printf "%s%s[ERR]%s  %s\n" "$RED"    "$BOLD" "$RESET" "$*"; }
step()    { printf "%s%s==>%s %s\n"     "$CYAN"   "$BOLD" "$RESET" "$*"; }
title()   { printf "%s%s%s%s\n"         "$MAGENTA" "$BOLD" "$*" "$RESET"; }
dimln()   { printf "%s%s%s\n"           "$DIM" "$*" "$RESET"; }
hr()      { printf "%s%s────────────────────────────────────────%s\n" "$DIM" "$BOLD" "$RESET"; }

# -----------------------------
# Progress indicator (spinner)
# -----------------------------
SPINNER_PID=""
_spinner_start() {
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

_spinner_stop() {
  local msg="${1:-Done}"
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" >/dev/null 2>&1 || true
    SPINNER_PID=""
    [[ -t 1 ]] && printf "\r%s\r" "                                "
  fi
  success "$msg"
}

_spinner_fail() {
  local msg="${1:-Failed}"
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" >/dev/null 2>&1 || true
    SPINNER_PID=""
    [[ -t 1 ]] && printf "\r%s\r" "                                "
  fi
  error "$msg"
}

cleanup_spinner() { [[ -n "${SPINNER_PID:-}" ]] && _spinner_fail "Interrupted"; }
trap cleanup_spinner INT TERM

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
  local primary="$HOME/.claude/.claude.json"
  local fallback="$HOME/.claude.json"

  if [[ -f "$primary" ]]; then
    if jq -e '.oauthAccount' "$primary" >/dev/null 2>&1; then
      echo "$primary"
      return
    fi
  fi
  echo "$fallback"
}

# -----------------------------
# JSON helpers
# -----------------------------
validate_json_file() { jq . "$1" >/dev/null 2>&1; }

write_json() {
  local file="$1" content="$2" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  if ! jq . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "Generated invalid JSON: $file"
    return 1
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# -----------------------------
# Dependencies
# -----------------------------
check_dependencies() {
  local missing=0
  for cmd in jq curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Missing dependency: $cmd"
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    dimln "Install jq:"
    dimln "  macOS:  brew install jq"
    dimln "  Ubuntu: sudo apt-get install -y jq"
    exit 1
  fi
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
  if _semver_gt "$latest" "$CSW_VERSION"; then
    echo "$latest"
    return 0
  fi
  return 1
}

cmd_check_update() {
  local latest rc
  _spinner_start "Checking for updates"
  if latest="$(_check_update_available)"; then
    _spinner_stop "Update available: ${CSW_VERSION} -> ${latest}"
    info "Run: csw --update"
    return 0
  fi
  rc=$?
  _spinner_stop "Checked"
  case "$rc" in
    1) success "You are up to date: ${CSW_VERSION}" ;;
    2) warn "No GitHub releases found for ${CSW_REPO}. (Still can update from branch.)" ;;
    *) error "Could not check updates (network/API issue)."; return 1 ;;
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

  _spinner_start "Downloading update"
  curl -fsSL "$tarball_url" -o "$tmp/repo.tar.gz"
  _spinner_stop "Downloaded"

  _spinner_start "Extracting"
  tar -xzf "$tmp/repo.tar.gz" -C "$tmp"
  _spinner_stop "Extracted"

  repo_dir="$(find "$tmp" -maxdepth 1 -type d -name 'csw-*' | head -n 1)"
  [[ -z "${repo_dir:-}" || ! -d "$repo_dir" ]] && { error "Could not locate extracted repo folder."; return 1; }

  _spinner_start "Installing files"
  cp -f "$repo_dir/ccswitch.sh" "$lib_dir/ccswitch.sh"
  cp -f "$repo_dir/bin/csw" "$bin_dir/csw"
  chmod +x "$lib_dir/ccswitch.sh" "$bin_dir/csw"
  _spinner_stop "Installed: $bin_dir/csw"
}

cmd_update() {
  local tag tarball
  tag="$(_get_latest_release_tag)"
  if [[ -n "${tag:-}" ]]; then
    step "Updating to ${tag}..."
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
  mkdir -p "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials"
  chmod 700 "$BACKUP_DIR" "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials"
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
  success "Claude Code closed."
}

# -----------------------------
# Current account
# -----------------------------
get_current_account() {
  local cfg email
  cfg="$(get_claude_config_path)"
  [[ ! -f "$cfg" ]] && { echo "none"; return 0; }
  validate_json_file "$cfg" || { echo "none"; return 0; }
  email="$(jq -r '.oauthAccount.emailAddress // empty' "$cfg" 2>/dev/null || true)"
  echo "${email:-none}"
}

# -----------------------------
# Credentials I/O (Keychain fix)
# -----------------------------
_keychain_services() {
  # one service per line (spaces-safe)
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

read_credentials() {
  local platform; platform="$(detect_platform)"
  case "$platform" in
    macos)
      local payload best="" line
      while IFS= read -r line; do
        payload="$(_keychain_read_service "$line")"
        [[ -z "$payload" ]] && continue

        if printf '%s' "$payload" | jq -e '.claudeAiOauth.refreshToken? // empty | length > 0' >/dev/null 2>&1; then
          best="$payload"
          break
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
        error "Refusing to write invalid JSON credentials"
        return 1
      fi

      local line
      while IFS= read -r line; do
        _keychain_write_service "$line" "$credentials"
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
    macos)
      security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
      ;;
    linux|wsl)
      local f="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      [[ -f "$f" ]] && cat "$f" || echo ""
      ;;
    *) echo "" ;;
  esac
}

write_account_credentials() {
  local account_num="$1" email="$2" credentials="$3"
  local platform; platform="$(detect_platform)"
  if ! printf '%s' "$credentials" | jq -e . >/dev/null 2>&1; then
    error "Invalid JSON credentials backup"
    return 1
  fi
  case "$platform" in
    macos)
      security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
      ;;
    linux|wsl)
      local f="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      printf '%s' "$credentials" > "$f"
      chmod 600 "$f"
      ;;
  esac
}

read_account_config() {
  local account_num="$1" email="$2"
  local f="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

write_account_config() {
  local account_num="$1" email="$2" config="$3"
  local f="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
  printf '%s\n' "$config" > "$f"
  chmod 600 "$f"
}

creds_has_refresh() {
  local creds="$1"
  printf '%s' "$creds" | jq -e '.claudeAiOauth.refreshToken? // empty | length > 0' >/dev/null 2>&1
}

# -----------------------------
# sequence.json lifecycle + migration
# -----------------------------
init_sequence_file() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    local now; now="$(utc_now)"
    write_json "$SEQUENCE_FILE" '{
  "schemaVersion": "'"$SCHEMA_VERSION"'",
  "activeAccountNumber": null,
  "lastUpdated": "'"$now"'",
  "sequence": [],
  "accounts": {},
  "history": []
}'
  fi
}

migrate_sequence_file() {
  [[ ! -f "$SEQUENCE_FILE" ]] && return 0
  local v
  v="$(jq -r '.schemaVersion // "1.0"' "$SEQUENCE_FILE" 2>/dev/null || echo "1.0")"
  [[ "$v" == "$SCHEMA_VERSION" ]] && return 0

  step "Migrating sequence.json schema: $v -> $SCHEMA_VERSION"
  cp "$SEQUENCE_FILE" "$SEQUENCE_FILE.backup-$(date +%s)" 2>/dev/null || true

  local migrated
  migrated="$(jq --arg ver "$SCHEMA_VERSION" '
    .schemaVersion = $ver
    | .history = (.history // [])
    | .accounts |= with_entries(
        .value |= (
          . + {
            alias: (.alias // null),
            lastUsed: (.lastUsed // null),
            usageCount: (.usageCount // 0),
            healthStatus: (.healthStatus // "unknown")
          }
        )
      )
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$migrated"
  success "Migration complete."
}

get_next_account_number() {
  jq -r '(.accounts | keys | map(tonumber) | max // 0) + 1' "$SEQUENCE_FILE" 2>/dev/null || echo "1"
}

account_exists_by_email() {
  local email="$1"
  jq -e --arg email "$email" '.accounts | to_entries[]? | select(.value.email == $email) | .key' \
    "$SEQUENCE_FILE" >/dev/null 2>&1
}

resolve_account_identifier() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] && { echo "$id"; return 0; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { echo ""; return 0; }

  local by_email by_alias
  by_email="$(jq -r --arg v "$id" '(.accounts | to_entries[]? | select(.value.email == $v) | .key) // empty' \
    "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  [[ -n "$by_email" ]] && { echo "$by_email"; return 0; }

  by_alias="$(jq -r --arg v "$id" '(.accounts | to_entries[]? | select((.value.alias // "") == $v) | .key) // empty' \
    "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  [[ -n "$by_alias" ]] && { echo "$by_alias"; return 0; }

  echo ""
}

append_history() {
  local from="$1" to="$2" ts="$3"
  local updated
  updated="$(jq --argjson max "$MAX_HISTORY" --arg from "$from" --arg to "$to" --arg ts "$ts" '
    .history = (.history // [])
    | .history += [{from: ($from|tonumber), to: ($to|tonumber), timestamp: $ts}]
    | .history = (.history | .[-$max:])
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
}

# -----------------------------
# Commands
# -----------------------------
cmd_add_account() {
  setup_directories
  init_sequence_file
  migrate_sequence_file

  local current_email cfg_path creds config num uuid now updated
  current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found. Please log in first."; exit 1; }

  if account_exists_by_email "$current_email"; then
    warn "Account $current_email is already managed. Use --sync to refresh its backup."
    exit 0
  fi

  cfg_path="$(get_claude_config_path)"

  _spinner_start "Reading current credentials"
  creds="$(read_credentials)"
  _spinner_stop "Credentials read"

  [[ -z "$creds" ]] && { error "Could not read credentials from Keychain"; exit 1; }

  config="$(cat "$cfg_path")"
  num="$(get_next_account_number)"
  uuid="$(jq -r '.oauthAccount.accountUuid // empty' "$cfg_path" 2>/dev/null || true)"
  now="$(utc_now)"

  _spinner_start "Saving backups"
  write_account_credentials "$num" "$current_email" "$creds"
  write_account_config "$num" "$current_email" "$config"
  _spinner_stop "Backups saved"

  updated="$(jq --arg num "$num" --arg email "$current_email" --arg uuid "$uuid" --arg now "$now" '
    .accounts[$num] = {
      email: $email,
      uuid: $uuid,
      added: $now,
      alias: null,
      lastUsed: $now,
      usageCount: 1,
      healthStatus: "unknown"
    }
    | .sequence += [($num|tonumber)]
    | .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Added Account-$num: $current_email"
}

cmd_sync() {
  setup_directories
  init_sequence_file
  migrate_sequence_file

  local current_email num cfg_path creds config now updated
  current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found. Please log in first."; exit 1; }

  num="$(jq -r --arg email "$current_email" '(.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty' \
    "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  if [[ -z "$num" ]]; then
    warn "Current account is not managed; adding it now..."
    cmd_add_account
    return 0
  fi

  cfg_path="$(get_claude_config_path)"

  _spinner_start "Reading current credentials"
  creds="$(read_credentials)"
  _spinner_stop "Credentials read"

  [[ -z "$creds" ]] && { error "Could not read credentials"; exit 1; }

  config="$(cat "$cfg_path")"
  now="$(utc_now)"

  _spinner_start "Updating backups"
  write_account_credentials "$num" "$current_email" "$creds"
  write_account_config "$num" "$current_email" "$config"
  _spinner_stop "Backups updated"

  updated="$(jq --arg num "$num" --arg now "$now" '
    .accounts[$num].lastUsed = $now
    | .accounts[$num].usageCount = ((.accounts[$num].usageCount // 0) + 1)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Synced Account-$num ($current_email)"
}

cmd_remove_account() {
  [[ $# -eq 0 ]] && { error "Usage: $0 --remove-account <num|email|alias>"; exit 1; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  local num email confirm platform now updated
  num="$(resolve_account_identifier "$1")"
  [[ -z "$num" ]] && { error "No account found: $1"; exit 1; }

  email="$(jq -r --arg num "$num" '.accounts[$num].email // empty' "$SEQUENCE_FILE")"
  [[ -z "$email" ]] && { error "Account-$num does not exist"; exit 1; }

  printf "%s%sRemove Account-%s (%s)?%s [y/N] " "$YELLOW" "$BOLD" "$num" "$email" "$RESET"
  read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Cancelled"; exit 0; }

  platform="$(detect_platform)"

  _spinner_start "Removing backups"
  case "$platform" in
    macos)
      security delete-generic-password -s "Claude Code-Account-${num}-${email}" 2>/dev/null || true
      ;;
    linux|wsl)
      rm -f "$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"
      ;;
  esac
  rm -f "$BACKUP_DIR/configs/.claude-config-${num}-${email}.json"
  _spinner_stop "Backups removed"

  now="$(utc_now)"
  updated="$(jq --arg num "$num" --arg now "$now" '
    del(.accounts[$num])
    | .sequence = (.sequence | map(select(. != ($num|tonumber))))
    | .lastUpdated = $now
    | if .activeAccountNumber == ($num|tonumber) then .activeAccountNumber = null else . end
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Removed Account-$num ($email)"
}

cmd_list() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { warn "No accounts are managed yet."; exit 0; }
  migrate_sequence_file

  local current_email active_num
  current_email="$(get_current_account)"
  active_num=""

  if [[ "$current_email" != "none" ]]; then
    active_num="$(jq -r --arg email "$current_email" '(.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty' \
      "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  fi

  title "Accounts:"
  jq -r --arg active "$active_num" '
    .sequence[]? as $num
    | .accounts[($num|tostring)] as $a
    | ($a.alias // "") as $alias
    | ($a.healthStatus // "unknown") as $h
    | ($a.usageCount // 0) as $u
    | if ($active != "" and ($num|tostring) == $active) then
        "  \($num): \($a.email)  (active)  alias=\($alias) uses=\($u) health=\($h)"
      else
        "  \($num): \($a.email)           alias=\($alias) uses=\($u) health=\($h)"
      end
  ' "$SEQUENCE_FILE"
}

cmd_status() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { info "No accounts are managed yet."; exit 0; }
  migrate_sequence_file

  local current_email num alias lastUsed usage health
  current_email="$(get_current_account)"
  title "Claude Code Account Status"
  echo ""

  if [[ "$current_email" == "none" ]]; then
    warn "No active account detected in config."
    return 0
  fi

  num="$(jq -r --arg email "$current_email" '(.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty' \
    "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  if [[ -z "$num" ]]; then
    warn "Active: $current_email (not managed)"
    return 0
  fi

  alias="$(jq -r --arg num "$num" '.accounts[$num].alias // "none"' "$SEQUENCE_FILE")"
  lastUsed="$(jq -r --arg num "$num" '.accounts[$num].lastUsed // "unknown"' "$SEQUENCE_FILE")"
  usage="$(jq -r --arg num "$num" '.accounts[$num].usageCount // 0' "$SEQUENCE_FILE")"
  health="$(jq -r --arg num "$num" '.accounts[$num].healthStatus // "unknown"' "$SEQUENCE_FILE")"

  success "Active: Account-$num ($current_email)"
  dimln "  alias: $alias"
  dimln "  usage: $usage"
  dimln "  last : $lastUsed"
  dimln "  health: $health"
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

get_current_managed_num() {
  local email="$1"
  [[ "$email" == "none" ]] && { echo ""; return 0; }
  jq -r --arg email "$email" '(.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty' \
    "$SEQUENCE_FILE" 2>/dev/null | head -n 1
}

cmd_set_alias() {
  [[ $# -lt 2 ]] && { error "Usage: $0 --set-alias <num|email|alias> <new_alias>"; exit 1; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  local num alias now updated
  num="$(resolve_account_identifier "$1")"
  [[ -z "$num" ]] && { error "No account found: $1"; exit 1; }

  alias="$2"
  [[ ! "$alias" =~ ^[a-zA-Z0-9_-]+$ ]] && { error "Alias must be letters/numbers/_/- only"; exit 1; }

  now="$(utc_now)"
  updated="$(jq --arg num "$num" --arg alias "$alias" --arg now "$now" '
    .accounts[$num].alias = $alias
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  success "Alias set: Account-$num -> $alias"
}

perform_switch() {
  local target="$1"

  wait_for_claude_close

  local target_email current_email current_num cfg_path current_creds current_config
  target_email="$(jq -r --arg num "$target" '.accounts[$num].email // empty' "$SEQUENCE_FILE")"
  [[ -z "$target_email" ]] && { error "Could not resolve target email"; exit 1; }

  current_email="$(get_current_account)"
  current_num="$(get_current_managed_num "$current_email")"
  [[ -z "$current_num" ]] && current_num="$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE")"
  [[ -z "$current_num" || "$current_num" == "null" ]] && current_num="0"

  cfg_path="$(get_claude_config_path)"

  _spinner_start "Reading current state"
  current_creds="$(read_credentials)"
  current_config="$(cat "$cfg_path")"
  _spinner_stop "Current state read"

  if [[ "$current_email" != "none" && "$current_num" != "0" ]]; then
    _spinner_start "Backing up current account"
    if [[ -n "$current_creds" ]]; then
      write_account_credentials "$current_num" "$current_email" "$current_creds" || true
    fi
    write_account_config "$current_num" "$current_email" "$current_config"
    _spinner_stop "Backed up Account-$current_num"
  fi

  local target_creds target_config
  _spinner_start "Loading target backup"
  target_creds="$(read_account_credentials "$target" "$target_email")"
  target_config="$(read_account_config "$target" "$target_email")"
  _spinner_stop "Target backup loaded"

  [[ -z "$target_creds" || -z "$target_config" ]] && { error "Missing backup data for Account-$target"; exit 1; }

  _spinner_start "Applying credentials (Keychain + file)"
  write_credentials "$target_creds"
  _spinner_stop "Credentials applied"

  local oauth_section merged
  oauth_section="$(printf '%s' "$target_config" | jq '.oauthAccount' 2>/dev/null || true)"
  [[ -z "$oauth_section" || "$oauth_section" == "null" ]] && { error "Invalid oauthAccount in backup"; exit 1; }

  _spinner_start "Updating config"
  merged="$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$cfg_path" 2>/dev/null)" \
    || { _spinner_fail "Config merge failed"; exit 1; }
  write_json "$cfg_path" "$merged"
  _spinner_stop "Config updated"

  local now updated
  now="$(utc_now)"
  updated="$(jq --arg num "$target" --arg now "$now" '
    .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
    | .accounts[$num].lastUsed = $now
    | .accounts[$num].usageCount = ((.accounts[$num].usageCount // 0) + 1)
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"
  append_history "$current_num" "$target" "$now"

  if ! creds_has_refresh "$target_creds"; then
    warn "Account-$target backup has no refreshToken; may hit 401 when access token expires."
    warn "Fix: switch to that account, login, then run: csw --sync"
  fi

  success "Switched to Account-$target ($target_email)"
  cmd_list
  echo ""
  warn "Restart Claude Code to use the new authentication."
}

cmd_switch() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  local current_email next num
  current_email="$(get_current_account)"
  [[ "$current_email" == "none" ]] && { error "No active Claude account found"; exit 1; }

  if ! account_exists_by_email "$current_email"; then
    warn "Active account '$current_email' was not managed."
    info "Adding it automatically..."
    cmd_add_account
    num="$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
    success "Added as Account-$num."
    info "Run 'csw --switch' again to rotate."
    exit 0
  fi

  next="$(get_next_in_sequence)"
  [[ -z "$next" ]] && { error "No accounts in sequence."; exit 1; }
  perform_switch "$next"
}

cmd_switch_to() {
  [[ $# -eq 0 ]] && { error "Usage: $0 --switch-to <num|email|alias>"; exit 1; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  local target
  target="$(resolve_account_identifier "$1")"
  [[ -z "$target" ]] && { error "No account found: $1"; exit 1; }
  perform_switch "$target"
}

cmd_verify() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  title "Verification"
  local any_bad=0 nums num

  nums="$(jq -r '.sequence[]?' "$SEQUENCE_FILE")"
  for num in $nums; do
    local email creds config health="healthy" now updated
    email="$(jq -r --arg num "$num" '.accounts[$num].email // empty' "$SEQUENCE_FILE")"
    creds="$(read_account_credentials "$num" "$email")"
    config="$(read_account_config "$num" "$email")"

    if [[ -z "$creds" || -z "$config" ]]; then
      any_bad=1; health="unhealthy"
      printf "  %s✗%s Account-%s (%s): missing backup\n" "$RED" "$RESET" "$num" "$email"
    elif creds_has_refresh "$creds"; then
      printf "  %s✓%s Account-%s (%s): ok\n" "$GREEN" "$RESET" "$num" "$email"
    else
      any_bad=1; health="degraded"
      printf "  %s⚠%s Account-%s (%s): no refreshToken\n" "$YELLOW" "$RESET" "$num" "$email"
    fi

    now="$(utc_now)"
    updated="$(jq --arg num "$num" --arg health "$health" --arg now "$now" '
      .accounts[$num].healthStatus = $health
      | .lastUpdated = $now
    ' "$SEQUENCE_FILE")"
    write_json "$SEQUENCE_FILE" "$updated"
  done

  echo ""
  if [[ "$any_bad" -eq 0 ]]; then
    success "All accounts verified"
  else
    warn "Some accounts are degraded/unhealthy."
    warn "Fix: switch to that account, login, then run: csw --sync"
  fi
}

cmd_history() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { info "No history yet."; exit 0; }
  migrate_sequence_file

  local n
  n="$(jq -r '(.history // []) | length' "$SEQUENCE_FILE")"
  [[ "$n" -eq 0 ]] && { info "No history yet."; exit 0; }

  title "Switch History (newest first)"
  jq -c '(.history // []) | reverse | .[]' "$SEQUENCE_FILE" | while IFS= read -r entry; do
    local from to ts
    from="$(printf '%s' "$entry" | jq -r '.from')"
    to="$(printf '%s' "$entry" | jq -r '.to')"
    ts="$(printf '%s' "$entry" | jq -r '.timestamp')"
    printf "  %s%s%s %s->%s\n" "$DIM" "$ts" "$RESET" "$from" "$to"
  done
}

cmd_undo() {
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts are managed yet"; exit 1; }
  migrate_sequence_file

  local n last from
  n="$(jq -r '(.history // []) | length' "$SEQUENCE_FILE")"
  [[ "$n" -eq 0 ]] && { error "No history to undo"; exit 1; }

  last="$(jq -c '(.history // []) | last' "$SEQUENCE_FILE")"
  from="$(printf '%s' "$last" | jq -r '.from')"
  [[ -z "$from" || "$from" == "null" ]] && { error "Bad history entry"; exit 1; }

  info "Undo: switching back to Account-$from"
  perform_switch "$from"
}

cmd_export() {
  [[ $# -eq 0 ]] && { error "Usage: $0 --export <output.tar.gz>"; exit 1; }
  [[ ! -f "$SEQUENCE_FILE" ]] && { error "No accounts to export"; exit 1; }
  migrate_sequence_file

  local out="$1" tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmp\"" EXIT

  _spinner_start "Preparing export"
  mkdir -p "$tmp/configs" "$tmp/credentials"
  cp "$SEQUENCE_FILE" "$tmp/sequence.json"
  cp -R "$BACKUP_DIR/configs/" "$tmp/" 2>/dev/null || true

  jq -c '.accounts | to_entries[] | {num:.key,email:.value.email}' "$SEQUENCE_FILE" | while IFS= read -r row; do
    local num email creds
    num="$(printf '%s' "$row" | jq -r '.num')"
    email="$(printf '%s' "$row" | jq -r '.email')"
    creds="$(read_account_credentials "$num" "$email")"
    if [[ -n "$creds" ]]; then
      printf '%s' "$creds" > "$tmp/credentials/.claude-credentials-${num}-${email}.json"
      chmod 600 "$tmp/credentials/.claude-credentials-${num}-${email}.json"
    fi
  done

  tar -czf "$out" -C "$tmp" . >/dev/null 2>&1
  _spinner_stop "Exported: $out"
  warn "Keep it secure — it contains auth credentials."
}

cmd_import() {
  [[ $# -eq 0 ]] && { error "Usage: $0 --import <archive.tar.gz>"; exit 1; }
  local arc="$1"
  [[ ! -f "$arc" ]] && { error "Archive not found: $arc"; exit 1; }

  printf "%s%sThis will merge imported accounts. Continue?%s [y/N] " "$YELLOW" "$BOLD" "$RESET"
  local confirm
  read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Cancelled"; exit 0; }

  setup_directories
  init_sequence_file
  migrate_sequence_file

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmp\"" EXIT

  _spinner_start "Extracting import archive"
  tar -xzf "$arc" -C "$tmp" >/dev/null 2>&1 || { _spinner_fail "Failed to extract"; exit 1; }
  _spinner_stop "Extracted"

  [[ ! -f "$tmp/sequence.json" ]] && { error "Invalid archive (missing sequence.json)"; exit 1; }

  _spinner_start "Merging accounts"
  jq -c '.accounts | to_entries[] | {email:.value.email, uuid:(.value.uuid//""), alias:(.value.alias//null)}' "$tmp/sequence.json" \
    | while IFS= read -r row; do
        local email uuid alias num now updated cfg_file cred_file f
        email="$(printf '%s' "$row" | jq -r '.email')"
        uuid="$(printf '%s' "$row" | jq -r '.uuid')"
        alias="$(printf '%s' "$row" | jq -r '.alias // empty')"

        if account_exists_by_email "$email"; then
          warn "Skipping existing: $email"
          continue
        fi

        num="$(get_next_account_number)"
        now="$(utc_now)"

        cfg_file=""
        for f in "$tmp/configs/.claude-config-"*"-${email}.json"; do
          [[ -f "$f" ]] && { cfg_file="$f"; break; }
        done
        [[ -n "$cfg_file" ]] && write_account_config "$num" "$email" "$(cat "$cfg_file")"

        cred_file=""
        for f in "$tmp/credentials/.claude-credentials-"*"-${email}.json"; do
          [[ -f "$f" ]] && { cred_file="$f"; break; }
        done
        [[ -n "$cred_file" ]] && write_account_credentials "$num" "$email" "$(cat "$cred_file")"

        updated="$(jq --arg num "$num" --arg email "$email" --arg uuid "$uuid" --arg now "$now" --arg alias "$alias" '
          .accounts[$num] = {
            email: $email, uuid: $uuid, added: $now,
            alias: (if $alias=="" then null else $alias end),
            lastUsed: null, usageCount: 0, healthStatus: "unknown"
          }
          | .sequence += [($num|tonumber)]
          | .lastUpdated = $now
        ' "$SEQUENCE_FILE")"
        write_json "$SEQUENCE_FILE" "$updated"
      done
  _spinner_stop "Merge complete"
  success "Import complete."
}

cmd_interactive() {
  init_sequence_file
  migrate_sequence_file

  while true; do
    echo ""
    hr
    title "csw interactive"
    hr
    echo "  1) List accounts"
    echo "  2) Add current account"
    echo "  3) Sync current account"
    echo "  4) Switch next"
    echo "  5) Switch to (num/email/alias)"
    echo "  6) Set alias"
    echo "  7) Status"
    echo "  8) Verify"
    echo "  9) History"
    echo " 10) Undo"
    echo " 11) Export"
    echo " 12) Import"
    echo "  0) Exit"
    printf "\n%s> %s" "$BOLD" "$RESET"
    local choice
    read -r choice
    case "$choice" in
      1) cmd_list ;;
      2) cmd_add_account ;;
      3) cmd_sync ;;
      4) cmd_switch ;;
      5) printf "Target (num/email/alias): "; local t; read -r t; cmd_switch_to "$t" ;;
      6) printf "Account (num/email/alias): "; local a; read -r a; printf "Alias: "; local al; read -r al; cmd_set_alias "$a" "$al" ;;
      7) cmd_status ;;
      8) cmd_verify ;;
      9) cmd_history ;;
      10) cmd_undo ;;
      11) printf "Output (.tar.gz): "; local o; read -r o; cmd_export "$o" ;;
      12) printf "Archive (.tar.gz): "; local i; read -r i; cmd_import "$i" ;;
      0) break ;;
      *) warn "Unknown choice" ;;
    esac
  done
}

show_usage() {
  title "csw — Multi-Account Switcher for Claude Code"
  dimln "Version: $CSW_VERSION"
  echo ""
  title "Commands:"
  dimln "  --interactive                    Menu-driven interactive mode"
  dimln "  --add-account                    Add current account"
  dimln "  --sync                           Refresh backup for current account"
  dimln "  --remove-account <id>            Remove account"
  dimln "  --list                           List accounts"
  dimln "  --status                         Show active status"
  dimln "  --switch                         Switch to next in sequence"
  dimln "  --switch-to <id>                 Switch to num/email/alias"
  dimln "  --set-alias <id> <alias>         Set alias"
  dimln "  --verify                         Verify backups"
  dimln "  --history                        Show history"
  dimln "  --undo                           Undo last switch"
  dimln "  --export <file.tar.gz>           Export backups"
  dimln "  --import <file.tar.gz>           Import backups"
  dimln "  --check-update                   Check for updates"
  dimln "  --update                         Update to latest"
  dimln "  --no-color                       Disable colors"
  dimln "  -v, --version                    Version"
  dimln "  --help                           Help"
}

# -----------------------------
# MAIN (rewritten safely)
# -----------------------------
main() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && ! is_running_in_container; then
    error "Do not run as root (unless in a container)"
    exit 1
  fi

  check_dependencies
  setup_directories

  # Handle --no-color safely (no recursion)
  if [[ "${1:-}" == "--no-color" ]]; then
    NO_COLOR=1
    _apply_colors
    shift || true
  fi

  case "${1:-}" in
    -v|--version|version)
      success "csw version ${CSW_VERSION}"
      ;;

    --interactive|interactive|ui)
      cmd_interactive
      ;;

    --check-update|check-update)
      cmd_check_update
      ;;

    --update|update)
      cmd_update
      ;;

    --add-account|add-account)
      cmd_add_account
      ;;

    --sync|sync|repair)
      cmd_sync
      ;;

    --remove-account|remove-account|rm-account)
      shift
      cmd_remove_account "$@"
      ;;

    --list|list|ls)
      cmd_list
      ;;

    --status|status)
      cmd_status
      ;;

    --switch|switch|next)
      cmd_switch
      ;;

    --switch-to|switch-to|to)
      shift
      cmd_switch_to "$@"
      ;;

    --set-alias|set-alias|alias)
      shift
      cmd_set_alias "$@"
      ;;

    --verify|verify)
      cmd_verify
      ;;

    --history|history)
      cmd_history
      ;;

    --undo|undo)
      cmd_undo
      ;;

    --export|export)
      shift
      cmd_export "$@"
      ;;

    --import|import)
      shift
      cmd_import "$@"
      ;;

    --help|help|-h|"")
      show_usage
      ;;

    *)
      error "Unknown command '$1'"
      show_usage
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
