#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Bash 3.2 compatible (macOS default)

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# -----------------------------
# Container detection
# -----------------------------
is_running_in_container() {
  if [[ -f /.dockerenv ]]; then
    return 0
  fi

  if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi

  if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
    return 0
  fi

  if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
    return 0
  fi

  return 1
}

# -----------------------------
# Platform detection
# -----------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        echo "wsl"
      else
        echo "linux"
      fi
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
  if ! jq . "$file" >/dev/null 2>&1; then
    echo "Error: Invalid JSON in $file"
    return 1
  fi
}

validate_email() {
  local email="$1"
  if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  return 1
}

write_json() {
  local file="$1"
  local content="$2"
  local temp_file

  temp_file="$(mktemp "${file}.XXXXXX")"
  printf '%s\n' "$content" > "$temp_file"

  if ! jq . "$temp_file" >/dev/null 2>&1; then
    rm -f "$temp_file"
    echo "Error: Generated invalid JSON"
    return 1
  fi

  mv "$temp_file" "$file"
  chmod 600 "$file"
}

# Resolve account identifier:
# - if numeric -> return it
# - else treat as email and find account number
resolve_account_identifier() {
  local identifier="$1"
  if [[ "$identifier" =~ ^[0-9]+$ ]]; then
    echo "$identifier"
    return 0
  fi

  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo ""
    return 0
  fi

  jq -r --arg email "$identifier" '
    (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
  ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1
}

# -----------------------------
# Dependencies
# -----------------------------
check_dependencies() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: Required command 'jq' not found."
    echo "On macOS install via Homebrew: brew install jq"
    exit 1
  fi
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
  if ! is_claude_running; then
    return 0
  fi

  echo "Claude Code is running. Please close it first."
  echo "Waiting for Claude Code to close..."

  while is_claude_running; do
    sleep 1
  done

  echo "Claude Code closed. Continuing..."
}

# -----------------------------
# Current account
# -----------------------------
get_current_account() {
  local cfg
  cfg="$(get_claude_config_path)"

  if [[ ! -f "$cfg" ]]; then
    echo "none"
    return 0
  fi

  if ! validate_json "$cfg"; then
    echo "none"
    return 0
  fi

  local email
  email="$(jq -r '.oauthAccount.emailAddress // empty' "$cfg" 2>/dev/null || true)"
  echo "${email:-none}"
}

# -----------------------------
# Credentials I/O
# -----------------------------
read_credentials() {
  local platform
  platform="$(detect_platform)"

  case "$platform" in
    macos)
      security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
      ;;
    linux|wsl)
      if [[ -f "$HOME/.claude/.credentials.json" ]]; then
        cat "$HOME/.claude/.credentials.json"
      else
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

write_credentials() {
  local credentials="$1"
  local platform
  platform="$(detect_platform)"

  case "$platform" in
    macos)
      # Store as generic password; -U updates if exists
      security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
      ;;
    linux|wsl)
      mkdir -p "$HOME/.claude"
      printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
      chmod 600 "$HOME/.claude/.credentials.json"
      ;;
  esac
}

read_account_credentials() {
  local account_num="$1"
  local email="$2"
  local platform
  platform="$(detect_platform)"

  case "$platform" in
    macos)
      security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
      ;;
    linux|wsl)
      local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      if [[ -f "$cred_file" ]]; then
        cat "$cred_file"
      else
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

write_account_credentials() {
  local account_num="$1"
  local email="$2"
  local credentials="$3"
  local platform
  platform="$(detect_platform)"

  case "$platform" in
    macos)
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
  local account_num="$1"
  local email="$2"
  local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

  if [[ -f "$config_file" ]]; then
    cat "$config_file"
  else
    echo ""
  fi
}

write_account_config() {
  local account_num="$1"
  local email="$2"
  local config="$3"
  local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

  printf '%s\n' "$config" > "$config_file"
  chmod 600 "$config_file"
}

# -----------------------------
# sequence.json lifecycle
# -----------------------------
init_sequence_file() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local init_content
    init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'"$now"'",
  "sequence": [],
  "accounts": {}
}'
    write_json "$SEQUENCE_FILE" "$init_content"
  fi
}

get_next_account_number() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "1"
    return 0
  fi

  jq -r '(.accounts | keys | map(tonumber) | max // 0) + 1' "$SEQUENCE_FILE"
}

account_exists() {
  local email="$1"
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    return 1
  fi

  jq -e --arg email "$email" '.accounts | to_entries[]? | select(.value.email == $email) | .key' \
    "$SEQUENCE_FILE" >/dev/null 2>&1
}

