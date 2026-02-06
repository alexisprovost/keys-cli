# keys

Native macOS keyboard shortcut manager. Reads and writes directly to macOS `NSUserKeyEquivalents` plists — the same system that **System Settings > Keyboard > Shortcuts > App Shortcuts** uses.

No config files, no databases, no daemons. Just the native macOS preference system.

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
keys add Safari "Show Reader" cmd+shift+r     # Add a shortcut
keys add Finder "Show Package Contents" ⌘⇧O   # Symbol format works too
keys add global "Emoji & Symbols" ctrl+cmd+space
keys list                                     # List all custom shortcuts
keys list safari                              # Filter by app
keys check cmd+shift+k                        # Check for conflicts
keys edit Safari                              # Edit a shortcut interactively
keys delete Finder                            # Delete a shortcut
keys export ~/Desktop/backup.plist            # Backup all shortcuts
keys import ~/Desktop/backup.plist            # Restore from backup
keys nuke                                     # Remove ALL custom shortcuts
```

## Shortcut Format

Three input formats are accepted and automatically converted:

| Format | Example | Notes |
|---|---|---|
| Human-readable | `cmd+shift+o` | Also accepts `command`, `option`, `alt`, `control` |
| Symbol | `⌘⇧O` | macOS-style modifier symbols |
| Plist (internal) | `@$O` | What macOS actually stores (`@`=⌘ `~`=⌥ `^`=⌃ `$`=⇧) |

## How It Works

`keys` uses the `defaults` command to write `NSUserKeyEquivalents` entries into macOS preference plists. This is exactly what System Settings does when you add app shortcuts through the GUI.

**Storage locations:**

| Scope | Plist |
|---|---|
| Global (all apps) | `~/Library/Preferences/.GlobalPreferences.plist` |
| Per-app | `~/Library/Preferences/<bundle-id>.plist` |
| App registry | `~/Library/Preferences/com.apple.universalaccess.plist` |

When you add a shortcut, `keys` also:
- Registers the app with `com.apple.universalaccess` so it appears in System Settings
- Resolves app names to bundle IDs automatically (e.g. `Safari` -> `com.apple.Safari`)
- Runs `activateSettings -u` to apply changes without a logout
- Scans all domains for conflicts before writing

## Commands

| Command | Description |
|---|---|
| `add [app] [menu] [shortcut]` | Add a new shortcut |
| `list [filter]` | List all custom shortcuts, optionally filtered |
| `edit [app]` | Interactively edit an existing shortcut |
| `delete [app]` | Delete a shortcut |
| `check <shortcut>` | Check a shortcut for system-wide conflicts |
| `export [file]` | Export all shortcuts to a plist backup |
| `import <file>` | Import shortcuts from a plist backup |
| `nuke` | Remove all custom shortcuts (requires confirmation) |

## Requirements

- macOS (uses `defaults`, `osascript`, `python3`)
- Bash 4+
- Python 3 (ships with macOS)

## License

MIT
