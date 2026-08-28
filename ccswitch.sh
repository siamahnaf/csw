#!/usr/bin/env bash
# csw — Multi-Account Switcher for Claude Code (Bash 3.2 compatible)

set -euo pipefail

readonly CSW_VERSION="2.8.0"

# Repo info (used for update checks)
readonly CSW_REPO="siamahnaf/csw"
readonly CSW_DEFAULT_BRANCH="main"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly LOG_FILE="$BACKUP_DIR/csw.log"

# Background refresh state
readonly BG_DIR="$BACKUP_DIR/bg"
readonly BG_PID_FILE="$BG_DIR/worker.pid"
readonly BG_GEN_FILE="$BG_DIR/generation"
readonly BG_STATUS_DIR="$BG_DIR/status"
readonly BG_TS_DIR="$BG_DIR/last-refresh"
readonly BG_LOCK_DIR="$BG_DIR/locks"

# Gap between consecutive background refreshes (rate-limit friendly)
readonly BG_GAP_SECONDS=60
# Delay before the first background refresh, so it never overlaps the
# foreground refresh of the account being switched to
readonly BG_INITIAL_DELAY=5
# An account refreshed by csw within this window is left alone
readonly REFRESH_FRESH_WINDOW=21600   # 6 hours
# How long to wait for another process to release an account lock
readonly BG_LOCK_WAIT=15

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

# Append one refresh outcome to the log. Every refresh attempt logs exactly one
# line — success or failure — so `csw log` is never empty after a switch.
#   log_refresh <FG|BG> <account_num> <email> <message>
log_refresh() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] Account-$2 ($3): $4" >> "$LOG_FILE"
}

# -----------------------------
# Claude CLI version (cached, resolved on first use)
# -----------------------------
_cached_claude_cli_version=""
get_claude_cli_version() {
  if [[ -z "$_cached_claude_cli_version" ]]; then
    _cached_claude_cli_version="$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || echo '0.0.0')"
  fi
  printf '%s' "$_cached_claude_cli_version"
}