# -----------------------------
# Commands
# -----------------------------
cmd_add_account() {
  setup_directories
  init_sequence_file

  local current_email
  current_email="$(get_current_account)"

  if [[ "$current_email" == "none" ]]; then
    echo "Error: No active Claude account found. Please log in first."
    exit 1
  fi

  if account_exists "$current_email"; then
    echo "Account $current_email is already managed."
    exit 0
  fi

  local account_num
  account_num="$(get_next_account_number)"

  local cfg_path
  cfg_path="$(get_claude_config_path)"

  local current_creds current_config
  current_creds="$(read_credentials)"
  current_config="$(cat "$cfg_path")"

  if [[ -z "$current_creds" ]]; then
    echo "Error: No credentials found for current account"
    exit 1
  fi

  local account_uuid
  account_uuid="$(jq -r '.oauthAccount.accountUuid' "$cfg_path")"

  write_account_credentials "$account_num" "$current_email" "$current_creds"
  write_account_config "$account_num" "$current_email" "$current_config"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local updated
  updated="$(jq --arg num "$account_num" \
                --arg email "$current_email" \
                --arg uuid "$account_uuid" \
                --arg now "$now" '
    .accounts[$num] = { email: $email, uuid: $uuid, added: $now }
    | .sequence += [($num|tonumber)]
    | .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"

  write_json "$SEQUENCE_FILE" "$updated"
  echo "Added Account $account_num: $current_email"
}

cmd_remove_account() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 --remove-account <account_number|email>"
    exit 1
  fi

  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "Error: No accounts are managed yet"
    exit 1
  fi

  local identifier="$1"
  local account_num

  if [[ "$identifier" =~ ^[0-9]+$ ]]; then
    account_num="$identifier"
  else
    if ! validate_email "$identifier"; then
      echo "Error: Invalid email format: $identifier"
      exit 1
    fi
    account_num="$(resolve_account_identifier "$identifier")"
    if [[ -z "$account_num" ]]; then
      echo "Error: No account found with email: $identifier"
      exit 1
    fi
  fi

  local account_info
  account_info="$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")"
  if [[ -z "$account_info" ]]; then
    echo "Error: Account-$account_num does not exist"
    exit 1
  fi

  local email
  email="$(printf '%s' "$account_info" | jq -r '.email')"

  local active_account
  active_account="$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
  if [[ "$active_account" == "$account_num" ]]; then
    echo "Warning: Account-$account_num ($email) is currently active"
  fi

  echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
  local confirm
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled"
    exit 0
  fi

  local platform
  platform="$(detect_platform)"
  case "$platform" in
    macos)
      security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
      ;;
    linux|wsl)
      rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
      ;;
  esac
  rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local updated
  updated="$(jq --arg num "$account_num" --arg now "$now" '
    del(.accounts[$num])
    | .sequence = (.sequence | map(select(. != ($num|tonumber))))
    | .lastUpdated = $now
    | if .activeAccountNumber == ($num|tonumber) then .activeAccountNumber = null else . end
  ' "$SEQUENCE_FILE")"

  write_json "$SEQUENCE_FILE" "$updated"
  echo "Account-$account_num ($email) has been removed"
}

first_run_setup() {
  local current_email
  current_email="$(get_current_account)"
  if [[ "$current_email" == "none" ]]; then
    echo "No active Claude account found. Please log in first."
    return 1
  fi

  echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
  local response
  read -r response
  if [[ "$response" == "n" || "$response" == "N" ]]; then
    echo "Setup cancelled. You can run '$0 --add-account' later."
    return 1
  fi

  cmd_add_account
  return 0
}

cmd_list() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "No accounts are managed yet."
    first_run_setup || true
    exit 0
  fi

  local current_email
  current_email="$(get_current_account)"

  local active_account_num=""
  if [[ "$current_email" != "none" ]]; then
    active_account_num="$(jq -r --arg email "$current_email" '
      (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
    ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1)"
  fi

  echo "Accounts:"
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

# Compute next account using jq (no bash arrays)
get_next_in_sequence() {
  # Requires SEQUENCE_FILE to exist
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
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "Error: No accounts are managed yet"
    exit 1
  fi

  local current_email
  current_email="$(get_current_account)"
  if [[ "$current_email" == "none" ]]; then
    echo "Error: No active Claude account found"
    exit 1
  fi

  if ! account_exists "$current_email"; then
    echo "Notice: Active account '$current_email' was not managed."
    cmd_add_account
    local account_num
    account_num="$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
    echo "It has been automatically added as Account-$account_num."
    echo "Please run '$0 --switch' again to switch to the next account."
    exit 0
  fi

  # wait_for_claude_close

  local next_account
  next_account="$(get_next_in_sequence)"
  if [[ -z "$next_account" ]]; then
    echo "Error: No accounts in sequence."
    exit 1
  fi

  perform_switch "$next_account"
}

