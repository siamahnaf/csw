# csw — Multi-Account Switcher for Claude Code

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
csw --add-account

# List all managed accounts
csw --list

# Switch to the next account in your rotation
csw --switch

# Switch to a specific account by number or email
csw --switch-to 2
csw --switch-to user2@example.com

# Remove an account (by number or email)
csw --remove-account 2
csw --remove-account user2@example.com

# Help
csw --help
```

---

## First-time setup workflow

1. **Log in to Claude Code** with your first account
2. Run:

   ```bash
   csw --add-account
   ```
3. **Log out**, then log in with your second account
4. Run again:

   ```bash
   csw --add-account
   ```
5. Switch accounts anytime:

   ```bash
   csw --switch
   ```

After switching, **restart Claude Code** to apply the new authentication.

> **What gets switched:** only authentication credentials and OAuth account info.
> **What stays the same:** themes, settings, preferences, and chat history.

---

## Requirements

* **Bash 3.2+** (works with the default macOS Bash)
* **jq** (JSON processor)

### Check requirements

```bash
bash --version
jq --version
```

### Install `jq`

**macOS (Homebrew):**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt-get update && sudo apt-get install -y jq
```

**Arch:**

```bash
sudo pacman -Sy jq
```

---

## How it works

`csw` stores per-account authentication data under:

* `~/.claude-switch-backup/`

Storage details:

* **macOS**

  * credentials: **Keychain**
  * config backups: `~/.claude-switch-backup/`
* **Linux/WSL**

  * credentials + config backups: `~/.claude-switch-backup/` (permissions restricted)

When you switch accounts, it:

1. Backs up the current account’s auth data
2. Restores the target account’s auth data
3. Updates Claude Code authentication files locally

---

## Troubleshooting

### `csw: command not found`

Make sure `~/.local/bin` is in PATH (see Installation section), then restart your terminal or run:

```bash
hash -r
```

### Can’t add an account

* Make sure you are **logged in** to Claude Code first
* Verify `jq` exists:

  ```bash
  jq --version
  ```
* Ensure the Claude config exists:

  ```bash
  ls -la ~/.claude.json ~/.claude/.claude.json 2>/dev/null
  ```

### Claude Code doesn’t reflect the switched account

* **Restart Claude Code** after switching
* Confirm active account:

  ```bash
  csw --list
  ```

---

## Uninstall / cleanup

### Remove the CLI

If you used the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/siamahnaf/csw/main/uninstall.sh | bash
```

### Remove all saved account backups

```bash
rm -rf ~/.claude-switch-backup
```

Your current Claude Code login remains active.

---

## Security notes

* Credentials are stored locally:

  * macOS: Keychain
  * Linux/WSL: files with restrictive permissions
* `csw` does not send data to any remote server
* For safest switching, close Claude Code during account switches

---

## License

MIT License — see `LICENSE`.