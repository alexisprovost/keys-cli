#!/bin/bash
# ════════════════════════════════════════════════════════════════════════
#  ⌨  keys — Paste text with a keyboard shortcut
# ════════════════════════════════════════════════════════════════════════
#  A lightweight macOS snippet manager. Assign global hotkeys that
#  paste text (Zoom links, emails, canned responses, etc.) anywhere.
#
#  Uses a tiny Swift daemon that registers Carbon global hotkeys and
#  pastes via the clipboard. Starts automatically on login.
#
#  Install: cp keys.sh /usr/local/bin/keys && chmod +x /usr/local/bin/keys
# ════════════════════════════════════════════════════════════════════════

set -euo pipefail

VERSION="3.0.0"
SNIPPET_CONFIG_DIR="$HOME/.config/keys"
SNIPPET_CONFIG="$SNIPPET_CONFIG_DIR/snippets.json"
DAEMON_SRC_URL="https://raw.githubusercontent.com/alexisprovost/keys-cli/main/keys-daemon.swift"
DAEMON_APP="$SNIPPET_CONFIG_DIR/KeysDaemon.app"
DAEMON_BIN="$DAEMON_APP/Contents/MacOS/keys-daemon"
DAEMON_LABEL="com.keys-cli.daemon"
DAEMON_PLIST="$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist"
DAEMON_LOG="$SNIPPET_CONFIG_DIR/daemon.log"

# ── TUI Colors & Glyphs ────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RST='\033[0m'    BLD='\033[1m'    DIM='\033[2m'
    RED='\033[91m'   GRN='\033[92m'   YEL='\033[93m'  BLU='\033[94m'
    MAG='\033[95m'   CYN='\033[96m'   WHT='\033[97m'  GRY='\033[90m'
    OK="✔" WARN="⚠" FAIL="✘" DOT="›" ARROW="→" KEY="⌨"
else
    RST="" BLD="" DIM="" RED="" GRN="" YEL="" BLU=""
    MAG="" CYN="" WHT="" GRY=""
    OK="OK" WARN="!!" FAIL="XX" DOT=">" ARROW="->" KEY="KB"
fi

# ── Shortcut Format Conversion ────────────────────────────────────────
# macOS plist format: @ = ⌘  ~ = ⌥  ^ = ⌃  $ = ⇧
# We accept human-readable input and convert both ways.

human_to_plist() {
    local input="$1"
    local mods="" key=""

    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]//g')

    # Handle symbolic input (⌘⇧⌥⌃)
    if echo "$input" | grep -q '[⌘⌥⌃⇧]'; then
        local plist_str=""
        while IFS= read -r -n1 char; do
            case "$char" in
                ⌘) plist_str+="@" ;;
                ⌥) plist_str+="~" ;;
                ⌃) plist_str+="^" ;;
                ⇧) plist_str+="\$" ;;
                *)
                    if [[ -n "$char" && "$char" != "+" ]]; then
                        key+="$char"
                    fi
                    ;;
            esac
        done <<< "$input"
        key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        echo "${plist_str}${key}"
        return
    fi

    # Parse modifier+modifier+key format
    IFS='+' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        case "$part" in
            cmd|command|⌘)   mods+="@" ;;
            opt|option|alt|⌥) mods+="~" ;;
            ctrl|control|⌃)  mods+="^" ;;
            shift|⇧)         mods+="\$" ;;
            fn)              ;;
            *)               key="$part" ;;
        esac
    done

    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')

    case "$key" in
        TAB)              key=$'\xe2\x87\xa5' ;;
        RETURN|ENTER)     key=$'\xe2\x86\xa9' ;;
        DELETE|BACKSPACE) key=$'\xe2\x8c\xab' ;;
        ESCAPE|ESC)       key=$'\xe2\x8e\x8b' ;;
        UP)               key=$'\xe2\x86\x91' ;;
        DOWN)             key=$'\xe2\x86\x93' ;;
        LEFT)             key=$'\xe2\x86\x90' ;;
        RIGHT)            key=$'\xe2\x86\x92' ;;
        SPACE)            key=" " ;;
        F[0-9]|F1[0-9])  ;;
    esac

    echo "${mods}${key}"
}

plist_to_human() {
    local input="$1"
    local result=""

    while IFS= read -r -n1 char; do
        case "$char" in
            @)   result+="⌘" ;;
            '~') result+="⌥" ;;
            '^') result+="⌃" ;;
            '$') result+="⇧" ;;
            *)   result+="$char" ;;
        esac
    done <<< "$input"
    echo "$result"
}

# ── Daemon Helpers ────────────────────────────────────────────────────

ensure_daemon() {
    if [[ -f "$DAEMON_BIN" ]]; then
        return 0
    fi

    echo -e "  ${DIM}Compiling snippet daemon (first time only)...${RST}"
    mkdir -p "$SNIPPET_CONFIG_DIR"

    local src=""
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$script_dir/keys-daemon.swift" ]]; then
        src="$script_dir/keys-daemon.swift"
    else
        src="/tmp/keys-daemon-$$.swift"
        if ! curl -fsSL "$DAEMON_SRC_URL" -o "$src" 2>/dev/null; then
            echo -e "  ${RED}${FAIL} Failed to download daemon source.${RST}"
            return 1
        fi
    fi

    local app_contents="$DAEMON_APP/Contents"
    local app_macos="$app_contents/MacOS"
    mkdir -p "$app_macos"

    if ! swiftc -o "$DAEMON_BIN" "$src" -framework AppKit -framework Carbon 2>&1; then
        echo -e "  ${RED}${FAIL} Failed to compile. Install Xcode Command Line Tools: xcode-select --install${RST}"
        [[ "$src" == /tmp/* ]] && rm -f "$src"
        return 1
    fi

    cat > "$app_contents/Info.plist" << 'APPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.keys-cli.daemon</string>
    <key>CFBundleName</key>
    <string>Keys Daemon</string>
    <key>CFBundleExecutable</key>
    <string>keys-daemon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
APPEOF

    [[ "$src" == /tmp/* ]] && rm -f "$src"
    [[ -f "$SNIPPET_CONFIG_DIR/keys-daemon" && ! -d "$DAEMON_APP" ]] && rm -f "$SNIPPET_CONFIG_DIR/keys-daemon"

    echo -e "  ${GRN}${OK} Daemon compiled.${RST}"
}

create_daemon_plist() {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$DAEMON_PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DAEMON_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${DAEMON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${DAEMON_LOG}</string>
</dict>
</plist>
PLISTEOF
}

restart_daemon() {
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    create_daemon_plist
    launchctl load "$DAEMON_PLIST"
}

stop_daemon() {
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    rm -f "$DAEMON_PLIST"
}

daemon_status() {
    if pgrep -f "keys-daemon" >/dev/null 2>&1; then
        echo "running"
    else
        echo "stopped"
    fi
}

# ════════════════════════════════════════════════════════════════════════
#  COMMANDS
# ════════════════════════════════════════════════════════════════════════

cmd_add() {
    echo -e "\n  ${GRN}${BLD}${KEY} Add Snippet${RST}\n"

    # ── Name
    local name
    if [[ -n "${1:-}" ]]; then
        name="$1"; shift
    else
        echo -e "  ${DIM}A short name for this snippet (e.g. \"Zoom\", \"Email\")${RST}"
        read -rp "  Name: " name
    fi
    [[ -z "$name" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }

    # ── Shortcut
    local shortcut_input plist_key
    if [[ -n "${1:-}" ]]; then
        shortcut_input="$1"; shift
    else
        echo -e "\n  ${DIM}e.g. cmd+shift+z, or ⌘⇧Z${RST}"
        read -rp "  Shortcut: " shortcut_input
    fi
    [[ -z "$shortcut_input" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }
    plist_key=$(human_to_plist "$shortcut_input")
    local human_key
    human_key=$(plist_to_human "$plist_key")

    # ── Text
    local text
    if [[ -n "${1:-}" ]]; then
        text="$1"; shift
    else
        echo -e "\n  ${DIM}The text to paste (e.g. your Zoom link)${RST}"
        read -rp "  Text: " text
    fi
    [[ -z "$text" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }

    # ── Save to snippets.json
    mkdir -p "$SNIPPET_CONFIG_DIR"
    python3 -c "
import json, os

config_path = '$SNIPPET_CONFIG'
snippets = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        snippets = json.load(f)
snippets['''$name'''] = {
    'text': '''$text''',
    'shortcut': '$plist_key',
}
with open(config_path, 'w') as f:
    json.dump(snippets, f, indent=2)
print('OK')
" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        echo -e "  ${RED}${FAIL} Failed to save snippet.${RST}\n"
        return 1
    fi

    # ── Compile daemon if needed
    if ! ensure_daemon; then
        return 1
    fi

    # ── Start/restart daemon
    echo -e "  ${DIM}Starting snippet daemon...${RST}"
    restart_daemon
    sleep 1

    local preview="$text"
    (( ${#preview} > 50 )) && preview="${preview:0:50}..."

    echo -e "\n  ${GRN}${BLD}${OK} Snippet created:${RST}"
    echo -e "    ${WHT}${human_key}${RST} ${ARROW} pastes \"${CYN}${preview}${RST}\""

    if [[ "$(daemon_status)" == "running" ]]; then
        echo -e "\n  ${GRN}${OK} Daemon is running. Shortcut is active now.${RST}"
    else
        echo -e "\n  ${YEL}${WARN} Daemon may need Accessibility permission.${RST}"
        echo -e "  ${DIM}Grant it in: System Settings → Privacy & Security → Accessibility${RST}"
        echo -e "  ${DIM}Then run: keys restart${RST}"
    fi
    echo ""
}

cmd_list() {
    echo -e "\n  ${CYN}${BLD}${KEY} Snippets${RST}"
    echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    if [[ ! -f "$SNIPPET_CONFIG" ]]; then
        echo -e "  ${DIM}No snippets yet. Create one with: keys add${RST}\n"
        return
    fi

    local count=0
    python3 -c "
import json, sys
with open('$SNIPPET_CONFIG') as f:
    snippets = json.load(f)
if not snippets:
    sys.exit(1)
for name, info in snippets.items():
    text = info['text']
    if len(text) > 60:
        text = text[:60] + '...'
    print(f'{name}\t{info[\"shortcut\"]}\t{text}')
" 2>/dev/null | while IFS=$'\t' read -r sname skey stext; do
        local human
        human=$(plist_to_human "$skey")
        printf "  ${WHT}%-14s${RST}  ${ARROW}  %-16s  ${CYN}%s${RST}\n" "$human" "$sname" "$stext"
        ((count++)) || true
    done

    echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    local status
    status=$(daemon_status)
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GRN}${OK} Daemon: running${RST}\n"
    else
        echo -e "  ${YEL}${WARN} Daemon: stopped${RST} — run ${WHT}keys restart${RST}\n"
    fi
}

cmd_delete() {
    echo -e "\n  ${RED}${BLD}${KEY} Delete Snippet${RST}\n"

    local name
    if [[ -n "${1:-}" ]]; then
        name="$1"; shift
    else
        if [[ -f "$SNIPPET_CONFIG" ]]; then
            python3 -c "
import json
with open('$SNIPPET_CONFIG') as f:
    snippets = json.load(f)
for i, name in enumerate(snippets, 1):
    print(f'  {i})  {name}')
" 2>/dev/null
        fi
        echo ""
        read -rp "  Snippet name to delete: " name
    fi
    [[ -z "$name" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }

    local exists
    exists=$(python3 -c "
import json, os
config_path = '$SNIPPET_CONFIG'
if not os.path.exists(config_path):
    print('no')
else:
    with open(config_path) as f:
        snippets = json.load(f)
    print('yes' if '''$name''' in snippets else 'no')
" 2>/dev/null)

    if [[ "$exists" != "yes" ]]; then
        echo -e "  ${RED}${FAIL} Snippet \"${name}\" not found.${RST}\n"
        return 1
    fi

    read -rp "  Delete snippet \"${name}\"? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo -e "  ${YEL}Cancelled.${RST}"; return 0; }

    python3 -c "
import json, os
config_path = '$SNIPPET_CONFIG'
if os.path.exists(config_path):
    with open(config_path) as f:
        snippets = json.load(f)
    snippets.pop('''$name''', None)
    with open(config_path, 'w') as f:
        json.dump(snippets, f, indent=2)
" 2>/dev/null

    local remaining
    remaining=$(python3 -c "import json; print(len(json.load(open('$SNIPPET_CONFIG'))))" 2>/dev/null || echo "0")

    if [[ "$remaining" == "0" ]]; then
        stop_daemon
        echo -e "  ${GRN}${OK} Deleted snippet \"${name}\". No snippets left — daemon stopped.${RST}\n"
    else
        restart_daemon
        echo -e "  ${GRN}${OK} Deleted snippet \"${name}\". Daemon restarted with ${remaining} snippet(s).${RST}\n"
    fi
}

cmd_status() {
    local status
    status=$(daemon_status)
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GRN}${OK} Snippet daemon is running.${RST}"
    else
        echo -e "  ${YEL}${WARN} Snippet daemon is not running.${RST}"
    fi

    if [[ -f "$SNIPPET_CONFIG" ]]; then
        local count
        count=$(python3 -c "import json; print(len(json.load(open('$SNIPPET_CONFIG'))))" 2>/dev/null || echo "0")
        echo -e "  ${DIM}${count} snippet(s) configured.${RST}"
    else
        echo -e "  ${DIM}No snippets configured.${RST}"
    fi
}

# ── Interactive Mode ───────────────────────────────────────────────────

cmd_interactive() {
    while true; do
        echo -e "\n${BLU}${BLD}  ⌨  keys${RST} ${GRY}v${VERSION}${RST} — ${DIM}Paste text with a keyboard shortcut${RST}"
        echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "   ${GRN}a${RST}dd       Add a new snippet"
        echo -e "   ${CYN}l${RST}ist      List all snippets"
        echo -e "   ${RED}d${RST}elete    Delete a snippet"
        echo -e "   ${BLU}s${RST}tatus    Show daemon status"
        echo -e "   ${MAG}r${RST}estart   Restart the daemon"
        echo -e "   ${BLU}u${RST}pdate    Update keys to latest version"
        echo -e "   ${GRY}q${RST}uit"
        echo ""
        read -rp "  ${DOT} " choice

        case "$choice" in
            a|add)       cmd_add ;;
            l|list|ls)   cmd_list ;;
            d|delete|rm) cmd_delete ;;
            s|status)    cmd_status ;;
            r|restart)   restart_daemon; echo -e "  ${GRN}${OK} Daemon restarted.${RST}" ;;
            u|update)    cmd_update ;;
            q|quit|exit) echo -e "  ${DIM}Bye.${RST}"; exit 0 ;;
            *)           echo -e "  ${RED}?${RST} Unknown: ${choice}" ;;
        esac
    done
}

# ── Usage ──────────────────────────────────────────────────────────────

usage() {
    echo -e "
${BLU}${BLD}  ⌨  keys${RST} ${GRY}v${VERSION}${RST} — Paste text with a keyboard shortcut

  ${BLD}USAGE${RST}
    keys <command> [options]

  ${BLD}COMMANDS${RST}
    ${GRN}add${RST} [name] [shortcut] [text]   Add a new snippet
    ${CYN}list${RST}                            List all snippets
    ${RED}delete${RST} [name]                   Delete a snippet
    ${BLU}status${RST}                          Show daemon status
    ${MAG}restart${RST}                         Restart the snippet daemon
    ${MAG}stop${RST}                            Stop the snippet daemon
    ${BLU}update${RST}                          Update keys to the latest version

  ${BLD}SHORTCUT FORMAT${RST}
    Human-readable: ${WHT}cmd+shift+z${RST}  ${WHT}ctrl+alt+k${RST}
    Symbol style:   ${WHT}⌘⇧Z${RST}          ${WHT}⌃⌥K${RST}

  ${BLD}EXAMPLES${RST}
    ${GRY}\$${RST} keys add \"Zoom\" cmd+shift+z \"https://zoom.us/j/123456\"
    ${GRY}\$${RST} keys add \"Email\" cmd+shift+e \"me@example.com\"
    ${GRY}\$${RST} keys list
    ${GRY}\$${RST} keys delete \"Zoom\"

  ${BLD}HOW IT WORKS${RST}
    A lightweight background daemon listens for global hotkeys and pastes
    your text via the clipboard. Starts automatically on login.
    Requires Accessibility permission (you'll be prompted on first use).
"
}

# ── Update ─────────────────────────────────────────────────────────────

REPO_URL="https://raw.githubusercontent.com/alexisprovost/keys-cli/main/keys.sh"

cmd_update() {
    echo -e "\n  ${BLU}${BLD}${KEY} Update${RST}\n"
    echo -e "  ${DIM}Checking for updates...${RST}"

    local tmp="/tmp/keys-update-$$"
    if ! curl -fsSL "$REPO_URL" -o "$tmp" 2>/dev/null; then
        echo -e "  ${RED}${FAIL} Failed to fetch latest version.${RST}\n"
        rm -f "$tmp"
        return 1
    fi

    local remote_version
    remote_version=$(grep '^VERSION=' "$tmp" | head -1 | sed 's/VERSION="//;s/"//')

    if [[ "$remote_version" == "$VERSION" ]]; then
        local self
        self=$(which keys 2>/dev/null || echo "$0")
        if diff -q "$self" "$tmp" >/dev/null 2>&1; then
            echo -e "  ${GRN}${OK} Already up to date (v${VERSION}).${RST}\n"
            rm -f "$tmp"
            return 0
        fi
        echo -e "  ${YEL}${WARN} Same version (v${VERSION}) but files differ. Updating...${RST}"
    else
        echo -e "  ${GRN}${OK} New version available: v${VERSION} → v${remote_version}${RST}"
    fi

    local install_path
    install_path=$(which keys 2>/dev/null || echo "/usr/local/bin/keys")

    if [[ -w "$install_path" ]]; then
        mv "$tmp" "$install_path"
        chmod +x "$install_path"
    else
        sudo mv "$tmp" "$install_path"
        sudo chmod +x "$install_path"
    fi

    echo -e "  ${GRN}${BLD}${OK} Updated to v${remote_version}.${RST}\n"
}

# ════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    add)            shift; cmd_add "$@" ;;
    list|ls)        cmd_list ;;
    delete|rm|del)  shift; cmd_delete "$@" ;;
    status)         cmd_status ;;
    restart)        restart_daemon; echo -e "  ${GRN}${OK} Daemon restarted.${RST}" ;;
    stop)           stop_daemon; echo -e "  ${GRN}${OK} Daemon stopped.${RST}" ;;
    update|upgrade) cmd_update ;;
    help|-h|--help) usage ;;
    version|-v|--version) echo "keys v${VERSION}" ;;
    "")             cmd_interactive ;;
    *)              echo -e "${RED}Unknown command: $1${RST}"; usage; exit 1 ;;
esac
