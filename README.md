# keys

Paste text with a keyboard shortcut. Assign global hotkeys that instantly paste Zoom links, email addresses, canned responses — anything.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexisprovost/keys-cli/main/install.sh | bash
```

Or manually:

```bash
curl -fsSL https://raw.githubusercontent.com/alexisprovost/keys-cli/main/keys.sh -o /usr/local/bin/keys
chmod +x /usr/local/bin/keys
```

## Usage

```bash
keys                                          # Interactive mode
keys add "Zoom" cmd+shift+z "https://zoom.us/j/123456"
keys add "Email" cmd+shift+e "me@example.com"
keys add "Sig" cmd+shift+s "Thanks,\nAlex"
keys list                                     # List all snippets
keys delete "Zoom"                            # Remove a snippet
keys status                                   # Check if daemon is running
keys restart                                  # Restart the daemon
keys update                                   # Update to latest version
```

## Shortcut Format

Two input formats are accepted:

| Format | Example |
|---|---|
| Human-readable | `cmd+shift+z` (also accepts `command`, `option`, `alt`, `control`) |
| Symbol | `⌘⇧Z` |

## How It Works

A lightweight Swift daemon runs in the background and listens for your hotkeys via macOS Carbon global hotkey API. When triggered, it copies your text to the clipboard and simulates `Cmd+V` to paste it.

- Daemon compiles automatically on first use (requires Xcode Command Line Tools)
- Starts on login via LaunchAgent
- Snippets stored in `~/.config/keys/snippets.json`
- Requires Accessibility permission (you'll be prompted on first run)

## Commands

| Command | Description |
|---|---|
| `add [name] [shortcut] [text]` | Add a new snippet |
| `list` | List all snippets |
| `delete [name]` | Delete a snippet |
| `status` | Show daemon status |
| `restart` | Restart the snippet daemon |
| `stop` | Stop the snippet daemon |
| `update` | Update keys to the latest version |

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 (ships with macOS)

## License

MIT