cmd_switch_to() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 --switch-to <account_number|email>"
    exit 1
  fi

  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    echo "Error: No accounts are managed yet"
    exit 1
  fi

  local identifier="$1"
  local target_account

  if [[ "$identifier" =~ ^[0-9]+$ ]]; then
    target_account="$identifier"
  else
    if ! validate_email "$identifier"; then
      echo "Error: Invalid email format: $identifier"
      exit 1
    fi
    target_account="$(resolve_account_identifier "$identifier")"
    if [[ -z "$target_account" ]]; then
      echo "Error: No account found with email: $identifier"
      exit 1
    fi
  fi

  local account_info
  account_info="$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")"
  if [[ -z "$account_info" ]]; then
    echo "Error: Account-$target_account does not exist"
    exit 1
  fi

  # wait_for_claude_close
  perform_switch "$target_account"
}

# Determine current managed account number from current email
get_current_managed_account_num() {
  local email="$1"
  if [[ "$email" == "none" || ! -f "$SEQUENCE_FILE" ]]; then
    echo ""
    return 0
  fi

  jq -r --arg email "$email" '
    (.accounts | to_entries[]? | select(.value.email == $email) | .key) // empty
  ' "$SEQUENCE_FILE" 2>/dev/null | head -n 1
}

perform_switch() {
  local target_account="$1"

  local target_email
  target_email="$(jq -r --arg num "$target_account" '.accounts[$num].email // empty' "$SEQUENCE_FILE")"
  if [[ -z "$target_email" ]]; then
    echo "Error: Could not resolve target account email."
    exit 1
  fi

  local current_email
  current_email="$(get_current_account)"

  local current_account
  current_account="$(get_current_managed_account_num "$current_email")"
  if [[ -z "$current_account" ]]; then
    # fallback to activeAccountNumber (might be null)
    current_account="$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE")"
  fi

  # Step 1: Backup current account (only if we can resolve it)
  local cfg_path
  cfg_path="$(get_claude_config_path)"

  local current_creds current_config
  current_creds="$(read_credentials)"
  current_config="$(cat "$cfg_path")"

  if [[ -n "$current_account" && "$current_account" != "null" && "$current_email" != "none" ]]; then
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
  fi

  # Step 2: Retrieve target account backup
  local target_creds target_config
  target_creds="$(read_account_credentials "$target_account" "$target_email")"
  target_config="$(read_account_config "$target_account" "$target_email")"

  if [[ -z "$target_creds" || -z "$target_config" ]]; then
    echo "Error: Missing backup data for Account-$target_account"
    exit 1
  fi

  # Step 3: Activate target creds
  write_credentials "$target_creds"

  local oauth_section
  oauth_section="$(printf '%s' "$target_config" | jq '.oauthAccount' 2>/dev/null || true)"
  if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
    echo "Error: Invalid oauthAccount in backup"
    exit 1
  fi

  local merged_config
  merged_config="$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$cfg_path" 2>/dev/null)"
  if [[ $? -ne 0 || -z "$merged_config" ]]; then
    echo "Error: Failed to merge config"
    exit 1
  fi

  write_json "$cfg_path" "$merged_config"

  # Step 4: Update state
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local updated
  updated="$(jq --arg num "$target_account" --arg now "$now" '
    .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"

  write_json "$SEQUENCE_FILE" "$updated"

  echo "Switched to Account-$target_account ($target_email)"
  cmd_list
  echo ""
  echo "Please restart Claude Code to use the new authentication."
  echo ""
}

show_usage() {
  echo "Multi-Account Switcher for Claude Code"
  echo "Usage: $0 [COMMAND]"
  echo ""
  echo "Commands:"
  echo "  --add-account                    Add current account to managed accounts"
  echo "  --remove-account <num|email>    Remove account by number or email"
  echo "  --list                           List all managed accounts"
  echo "  --switch                         Rotate to next account in sequence"
  echo "  --switch-to <num|email>          Switch to specific account number or email"
  echo "  --help                           Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --add-account"
  echo "  $0 --list"
  echo "  $0 --switch"
  echo "  $0 --switch-to 2"
  echo "  $0 --switch-to user@example.com"
  echo "  $0 --remove-account user@example.com"
}

main() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && ! is_running_in_container; then
    echo "Error: Do not run this script as root (unless running in a container)"
    exit 1
  fi

  check_dependencies

  case "${1:-}" in
    --add-account)
      cmd_add_account
      ;;
    --remove-account)
      shift
      cmd_remove_account "$@"
      ;;
    --list)
      cmd_list
      ;;
    --switch)
      cmd_switch
      ;;
    --switch-to)
      shift
      cmd_switch_to "$@"
      ;;
    --help|"")
      show_usage
      ;;
    *)
      echo "Error: Unknown command '$1'"
      show_usage
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi