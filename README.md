<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-white.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png">
  <img alt="Siam Ahnaf" src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png" height="auto" width="240">
</picture>

# Multi-Account Switcher for Claude Code

`csw` is a lightweight CLI to **manage and switch between multiple Claude Code accounts** on **macOS, Linux, WSL, and Windows**.

It only switches **authentication** — your **themes, settings, preferences, and chat history** remain unchanged.

---

## Features

- **Multi-account management**: add, remove, list accounts
- **Fast switching**: rotate to the next account or switch to a specific one
- **Automatic token refresh**: OAuth tokens are refreshed on every switch
  - **Foreground**: the account you switch to is refreshed before activation —
    refreshed, saved, and applied in sync
  - **Background**: every other account is refreshed by a detached worker, one
    at a time with a 1-minute gap, so requests are never bursted
  - **Already refreshed**: an account csw refreshed within the last 6 hours is
    left alone instead of being queued again
  - Starting a new switch cancels any refreshes still pending from the previous
    one and queues a fresh run
- **Live status table**: `csw log` shows one row per account — mode (`fg`/`bg`),
  status (`Success`, `Pending`, `Refreshing`, `Fresh`, `Skipped`, `Failed`),
  when it happened, and — for queued accounts — the projected refresh time plus
  when the whole queue finishes. `csw log -v` appends the raw log lines.
- **Cross-platform**: macOS, Linux, WSL, Windows
- **Secure storage**
  - **macOS**: credentials stored in **Keychain**
  - **Linux/WSL**: credentials stored in local files with **restricted permissions**
  - **Windows**: credentials encrypted with **DPAPI** (current-user scope)
- **Non-destructive**: does not modify your Claude Code UI settings

---

## Installation

### Install with one command

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/install.sh | bash
```

**Windows (PowerShell — run as your normal user, no admin required):**

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/siamahnaf/csw/main/install-windows.ps1" -OutFile "$env:TEMP\install-windows.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-windows.ps1"
```

### Ensure `csw` is on your PATH

**Windows:** The installer adds `%LOCALAPPDATA%\csw` to your user PATH automatically. Restart your terminal after install.

**macOS / Linux / WSL:** If `csw` is not found after install, add `~/.local/bin` to your shell PATH:

**zsh (default on macOS):**

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
hash -r
```

**bash:**

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
hash -r
```

---

## Usage

### Basic commands

```bash
# Add the currently logged-in Claude Code account to managed accounts
csw add-account

# List all managed accounts
csw list

# Switch to the next account in your rotation
csw switch

# Switch to a specific account by number or email
csw switch-to 2
csw switch-to user2@example.com

# Remove an account (by number or email)
csw remove-account 2
csw remove-account user2@example.com

# Status table for the last switch: per-account state, next refresh time, ETA
# (re-run while a background refresh is in flight to watch Pending -> Success)
csw log

# Same table plus the raw log lines
csw log -v

# Help
csw -help

# Updater
csw -v
csw -check-update
```

---

## First-time setup workflow

1. **Log in to Claude Code** with your first account
2. Run:

   ```bash
   csw add-account
   ```
3. **Switch your Claude login to your second account** — run `claude login`
   (or `/login` inside Claude Code) and sign in with the second account.

   > ⚠️ **Do NOT run `claude logout`.** Logging out revokes that account's
   > refresh token on Anthropic's servers, which makes `csw switch` fail later
   > with `HTTP 400 invalid_grant — "Refresh token not found or invalid"`.
   > Always move between accounts with `claude login` / `/login` / `csw switch`,
   > never `claude logout`.
4. Run again:

   ```bash
   csw add-account
   ```
5. Switch accounts anytime:

   ```bash
   csw switch
   ```

After switching, **restart Claude Code** to apply the new authentication.

> **What gets switched:** only authentication credentials and OAuth account info.
> **What stays the same:** themes, settings, preferences, and chat history.

---

## Troubleshooting

### `HTTP 400 invalid_grant — "Refresh token not found or invalid"` when switching

This means the stored refresh token for that account has been **revoked on
Anthropic's servers** — almost always because `claude logout` was run for that
account. Logging out revokes the refresh token, so the credentials `csw` saved
can no longer be refreshed.

**Golden rule:** move between accounts only with `claude login` / `/login` /
`csw switch`. **Never run `claude logout`** — re-logging in replaces local
credentials without revoking the previous account's token, but logging out
kills it permanently.

**To recover a broken account** (example for Account-1, while Account-2 stays
active and healthy):

```bash
csw remove-account 1      # drop the stale/dead entry
claude login              # sign in as that account (mints a FRESH token) — do NOT 'claude logout' first
csw add-account           # re-capture the fresh credentials
claude login              # sign back in as your other account (re-login, no logout)
csw switch                # both accounts now refresh cleanly
```

> Anthropic uses **rotating refresh tokens with reuse detection**. Each refresh
> invalidates the previous token, and presenting an already-used token revokes
> the whole token family.
>
> Background refresh is built around that constraint. An account is refreshed by
> at most one process at a time (per-account lock files), a superseded worker
> retires itself at a safe checkpoint rather than being killed mid-refresh, and
> accounts refreshed in the last 6 hours are skipped entirely. If you see
> `Failed — Refreshed but could not save` in `csw log`, that account's stored
> token is the invalidated one and it needs `claude login`.

### Background refreshes are stuck

`csw log` shows `Stalled` (instead of `Pending`) when accounts are still queued
but the worker process is gone — a reboot, or a killed terminal. Run
`csw switch` again to queue a fresh run.

---

## Uninstall

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/uninstall.sh | bash
```

This does NOT remove backups:

```bash
rm -rf ~/.claude-switch-backup
```

**Windows:**

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/siamahnaf/csw/main/uninstall-windows.ps1" -OutFile "$env:TEMP\uninstall-windows.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\uninstall-windows.ps1"
```

This does NOT remove backups:

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-switch-backup" -ErrorAction SilentlyContinue
```

---

## Disclaimer

`csw` is an unofficial utility and is not affiliated with Anthropic.

Use responsibly and keep exported backups secure.

---

## Connect with Me

<div style="display: flex; align-items: center; gap: 3px;">
<a href="https://wa.me/8801611994403"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/whatsapp.png" width="40" height="40"></a>
<a href="https://siamahnaf.com/"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/web.png" width="40" height="40"></a>
<a href="https://www.linkedin.com/in/siamahnaf/"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/linkedin.png" width="40" height="40"></a>
<a href="https://x.com/siamahnaf198"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/x.png" width="40" height="40"></a>
<a href="https://www.facebook.com/siamahnaf198/"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/facebook.png" width="40" height="40"></a>
<a href="https://t.me/siamahnaf198"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/telegram.png" width="40" height="40"></a>
<a href="https://www.npmjs.com/~siamahnaf"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/npm.png" width="40" height="40"></a>
</div>