# -----------------------------
# Container detection
# -----------------------------
is_running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null && return 0
  [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null && return 0
  { [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; } && return 0
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

# Remove API-key-related settings so OAuth switching doesn't conflict.
# (Fixes "Auth conflict: token + /login managed key")
sanitize_config_json() {
  local json="$1"
  # Delete all known API-key/helper fields. Safe if absent.
  # Keep permissive (doesn't break older/newer configs).
  printf '%s' "$json" | jq '
    del(
      .apiKeyHelper,
      .apiKey,
      .anthropicApiKey,
      .claudeApiKey,
      .managedApiKey,
      .externalApiKey,
      .loginApiKey,
      .enterpriseApiKey,
      .organizationApiKey,
      .apiKeySource,
      .hasApiKey
    )
  ' 2>/dev/null || printf '%s' "$json"
}

# Remove API-key fields from credentials JSON, keeping only OAuth token.
# Prevents a stored backup that contains both OAuth + API key from
# reintroducing the auth-conflict warning when the backup is restored.
sanitize_credentials_json() {
  local json="$1"
  # -c = compact (no newlines). Newlines in Keychain values cause macOS to
  # return the data as hex on retrieval, breaking all subsequent reads.
  printf '%s' "$json" | jq -c '
    del(
      .apiKey,
      .anthropicApiKey,
      .claudeApiKey,
      .managedApiKey,
      .externalApiKey,
      .apiKeyHelper,
      .loginApiKey
    )
  ' 2>/dev/null || printf '%s' "$json"
}

# Proactively refresh the OAuth access token using the stored refreshToken.
# On success returns updated credentials JSON with a fresh accessToken, expiresAt,
# and (if the server rotates tokens) a new refreshToken.
# On ANY failure the original credentials are returned unchanged — the caller
# falls back gracefully.
#
# Return codes:
#   0 — token refreshed successfully (stdout has updated creds)
#   1 — no refreshToken stored in credentials
#   2 — network error (curl failed or timed out)
#   3 — server returned non-200 HTTP status (detail written to msg_file)
#   4 — server response missing access_token or malformed JSON
refresh_oauth_token() {
  local creds="$1"
  local msg_file="${2:-/dev/null}"
  printf '' > "$msg_file"
  local refresh_token
  refresh_token="$(printf '%s' "$creds" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)"
  [[ -z "$refresh_token" ]] && { printf '%s' "$creds"; return 1; }

  local tmp_body tmp_headers http_code
  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
  http_code="$(curl -s -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
    --max-time 15 \
    -X POST "https://platform.claude.com/v1/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "User-Agent: claude-cli/$(get_claude_cli_version)" \
    -H "anthropic-beta: oauth-2025-04-20" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$refresh_token" \
    --data-urlencode "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e" \
    2>/dev/null)" || { rm -f "$tmp_body" "$tmp_headers"; printf '%s' "$creds"; return 2; }

  local body headers
  body="$(cat "$tmp_body")"
  headers="$(cat "$tmp_headers")"
  rm -f "$tmp_body" "$tmp_headers"

  if [[ "$http_code" != "200" ]]; then
    # Extract rate-limit headers from Claude's response
    local retry_after requests_reset requests_remaining
    retry_after="$(printf '%s' "$headers" | grep -i '^retry-after:' | head -1 | sed 's/[^:]*:[[:space:]]*//' | tr -d '\r')"
    requests_reset="$(printf '%s' "$headers" | grep -i '^anthropic-ratelimit-requests-reset:' | head -1 | sed 's/[^:]*:[[:space:]]*//' | tr -d '\r')"
    requests_remaining="$(printf '%s' "$headers" | grep -i '^anthropic-ratelimit-requests-remaining:' | head -1 | sed 's/[^:]*:[[:space:]]*//' | tr -d '\r')"
    {
      printf '%s\n' "$body"
      printf 'HTTP_STATUS=%s\n' "$http_code"
      printf 'RETRY_AFTER=%s\n' "$retry_after"
      printf 'REQUESTS_RESET=%s\n' "$requests_reset"
      printf 'REQUESTS_REMAINING=%s\n' "$requests_remaining"
    } > "$msg_file"
    printf '%s' "$creds"
    return 3
  fi

  local access_token expires_in new_refresh_token
  access_token="$(printf '%s' "$body" | jq -r '.access_token // empty' 2>/dev/null)"
  expires_in="$(printf '%s' "$body" | jq -r '.expires_in // 28800' 2>/dev/null)"
  new_refresh_token="$(printf '%s' "$body" | jq -r '.refresh_token // empty' 2>/dev/null)"

  [[ -z "$access_token" ]] && { printf '%s' "$creds"; return 4; }

  local expires_at
  expires_at="$(( $(date +%s) * 1000 + expires_in * 1000 ))"
  # Keep old refresh token if server didn't issue a new one (non-rotating flow)
  [[ -z "$new_refresh_token" ]] && new_refresh_token="$refresh_token"

  local updated_creds
  updated_creds="$(printf '%s' "$creds" | jq -c \
    --arg  at "$access_token" \
    --argjson ea "$expires_at" \
    --arg  rt "$new_refresh_token" '
      if .claudeAiOauth then
        .claudeAiOauth.accessToken  = $at
        | .claudeAiOauth.expiresAt  = $ea
        | .claudeAiOauth.refreshToken = $rt
      else . end
    ' 2>/dev/null)" || { printf '%s' "$creds"; return 4; }

  printf '%s' "$updated_creds"
  return 0
}

# -----------------------------
# Background refresh: state helpers
#
# Inactive accounts are refreshed by a detached worker, one at a time with a
# gap between each, so we never burst requests at the OAuth server.
#
# Two invariants keep this safe against Anthropic's rotating refresh tokens
# (where refreshing with an already-used token revokes the whole token family):
#
#   1. Per-account mkdir lock — no two processes ever refresh the same account
#      concurrently, so the same refresh token is never presented twice.
#   2. Generation counter — a superseded worker stops cooperatively at its next
#      checkpoint instead of being killed, so it can never be signalled away
#      mid-refresh with a rotated-but-unsaved token.
# -----------------------------
bg_setup_dirs() {
  mkdir -p "$BG_DIR" "$BG_STATUS_DIR" "$BG_TS_DIR" "$BG_LOCK_DIR"
  chmod 700 "$BG_DIR" "$BG_STATUS_DIR" "$BG_TS_DIR" "$BG_LOCK_DIR" 2>/dev/null || true
}

now_epoch() { date +%s; }

# Absolute path to this script, so the worker can re-exec it detached.
script_path() {
  local p="${BASH_SOURCE[0]}"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$PWD" "$p" ;;
  esac
}

# Stamp the time of a successful refresh (drives the "Already refreshed" rule).
record_refresh_time() {
  bg_setup_dirs
  printf '%s\n' "$(now_epoch)" > "$BG_TS_DIR/$1"
}

# Seconds since csw last refreshed this account; returns 1 if never.
refresh_age_seconds() {
  local f="$BG_TS_DIR/$1" ts
  [[ -f "$f" ]] || return 1
  ts="$(head -n 1 "$f" 2>/dev/null || true)"
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  echo $(( $(now_epoch) - ts ))
}

_rough_duration() {
  local s="$1"
  if (( s < 60 )); then       echo "${s}s"
  elif (( s < 3600 )); then   echo "$(( s / 60 ))m"
  else                        echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  fi
}

human_duration() { echo "$(_rough_duration "$1") ago"; }
human_until()    { local s="$1"; (( s <= 0 )) && { echo "now"; return; }; echo "in $(_rough_duration "$s")"; }

# Wall-clock HH:MM:SS for an epoch (BSD `date -r`, GNU `date -d @`).
epoch_to_hms() {
  local e="$1"
  [[ "$e" =~ ^[0-9]+$ ]] || { echo "--:--:--"; return; }
  date -r "$e" '+%H:%M:%S' 2>/dev/null \
    || date -d "@$e" '+%H:%M:%S' 2>/dev/null \
    || echo "--:--:--"
}

# When the sleeping worker will fire next (epoch), or empty if not scheduled.
bg_next_run_epoch() {
  local f="$BG_DIR/next-run" v
  [[ -f "$f" ]] || return 1
  v="$(head -n 1 "$f" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

bg_set_next_run()   { bg_setup_dirs; printf '%s\n' "$1" > "$BG_DIR/next-run"; }
bg_clear_next_run() { rm -f "$BG_DIR/next-run"; }
# A retiring worker must not delete the schedule a newer run just published.
bg_clear_next_run_if_mine() { bg_generation_is_mine "$1" && bg_clear_next_run; return 0; }

# Per-account status, one file per account so concurrent writers never clash.
# Field 5 is the epoch of the transition, so `csw log` can show when each
# account was actually refreshed without parsing the log.
#   bg_set_status <num> <email> <PENDING|RUNNING|SUCCESS|FAILED|SKIPPED|ALREADY|CANCELLED> [detail]
bg_set_status() {
  bg_setup_dirs
  local detail; detail="$(printf '%s' "${4:-}" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$detail" "$(now_epoch)" > "$BG_STATUS_DIR/$1"
}

bg_get_status_field() {
  local num="$1" field="$2" f="$BG_STATUS_DIR/$1"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v n="$field" 'NR==1{print $n}' "$f" 2>/dev/null
}

# -----------------------------
# Background refresh: per-account locks (mkdir is atomic everywhere)
# -----------------------------
acct_lock_acquire() {
  # NOTE: bash 3.2 creates all names in a `local` list before assigning, so a
  # later item cannot reference an earlier one. Keep these separate.
  local num="$1" timeout="${2:-0}" waited=0 owner=""
  local lock="$BG_LOCK_DIR/$num.lock"
  bg_setup_dirs
  while ! mkdir "$lock" 2>/dev/null; do
    # Reclaim a lock whose owner died (crash, reboot, kill -9)
    owner="$(head -n 1 "$lock/pid" 2>/dev/null || true)"
    if [[ ! "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    (( waited >= timeout )) && return 1
    sleep 1
    waited=$(( waited + 1 ))
  done
  printf '%s\n' "$$" > "$lock/pid"
  return 0
}

acct_lock_release() {
  rm -rf "$BG_LOCK_DIR/$1.lock"
}

# -----------------------------
# Background refresh: generation / cancellation
# -----------------------------
bg_current_generation() {
  [[ -f "$BG_GEN_FILE" ]] && head -n 1 "$BG_GEN_FILE" 2>/dev/null || true
}

# True while this worker is still the current one.
bg_generation_is_mine() {
  [[ "$(bg_current_generation)" == "$1" ]]
}

bg_worker_alive() {
  local pid=""
  [[ -f "$BG_PID_FILE" ]] && pid="$(head -n 1 "$BG_PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Interruptible sleep: polls the generation file so a superseded worker stops
# within a second instead of sitting out a full gap.
bg_sleep_cancellable() {
  local total="$1" gen="$2" elapsed=0
  while (( elapsed < total )); do
    sleep 1
    elapsed=$(( elapsed + 1 ))
    bg_generation_is_mine "$gen" || return 1
  done
  return 0
}

# Supersede any in-flight worker: bump the generation, then log every account
# still queued as cancelled and clear the old queue. The old worker is
# deliberately NOT killed — it notices the new generation and stops on its own
# at a safe point.
#   bg_cancel_previous <keep_num>
# keep_num's status file is left alone: the foreground refresh of the account
# being switched to has already written this run's status there.
bg_cancel_previous() {
  local keep_num="${1:-}"
  bg_setup_dirs
  local had_pending=0 num email status
  if [[ -d "$BG_STATUS_DIR" ]]; then
    for f in "$BG_STATUS_DIR"/*; do
      [[ -f "$f" ]] || continue
      [[ -n "$keep_num" && "$(basename "$f")" == "$keep_num" ]] && continue
      IFS=$'\t' read -r num email status _ < "$f" || continue
      if [[ "$status" == "PENDING" || "$status" == "RUNNING" ]]; then
        had_pending=1
        log_refresh BG "$num" "$email" "Cancelled — superseded by a newer switch."
      fi
      rm -f "$f"
    done
  fi
  return $(( 1 - had_pending ))
}

# -----------------------------
# Background refresh: worker
# -----------------------------
# Refresh one account under its lock. Never exits non-zero — a single account
# failing must not abort the rest of the queue.
bg_refresh_one() {
  local num="$1" email="$2"

  if ! acct_lock_acquire "$num" "$BG_LOCK_WAIT"; then
    bg_set_status "$num" "$email" "FAILED" "Locked by another csw process"
    log_refresh BG "$num" "$email" "Skipped — account lock held by another csw process."
    return 0
  fi

  bg_set_status "$num" "$email" "RUNNING" ""
  # Re-publish the next fire time from *now*, so the schedule shown by
  # `csw log` stays correct while this refresh is in flight (the value written
  # before the sleep is in the past by the time we get here).
  bg_set_next_run "$(( $(now_epoch) + BG_GAP_SECONDS ))"

  local creds rc=0 msg_file new_creds
  creds="$(read_account_credentials "$num" "$email")"
  if [[ -z "$creds" ]]; then
    acct_lock_release "$num"
    bg_set_status "$num" "$email" "FAILED" "No stored credentials"
    log_refresh BG "$num" "$email" "Failed — no stored credentials found."
    return 0
  fi

  msg_file="$(mktemp)"
  new_creds="$(refresh_oauth_token "$creds" "$msg_file")" || rc=$?
  case $rc in
    0)
      if write_account_credentials "$num" "$email" "$new_creds"; then
        record_refresh_time "$num"
        bg_set_status "$num" "$email" "SUCCESS" ""
        log_refresh BG "$num" "$email" "Token refreshed successfully."
      else
        # Refresh succeeded server-side but the new token could not be stored:
        # the stored token is now the invalidated one. Say so loudly.
        bg_set_status "$num" "$email" "FAILED" "Refreshed but could not save — re-login may be needed"
        log_refresh BG "$num" "$email" "Failed — token refreshed but could not be saved to backup. Re-login with: claude login"
      fi
      ;;
    1)
      bg_set_status "$num" "$email" "SKIPPED" "No refreshToken stored"
      log_refresh BG "$num" "$email" "Skipped — no refreshToken in stored credentials."
      ;;
    2)
      bg_set_status "$num" "$email" "FAILED" "Network error"
      log_refresh BG "$num" "$email" "Failed — network error (curl failed or timed out)."
      ;;
    3)
      local http_status retry_after detail
      http_status="$(grep '^HTTP_STATUS=' "$msg_file" 2>/dev/null | sed 's/HTTP_STATUS=//' || true)"
      retry_after="$(grep '^RETRY_AFTER=' "$msg_file" 2>/dev/null | sed 's/RETRY_AFTER=//' || true)"
      detail="HTTP ${http_status:-unknown}"
      [[ -n "$retry_after" ]] && detail="$detail, retry after ${retry_after}s"
      bg_set_status "$num" "$email" "FAILED" "$detail"
      log_refresh BG "$num" "$email" "Failed — $detail from Claude server."
      ;;
    4)
      bg_set_status "$num" "$email" "FAILED" "Invalid server response"
      log_refresh BG "$num" "$email" "Failed — invalid or empty response (missing access_token or malformed JSON)."
      ;;
  esac
  rm -f "$msg_file"
  acct_lock_release "$num"
  return 0
}

# Entry point for the detached worker process: `csw --bg-refresh <generation>`.
bg_worker_main() {
  local gen="${1:-}"
  [[ -z "$gen" ]] && return 0

  # Walk the queue this switch wrote. Sorted numerically for stable ordering.
  local queue num email status first=1
  # The `if` (rather than `[[ ... ]] &&`) and the trailing `|| true` are both
  # load-bearing: with pipefail, a loop whose last command is a false test
  # makes the whole command substitution return non-zero, and set -e would
  # kill this worker silently before it refreshed anything.
  queue="$(
    for f in "$BG_STATUS_DIR"/*; do
      [[ -f "$f" ]] || continue
      IFS=$'\t' read -r num email status _ < "$f" || continue
      if [[ "$status" == "PENDING" ]]; then
        printf '%s\t%s\n' "$num" "$email"
      fi
    done | sort -n -k1,1
  )" || true
  [[ -z "$queue" ]] && return 0

  while IFS=$'\t' read -r num email; do
    [[ -z "$num" ]] && continue
    bg_generation_is_mine "$gen" || return 0
    local delay
    if (( first )); then delay="$BG_INITIAL_DELAY"; first=0; else delay="$BG_GAP_SECONDS"; fi
    # Publish the next fire time so `csw log` can show a schedule.
    bg_set_next_run "$(( $(now_epoch) + delay ))"
    # Superseded: return without touching next-run, which now belongs to the
    # newer run.
    bg_sleep_cancellable "$delay" "$gen" || return 0
    # Re-check right before touching a token — the cheapest possible moment
    # to discover we have been superseded.
    bg_generation_is_mine "$gen" || return 0
    # Status may have been rewritten while we slept; skip if no longer pending.
    status="$(bg_get_status_field "$num" 3 || true)"
    [[ "$status" == "PENDING" ]] || continue
    bg_refresh_one "$num" "$email"
  done <<< "$queue"

  bg_clear_next_run_if_mine "$gen"
  return 0
}

# Build the queue for this switch and spawn the detached worker.
# Accounts refreshed within REFRESH_FRESH_WINDOW are marked ALREADY and skipped.
bg_start_refresh() {
  local target_num="$1"
  bg_setup_dirs

  local gen queued=0 skipped=0 num email age
  gen="$(now_epoch)-$$"

  # Bump the generation BEFORE queueing so any in-flight worker stops before
  # it can act on entries this run is about to rewrite.
  printf '%s\n' "$gen" > "$BG_GEN_FILE"
  bg_cancel_previous "$target_num" && info "Cancelled pending background refreshes from the previous switch."

  while IFS= read -r num; do
    [[ -z "$num" || "$num" == "$target_num" ]] && continue
    email="$(jq -r --arg n "$num" '.accounts[$n].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)"
    [[ -z "$email" ]] && continue

    age="$(refresh_age_seconds "$num" || true)"
    if [[ -n "$age" ]] && (( age < REFRESH_FRESH_WINDOW )); then
      bg_set_status "$num" "$email" "ALREADY" "$(human_duration "$age")"
      log_refresh BG "$num" "$email" "Already refreshed $(human_duration "$age") — skipped."
      skipped=$(( skipped + 1 ))
      continue
    fi

    bg_set_status "$num" "$email" "PENDING" ""
    queued=$(( queued + 1 ))
  done < <(jq -r '.sequence[]? | tostring' "$SEQUENCE_FILE" 2>/dev/null || true)

  (( skipped > 0 )) && info "Skipped $skipped account(s) refreshed within the last 6 hours."

  if (( queued == 0 )); then
    rm -f "$BG_PID_FILE"
    bg_clear_next_run
    info "No accounts need a background refresh."
    return 0
  fi

  # Publish the first fire time up front so `csw log` shows a schedule even
  # before the worker has taken its first breath.
  bg_set_next_run "$(( $(now_epoch) + BG_INITIAL_DELAY ))"

  local self; self="$(script_path)"
  nohup /bin/bash "$self" --bg-refresh "$gen" >/dev/null 2>&1 &
  local worker_pid=$!
  disown "$worker_pid" 2>/dev/null || true
  printf '%s\n' "$worker_pid" > "$BG_PID_FILE"

  info "Queued $queued account(s) for background refresh (${BG_GAP_SECONDS}s apart)."
  dimln "  Track progress with: csw log"
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
  local latest check_rc=0
  latest="$(_check_update_available)" || check_rc=$?

  case $check_rc in
    0)
      warn "Update available: ${CSW_VERSION} -> ${latest}"
      info "Run: csw --update"
      ;;
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

  local tmp repo_dir install_rc=0
  tmp="$(mktemp -d)"

  curl -fsSL "$tarball_url" -o "$tmp/repo.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/repo.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }

  repo_dir="$(find "$tmp" -maxdepth 1 -type d -name 'csw-*' | head -n 1)"
  if [[ -z "${repo_dir:-}" || ! -d "$repo_dir" ]]; then
    error "Could not locate extracted repo folder."
    rm -rf "$tmp"
    return 1
  fi

  cp -f "$repo_dir/ccswitch.sh" "$lib_dir/ccswitch.sh" && \
  cp -f "$repo_dir/bin/csw" "$bin_dir/csw" && \
  chmod +x "$lib_dir/ccswitch.sh" "$bin_dir/csw" || install_rc=$?

  rm -rf "$tmp"
  [[ $install_rc -ne 0 ]] && { error "Failed to copy files"; return 1; }

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
  mkdir -p "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials"
  chmod 700 "$BACKUP_DIR" "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials"
  bg_setup_dirs
}

# -----------------------------
# Claude process detection
# -----------------------------
is_claude_running() {
  ps -eo pid,comm,args | awk 'BEGIN{f=0} $2 == "claude" || $3 == "claude" {f=1; exit} END{exit !f}'
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
# FIX: macOS Keychain credential service mismatch (space-safe)
# -----------------------------
_keychain_services() {
  printf '%s\n' "Claude Code-credentials" "Claude Code"
}

_keychain_read_service() {
  local service="$1"
  local data
  data="$(security find-generic-password -s "$service" -w 2>/dev/null)" || true
  [[ -z "$data" ]] && return 0
  # macOS Keychain returns binary/control-char data (e.g. JSON with newlines)
  # as a lowercase hex string. Detect and decode that before returning.
  if [[ $(( ${#data} % 2 )) -eq 0 ]] && printf '%s' "$data" | grep -qxE '[0-9a-fA-F]+'; then
    local decoded
    decoded="$(printf '%s' "$data" | xxd -r -p 2>/dev/null)" || true
    if [[ -n "$decoded" ]] && printf '%s' "$decoded" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$decoded"
      return 0
    fi
  fi
  printf '%s' "$data"
}

_keychain_write_service() {
  local service="$1" payload="$2"
  security add-generic-password -U -s "$service" -a "$USER" -w "$payload" 2>/dev/null
}

_keychain_delete_service() {
  local service="$1"
  # Delete all entries for this service (loop because there may be multiple account names)
  while security delete-generic-password -s "$service" 2>/dev/null; do :; done
  return 0
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
      # Always compact before writing: Keychain returns data with newlines as
      # hex on retrieval, which breaks all future reads.
      local compact_creds
      compact_creds="$(printf '%s' "$credentials" | jq -c . 2>/dev/null)" || compact_creds="$credentials"
      # Write only to the primary service ("Claude Code-credentials").
      # Writing to the legacy "Claude Code" service creates a Keychain entry that
      # Claude Code interprets as a managed/API key, triggering the auth-conflict
      # warning "Both a token (claude.ai) and an API key (/login managed key) are set."
      _keychain_write_service "Claude Code-credentials" "$compact_creds"
      # Remove any leftover "Claude Code" entry (old API key or stale csw write)
      # so Claude Code cannot detect a false managed-key conflict.
      _keychain_delete_service "Claude Code"
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
    macos) _keychain_read_service "Claude Code-Account-${account_num}-${email}" ;;
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
      # Compact before storing to prevent hex-encoding on retrieval.
      local compact_creds
      compact_creds="$(printf '%s' "$credentials" | jq -c . 2>/dev/null)" || compact_creds="$credentials"
      security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$compact_creds" 2>/dev/null
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

  [[ -z "$current_creds" ]] && { error "No credentials found/readable for current account (Keychain service mismatch or permissions)."; exit 1; }

  # Sanitize both credentials and config before storing backup
  # (prevents auth conflict when backup is restored during a switch)
  current_creds="$(sanitize_credentials_json "$current_creds")"
  current_config="$(sanitize_config_json "$current_config")"

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
  # Sanitize both before storing backup to prevent auth conflict on restore
  current_creds="$(sanitize_credentials_json "$current_creds")"
  current_config="$(sanitize_config_json "$current_config")"

  if [[ -n "$current_account" && "$current_account" != "null" && "$current_email" != "none" ]]; then
    step "Saving current account backup..."
    if [[ -n "$current_creds" ]]; then
      if ! write_account_credentials "$current_account" "$current_email" "$current_creds"; then
        warn "Failed to save credentials for Account-$current_account; skipping credentials backup."
      fi
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
  # Defense-in-depth: sanitize target credentials before applying
  # (handles old backups that may have been stored without sanitization)
  target_creds="$(sanitize_credentials_json "$target_creds")"

  # Proactively refresh the OAuth token so restored credentials are always
  # current regardless of how long ago this account was last used.
  # If the refresh succeeds the new accessToken/expiresAt/refreshToken are
  # used; if it fails for any reason the stored credentials are used as-is
  # (same behaviour as before — works until the stored accessToken expires).
  # Clear log file — csw log only shows the current switch run
  printf '' > "$LOG_FILE"
  bg_setup_dirs
  printf '%s\n' "$(now_epoch)" > "$BG_DIR/last-switch"

  step "Refreshing OAuth token for Account-$target_account..."
  # Take the account lock so a background worker from an earlier switch can
  # never refresh this same account at the same moment (rotating refresh
  # tokens would revoke the token family).
  local fg_locked=0
  if acct_lock_acquire "$target_account" "$BG_LOCK_WAIT"; then
    fg_locked=1
  else
    warn "Another csw process is refreshing this account — using stored credentials."
    log_refresh FG "$target_account" "$target_email" "Skipped — account lock held by another csw process."
  fi

  local fg_msg_file; fg_msg_file="$(mktemp)"
  local refreshed_creds refresh_rc=0
  if (( fg_locked )); then
    refreshed_creds="$(refresh_oauth_token "$target_creds" "$fg_msg_file")" || refresh_rc=$?
  else
    refresh_rc=5
  fi
  case $refresh_rc in
    0)
      target_creds="$refreshed_creds"
      write_account_credentials "$target_account" "$target_email" "$refreshed_creds"
      record_refresh_time "$target_account"
      bg_set_status "$target_account" "$target_email" "SUCCESS" ""
      log_refresh FG "$target_account" "$target_email" "Token refreshed successfully."
      success "Token refreshed successfully — new access token applied and saved to backup."
      ;;
    1)
      bg_set_status "$target_account" "$target_email" "SKIPPED" "No refreshToken stored"
      log_refresh FG "$target_account" "$target_email" "Skipped — no refreshToken in stored credentials."
      warn "Token refresh skipped — no refreshToken found in stored credentials."
      info "The account will use its existing access token (valid until it expires)."
      ;;
    2)
      bg_set_status "$target_account" "$target_email" "FAILED" "Network error"
      log_refresh FG "$target_account" "$target_email" "Failed — network error (curl failed or timed out)."
      warn "Token refresh failed — network error (no internet or server unreachable)."
      info "Using stored credentials as-is. If the access token has expired, re-login with: claude login"
      ;;
    3)
      local raw_response http_status retry_after requests_reset requests_remaining
      raw_response="$(sed -e '/^HTTP_STATUS=/d' -e '/^RETRY_AFTER=/d' -e '/^REQUESTS_RESET=/d' -e '/^REQUESTS_REMAINING=/d' "$fg_msg_file" 2>/dev/null)"
      # `|| true` is required: these keys are optional, and pipefail would make
      # a non-matching grep abort the script mid-diagnostic.
      http_status="$(grep '^HTTP_STATUS=' "$fg_msg_file" 2>/dev/null | sed 's/HTTP_STATUS=//' || true)"
      retry_after="$(grep '^RETRY_AFTER=' "$fg_msg_file" 2>/dev/null | sed 's/RETRY_AFTER=//' || true)"
      requests_reset="$(grep '^REQUESTS_RESET=' "$fg_msg_file" 2>/dev/null | sed 's/REQUESTS_RESET=//' || true)"
      requests_remaining="$(grep '^REQUESTS_REMAINING=' "$fg_msg_file" 2>/dev/null | sed 's/REQUESTS_REMAINING=//' || true)"
      local log_detail="Failed — HTTP ${http_status:-unknown} from Claude server."
      [[ -n "$retry_after" ]] && log_detail="$log_detail Retry after ${retry_after}s."
      [[ -n "$requests_reset" ]] && log_detail="$log_detail Rate limit resets at ${requests_reset}."
      bg_set_status "$target_account" "$target_email" "FAILED" "HTTP ${http_status:-unknown}${retry_after:+, retry after ${retry_after}s}"
      log_refresh FG "$target_account" "$target_email" "$log_detail"
      warn "Token refresh failed — HTTP $http_status from Claude server."
      if [[ -n "$raw_response" ]]; then
        info "Claude server response:"
        printf "  %s\n" "$raw_response"
      fi
      if [[ -n "$retry_after" ]]; then
        info "Retry after: ${retry_after} seconds."
      fi
      if [[ -n "$requests_reset" ]]; then
        info "Rate limit resets at: ${requests_reset}"
      fi
      if [[ -n "$requests_remaining" ]]; then
        info "Requests remaining: ${requests_remaining}"
      fi
      info "Re-login with: claude login"
      ;;
    4)
      bg_set_status "$target_account" "$target_email" "FAILED" "Invalid server response"
      log_refresh FG "$target_account" "$target_email" "Failed — invalid or empty response (missing access_token or malformed JSON)."
      warn "Token refresh failed — server returned an invalid or empty response."
      info "Using stored credentials as-is. If login fails, re-authenticate with: claude login"
      ;;
    5)
      bg_set_status "$target_account" "$target_email" "SKIPPED" "Locked by another csw process"
      info "Using stored credentials as-is (refresh skipped — account was locked)."
      ;;
  esac
  rm -f "$fg_msg_file"
  (( fg_locked )) && acct_lock_release "$target_account"

  step "Applying target credentials/config..."
  write_credentials "$target_creds"

  local oauth_section
  oauth_section="$(printf '%s' "$target_config" | jq '.oauthAccount' 2>/dev/null || true)"
  [[ -z "$oauth_section" || "$oauth_section" == "null" ]] && { error "Invalid oauthAccount in backup"; exit 1; }

  # Merge oauthAccount from target and strip all API-key fields to avoid auth-conflict warning
  local merged_config merge_rc=0
  merged_config="$(jq --argjson oauth "$oauth_section" '
      del(
        .apiKeyHelper, .apiKey, .anthropicApiKey, .claudeApiKey,
        .managedApiKey, .externalApiKey,
        .loginApiKey, .enterpriseApiKey, .organizationApiKey,
        .apiKeySource, .hasApiKey
      )
      | .oauthAccount = $oauth
    ' "$cfg_path" 2>/dev/null)" || merge_rc=$?
  [[ $merge_rc -ne 0 || -z "$merged_config" ]] && { error "Failed to merge config"; exit 1; }

  write_json "$cfg_path" "$merged_config"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local updated
  updated="$(jq --arg num "$target_account" --arg now "$now" '
    .activeAccountNumber = ($num|tonumber)
    | .lastUpdated = $now
  ' "$SEQUENCE_FILE")"
  write_json "$SEQUENCE_FILE" "$updated"

  success "Switched to Account-$target_account ($target_email)"

  # Warm every other account's token in the background, one at a time.
  #
  # CAUTION: Anthropic's OAuth server uses ROTATING refresh tokens with reuse
  # detection — each successful refresh invalidates the previous refresh token,
  # and presenting an already-used one revokes the entire token family
  # (HTTP 400 invalid_grant — "Refresh token not found or invalid").
  #
  # bg_start_refresh is built around that: per-account mkdir locks make a
  # double refresh of one account impossible, and the generation counter
  # retires a superseded worker cooperatively rather than signalling it away
  # mid-refresh. Do not add a `kill` to the cancellation path — killing a
  # worker between "server rotated the token" and "token saved to backup" is
  # exactly what strands an account needing `claude login`.
  step "Starting background refresh for other accounts..."
  bg_start_refresh "$target_account"

  cmd_list
  echo ""
  warn "Please restart Claude Code to use the new authentication."
  echo ""
}

# -----------------------------
# csw log — status table
# -----------------------------
_repeat() {
  local n="$1" ch="$2" out="" i=0
  while (( i < n )); do out="$out$ch"; i=$(( i + 1 )); done
  printf '%s' "$out"
}

# Pad a plain-text cell to a width, then colorize. Colors are applied AFTER
# measuring so escape bytes never skew the column alignment.
_cell() {
  local text="$1" width="$2" color="${3:-}"
  local pad=$(( width - ${#text} ))
  (( pad < 0 )) && pad=0
  printf '%s%s%s%s' "$color" "$text" "${color:+$RESET}" "$(_repeat "$pad" ' ')"
}

# One horizontal rule for the status table. $1/$2/$3 are the left, junction
# and right glyphs; the rest are column widths.
_table_rule() {
  local left="$1" mid="$2" right="$3"; shift 3
  local out="" w first=1
  for w in "$@"; do
    if (( first )); then first=0; else out="${out}${mid}"; fi
    # Braces are required: a bare $out followed by a multibyte glyph gets
    # parsed as part of the variable name.
    out="${out}─$(_repeat "$w" "─")─"
  done
  printf '  %s%s%s%s%s' "$DIM" "$left" "$out" "$right" "$RESET"
}

# Print one table row. Relies on $bar from the calling scope (bash dynamic
# scoping) so every row shares the caller's separator styling.
_print_row() {
  printf '  %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
    "$bar" "$1" "$bar" "$2" "$bar" "$3" "$bar" "$4" "$bar" "$5" "$bar" "$6" "$bar"
}

# Map a status to its display word + color. Sets _st_word / _st_color / _st_note.
_status_display() {
  local status="$1" detail="$2" worker_alive="$3"
  _st_note="$detail"
  case "$status" in
    SUCCESS)   _st_word="Success";   _st_color="$GREEN" ;;
    RUNNING)   _st_word="Refreshing";_st_color="$CYAN";   _st_note="in progress" ;;
    PENDING)
      if (( worker_alive )); then
        _st_word="Pending"; _st_color="$YELLOW"
      else
        _st_word="Stalled"; _st_color="$RED"; _st_note="worker gone; run csw switch"
      fi
      ;;
    ALREADY)   _st_word="Fresh";     _st_color="$BLUE";   _st_note="refreshed ${detail:-recently}" ;;
    SKIPPED)   _st_word="Skipped";   _st_color="$YELLOW" ;;
    FAILED)    _st_word="Failed";    _st_color="$RED" ;;
    CANCELLED) _st_word="Cancelled"; _st_color="$DIM";    _st_note="superseded" ;;
    *)         _st_word="${status:-Not queued}"; _st_color="$DIM" ;;
  esac
}

cmd_log() {
  local show_raw=0
  case "${1:-}" in
    -v|--verbose|--full|-a|--all) show_raw=1 ;;
    "") ;;
    *) warn "Unknown option '$1' — showing the status table."; dimln "  Raw log entries: csw log -v" ;;
  esac

  local have_log=0 have_status=0
  [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]] && have_log=1
  [[ -d "$BG_STATUS_DIR" ]] && [[ -n "$(ls -A "$BG_STATUS_DIR" 2>/dev/null || true)" ]] && have_status=1
  if (( have_log == 0 && have_status == 0 )); then
    info "No refresh activity recorded yet. Run: csw switch"
    return 0
  fi
  if [[ ! -f "$SEQUENCE_FILE" ]]; then
    info "No managed accounts yet. Run: csw add-account"
    return 0
  fi

  local worker_alive=0; bg_worker_alive && worker_alive=1
  local active_num next_run now last_switch
  active_num="$(jq -r '.activeAccountNumber // empty | tostring' "$SEQUENCE_FILE" 2>/dev/null || true)"
  now="$(now_epoch)"
  next_run="$(bg_next_run_epoch || true)"
  last_switch="$(head -n 1 "$BG_DIR/last-switch" 2>/dev/null || true)"

  # ---- Pass 1: gather rows, measure column widths ----
  # Parallel arrays (bash 3.2 has no associative arrays).
  local -a r_num r_email r_mode r_word r_color r_note r_when
  local col_acct=7 col_status=6 col_note=6 col_num=1
  local acct_num acct_email status detail ts pending_seen=0 queued_total=0 running_total=0
  local _st_word _st_color _st_note

  while IFS= read -r acct_num; do
    acct_email="$(jq -r --arg num "$acct_num" '.accounts[$num].email // empty' "$SEQUENCE_FILE" 2>/dev/null || true)"
    [[ -z "$acct_email" ]] && continue

    status="$(bg_get_status_field "$acct_num" 3 2>/dev/null || true)"
    detail="$(bg_get_status_field "$acct_num" 4 2>/dev/null || true)"
    ts="$(bg_get_status_field "$acct_num" 5 2>/dev/null || true)"

    # An ALREADY row was skipped *because* it was refreshed earlier, so its
    # "When" is that earlier refresh — not when this switch wrote the status.
    if [[ "$status" == "ALREADY" ]]; then
      local prev_ts
      prev_ts="$(head -n 1 "$BG_TS_DIR/$acct_num" 2>/dev/null || true)"
      [[ "$prev_ts" =~ ^[0-9]+$ ]] && ts="$prev_ts"
    fi

    _status_display "$status" "$detail" "$worker_alive"

    # "When": completed rows show when it happened; queued rows show the
    # projected fire time (next_run + position * gap), matching the worker's
    # own pacing.
    local when="-"
    if [[ "$status" == "PENDING" ]]; then
      # Counted whether or not the worker is alive, so a stalled queue is
      # never reported as settled.
      queued_total=$(( queued_total + 1 ))
      if (( worker_alive )) && [[ -n "$next_run" ]]; then
        local eta=$(( next_run + pending_seen * BG_GAP_SECONDS ))
        (( eta < now )) && eta=$now
        when="$(epoch_to_hms "$eta")"
        _st_note="due $(human_until $(( eta - now )))"
      elif (( worker_alive )); then
        when="queued"
      fi
      pending_seen=$(( pending_seen + 1 ))
    elif [[ "$status" == "RUNNING" ]]; then
      running_total=$(( running_total + 1 ))
      when="now"
    elif [[ "$ts" =~ ^[0-9]+$ ]]; then
      when="$(epoch_to_hms "$ts")"
      [[ -z "$_st_note" ]] && _st_note="$(human_duration $(( now - ts )))"
    fi

    r_num[${#r_num[@]}]="$acct_num"
    r_email[${#r_email[@]}]="$acct_email"
    if [[ "$acct_num" == "$active_num" ]]; then
      r_mode[${#r_mode[@]}]="fg"
    else
      r_mode[${#r_mode[@]}]="bg"
    fi
    r_word[${#r_word[@]}]="$_st_word"
    r_color[${#r_color[@]}]="$_st_color"
    r_note[${#r_note[@]}]="$_st_note"
    r_when[${#r_when[@]}]="$when"

    (( ${#acct_num} > col_num ))     && col_num=${#acct_num}
    (( ${#acct_email} > col_acct ))  && col_acct=${#acct_email}
    (( ${#_st_word}  > col_status )) && col_status=${#_st_word}
    (( ${#_st_note}  > col_note ))   && col_note=${#_st_note}
  done < <(jq -r '.sequence[]? | tostring' "$SEQUENCE_FILE" 2>/dev/null || true)

  if (( ${#r_num[@]} == 0 )); then
    info "No managed accounts in the switch sequence."
    return 0
  fi

  # ---- Header ----
  local header="Token refresh — last switch"
  if [[ "$last_switch" =~ ^[0-9]+$ ]]; then
    header="$header $(epoch_to_hms "$last_switch") ($(human_duration $(( now - last_switch ))))"
  fi
  echo ""
  title "  $header"
  echo ""

  # ---- Table ----
  # Cell text is kept ASCII-only: widths are measured with ${#...}, which
  # counts bytes in a C locale, so a multibyte glyph inside a padded cell
  # would skew the columns. Box-drawing glyphs sit outside the cells.
  local col_mode=4 col_when=8
  local bar="${DIM}│${RESET}"
  local sep_top sep_mid sep_bot
  sep_top="$(_table_rule "┌" "┬" "┐" "$col_num" "$col_acct" "$col_mode" "$col_status" "$col_when" "$col_note")"
  sep_mid="$(_table_rule "├" "┼" "┤" "$col_num" "$col_acct" "$col_mode" "$col_status" "$col_when" "$col_note")"
  sep_bot="$(_table_rule "└" "┴" "┘" "$col_num" "$col_acct" "$col_mode" "$col_status" "$col_when" "$col_note")"

  printf '%s\n' "$sep_top"
  _print_row \
    "$(_cell '#'       $col_num    "$BOLD")" \
    "$(_cell 'Account' $col_acct   "$BOLD")" \
    "$(_cell 'Mode'    $col_mode   "$BOLD")" \
    "$(_cell 'Status'  $col_status "$BOLD")" \
    "$(_cell 'When'    $col_when   "$BOLD")" \
    "$(_cell 'Detail'  $col_note   "$BOLD")"
  printf '%s\n' "$sep_mid"

  local i=0 mode_color
  while (( i < ${#r_num[@]} )); do
    mode_color="$DIM"
    [[ "${r_mode[$i]}" == "fg" ]] && mode_color="$MAGENTA"
    _print_row \
      "$(_cell "${r_num[$i]}"   $col_num    "$BOLD")" \
      "$(_cell "${r_email[$i]}" $col_acct   "")" \
      "$(_cell "${r_mode[$i]}"  $col_mode   "$mode_color")" \
      "$(_cell "${r_word[$i]}"  $col_status "${r_color[$i]}")" \
      "$(_cell "${r_when[$i]}"  $col_when   "$DIM")" \
      "$(_cell "${r_note[$i]}"  $col_note   "$DIM")"
    i=$(( i + 1 ))
  done
  printf '%s\n' "$sep_bot"
  echo ""

  # ---- Schedule summary ----
  if (( queued_total == 0 && running_total > 0 )); then
    printf '  %sRefreshing now%s %s— last account in flight%s\n' "$CYAN" "$RESET" "$DIM" "$RESET"
  elif (( queued_total > 0 )) && (( worker_alive )); then
    if [[ -n "$next_run" ]]; then
      local nxt=$next_run
      (( nxt < now )) && nxt=$now
      local done_at=$(( nxt + (queued_total - 1) * BG_GAP_SECONDS ))
      printf '  %sNext refresh%s   %s  %s(%s)%s\n' \
        "$BOLD" "$RESET" "$(epoch_to_hms "$nxt")" "$DIM" "$(human_until $(( nxt - now )))" "$RESET"
      printf '  %sAll done by%s    %s  %s(%s left, %ss apart)%s\n' \
        "$BOLD" "$RESET" "$(epoch_to_hms "$done_at")" "$DIM" "$queued_total" "$BG_GAP_SECONDS" "$RESET"
    else
      printf '  %sNext refresh%s   starting up\n' "$BOLD" "$RESET"
    fi
  elif (( queued_total > 0 )); then
    printf '  %s%s account(s) still queued but the worker is gone%s — run: %scsw switch%s\n' \
      "$RED" "$queued_total" "$RESET" "$BOLD" "$RESET"
  else
    printf '  %sAll accounts settled%s %s— nothing queued%s\n' "$GREEN" "$RESET" "$DIM" "$RESET"
  fi

  if (( show_raw )); then
    echo ""
    title "  Log entries"
    echo ""
    while IFS= read -r line; do dimln "  $line"; done < "$LOG_FILE"
  elif (( have_log )); then
    echo ""
    dimln "  Full log: csw log -v"
  fi
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
  dimln "  --log                            Show token refresh status/logs from last switch"
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
  --log|log) shift; cmd_log "$@" ;;
  # Internal: entry point for the detached background refresh worker.
  # Not listed in --help; invoked only by bg_start_refresh.
  --bg-refresh) shift; bg_worker_main "$@" ;;
  --help|help|-h|"") show_usage ;;
  *) error "Unknown command '$1'"; show_usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
