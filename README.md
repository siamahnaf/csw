<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-white.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png">
  <img alt="Siam Ahnaf" src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png" height="auto" width="240">
</picture>

# Multi-Account Switcher for Claude Code (csw)

`csw` is a powerful yet lightweight CLI tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

It swaps authentication only — your themes, preferences, chat history, and UI settings remain unchanged.

---

## What's New (v2.1)

### Interactive Mode
Menu-driven interface for easier account management:

    csw interactive

### Color-Coded Output
Beautiful, readable terminal output with structured formatting.

Disable colors if needed:

    csw --no-color

### Progress Indicators
Real-time spinner feedback during:
- Switching accounts
- Installing / Updating
- Export / Import
- Backup operations

---

## Secure & Smart Authentication Handling

Claude Code does not officially support account switching.

`csw` works by safely:
1. Backing up authentication credentials
2. Swapping OAuth credentials when switching accounts
3. Updating Claude config automatically

### macOS Special Fix

Claude Code sometimes stores credentials under different Keychain service names:

- Claude Code
- Claude Code-credentials

`csw` automatically:
- Detects which one contains valid OAuth tokens
- Writes to both services to prevent 401 authentication errors

This prevents the common:

    Failed to authenticate. API Error: 401 OAuth token has expired

---

## Features

- Multi-account management
- Fast account rotation
- Switch by number, email, or alias
- Alias support
- Backup verification
- Export / Import accounts
- Undo last switch
- Switch history tracking
- Interactive UI
- Cross-platform (macOS, Linux, WSL)
- Secure storage:
  - macOS → Keychain
  - Linux/WSL → restricted permission files

---

## Installation

### One-line install

    curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/install.sh | bash

---

### Add to PATH (if needed)

zsh (macOS default):

    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    source ~/.zshrc
    hash -r

bash:

    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    source ~/.bashrc
    hash -r

---

## Usage

Basic:

    csw add-account
    csw list
    csw switch
    csw switch-to 2
    csw switch-to user@example.com
    csw remove-account 2
    csw status
    csw verify

Alias Support:

    csw set-alias 1 work
    csw switch-to work

Sync Current Account (after re-login):

    csw sync

Undo Last Switch:

    csw undo

Export Accounts:

    csw export backup.tar.gz

Import Accounts:

    csw import backup.tar.gz

---

## First-Time Setup Workflow

1. Log in to Claude Code with Account #1  
2. Run:

       csw add-account

3. Log out → Log in with Account #2  
4. Run:

       csw add-account

5. Switch anytime:

       csw switch

After switching, restart Claude Code.

---

## Verification & Health Check

    csw verify

- Checks if credentials exist
- Warns if refreshToken is missing
- Detects degraded accounts before 401 errors happen

If login expires:
1. Switch to that account
2. Log in normally
3. Run:

       csw sync

---

## Uninstall

    curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/uninstall.sh | bash

This does NOT remove backups:

    rm -rf ~/.claude-switch-backup

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
