<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-white.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png">
  <img alt="Siam Ahnaf" src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/logo/logo-black.png" height="auto" width="240">
</picture>

# Multi-Account Switcher for Claude Code

`csw` is a lightweight CLI to **manage and switch between multiple Claude Code accounts** on **macOS, Linux, and WSL**.

It only switches **authentication** — your **themes, settings, preferences, and chat history** remain unchanged.

---

## Features

- **Multi-account management**: add, remove, list accounts
- **Fast switching**: rotate to the next account or switch to a specific one
- **Cross-platform**: macOS, Linux, WSL
- **Secure storage**
  - **macOS**: credentials stored in **Keychain**
  - **Linux/WSL**: credentials stored in local files with **restricted permissions**
- **Non-destructive**: does not modify your Claude Code UI settings

---

## Installation

### Install with one command

```bash
curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/install.sh | bash
````

### Ensure `csw` is on your PATH

If `csw` is not found after install, add `~/.local/bin` to your shell PATH:

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
3. **Log out**, then log in with your second account
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

## Requirements

* **Bash 3.2+** (works with the default macOS Bash)
* **jq** (JSON processor)


## Connect with me
<div style="display: flex; align-items: center; gap: 3px;">
<a href="https://wa.me/8801611994403"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/whatsapp.png" width="40" height="40"></a>
<a href="https://siamahnaf.com/" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/web.png" width="40" height="40"></a>
<a href="https://www.linkedin.com/in/siamahnaf/" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/linkedin.png" width="40" height="40"></a>
<a href="https://x.com/siamahnaf198" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/x.png" width="40" height="40"></a>
<a href="https://www.facebook.com/siamahnaf198/" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/facebook.png" width="40" height="40"></a>
<a href="https://t.me/siamahnaf198" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/telegram.png" width="40" height="40"></a>
<a href="https://www.npmjs.com/~siamahnaf" style="margin-right: 8px"><img src="https://raw.githubusercontent.com/siamahnaf/assets-kit/main/icons/npm.png" width="40" height="40"></a>
</div>