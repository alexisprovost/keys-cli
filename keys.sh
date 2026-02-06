#!/bin/bash
# ════════════════════════════════════════════════════════════════════════
#  ⌨  keys — Native macOS Keyboard Shortcut Manager
# ════════════════════════════════════════════════════════════════════════
#  Reads & writes directly to macOS NSUserKeyEquivalents plists.
#  This is exactly what System Settings > Keyboard > Shortcuts does.
#
#  Storage locations (native macOS):
#    Global:    ~/Library/Preferences/.GlobalPreferences.plist
#    Per-app:   ~/Library/Preferences/<bundle-id>.plist
#    Registry:  ~/Library/Preferences/com.apple.universalaccess.plist
#    Hotkeys:   ~/Library/Preferences/com.apple.symbolichotkeys.plist
#
#  Install: cp keys.sh /usr/local/bin/keys && chmod +x /usr/local/bin/keys
# ════════════════════════════════════════════════════════════════════════

set -euo pipefail

VERSION="2.0.0"
PREFS_DIR="$HOME/Library/Preferences"
GLOBAL_DOMAIN="-g"  # aka NSGlobalDomain / .GlobalPreferences.plist
UA_PLIST="com.apple.universalaccess"
SERVICES_DIR="$HOME/Library/Services"
SNIPPET_CONFIG_DIR="$HOME/.config/keys"
SNIPPET_CONFIG="$SNIPPET_CONFIG_DIR/snippets.json"
SNIPPET_PREFIX="Keys"
DAEMON_SRC_URL="https://raw.githubusercontent.com/alexisprovost/keys-cli/main/keys-daemon.swift"
DAEMON_APP="$SNIPPET_CONFIG_DIR/KeysDaemon.app"
DAEMON_BIN="$DAEMON_APP/Contents/MacOS/keys-daemon"
DAEMON_LABEL="com.keys-cli.daemon"
DAEMON_PLIST="$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist"
DAEMON_LOG="$SNIPPET_CONFIG_DIR/daemon.log"

# ── TUI Colors & Glyphs ────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RST='\033[0m'    BLD='\033[1m'    DIM='\033[2m'   UND='\033[4m'
    RED='\033[91m'   GRN='\033[92m'   YEL='\033[93m'  BLU='\033[94m'
    MAG='\033[95m'   CYN='\033[96m'   WHT='\033[97m'  GRY='\033[90m'
    BG_R='\033[41m'  BG_G='\033[42m'  BG_B='\033[44m' BG_Y='\033[43m'
    OK="✔" WARN="⚠" FAIL="✘" DOT="›" ARROW="→" KEY="⌨"
else
    RST="" BLD="" DIM="" UND="" RED="" GRN="" YEL="" BLU=""
    MAG="" CYN="" WHT="" GRY="" BG_R="" BG_G="" BG_B="" BG_Y=""
    OK="OK" WARN="!!" FAIL="XX" DOT=">" ARROW="->" KEY="KB"
fi

# ── Modifier Key Mapping ───────────────────────────────────────────────
# macOS NSUserKeyEquivalents uses: @ = ⌘  ~ = ⌥  ^ = ⌃  $ = ⇧
# We accept human-readable input and convert both ways.

human_to_plist() {
    # Converts "cmd+shift+o" or "⌘⇧O" → "@$O"
    local input="$1"
    local mods="" key=""

    # Normalize: lowercase, remove spaces, split on +
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]//g')

    # Handle already-symbolic input (⌘⇧⌥⌃)
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
            fn)              ;; # fn not supported in NSUserKeyEquivalents
            *)               key="$part" ;;
        esac
    done

    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')

    # Special key names → Unicode
    case "$key" in
        TAB)              key=$'\xe2\x87\xa5' ;; # ⇥
        RETURN|ENTER)     key=$'\xe2\x86\xa9' ;; # ↩
        DELETE|BACKSPACE) key=$'\xe2\x8c\xab' ;; # ⌫
        ESCAPE|ESC)       key=$'\xe2\x8e\x8b' ;; # ⎋
        UP)               key=$'\xe2\x86\x91' ;; # ↑
        DOWN)             key=$'\xe2\x86\x93' ;; # ↓
        LEFT)             key=$'\xe2\x86\x90' ;; # ←
        RIGHT)            key=$'\xe2\x86\x92' ;; # →
        SPACE)            key=" " ;;
        F[0-9]|F1[0-9])  ;; # Fn keys stay as-is
    esac

    echo "${mods}${key}"
}

plist_to_human() {
    # Converts "@$O" → "⌘⇧O"
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

# ── Domain Helpers ─────────────────────────────────────────────────────

resolve_domain() {
    local input="$1"
    case "$(echo "$input" | tr '[:upper:]' '[:lower:]')" in
        global|all|"-g"|nsglobaldomain|"all applications"|allapps)
            echo "-g"
            return ;;
    esac

    # Already a bundle ID?
    if [[ "$input" == *.* ]]; then
        echo "$input"
        return
    fi

    # Try to find the app by name
    local bundle_id
    bundle_id=$(osascript -e "id of app \"$input\"" 2>/dev/null || true)
    if [[ -n "$bundle_id" ]]; then
        echo "$bundle_id"
    else
        echo "$input"
    fi
}

domain_display_name() {
    local domain="$1"
    if [[ "$domain" == "-g" ]]; then
        echo "All Applications (Global)"
    else
        local name
        name=$(osascript -e "tell application \"System Events\" to get name of first application process whose bundle identifier is \"$domain\"" 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            echo "$name ($domain)"
        else
            echo "$domain"
        fi
    fi
}

# ── Register with com.apple.universalaccess ────────────────────────────

register_app_shortcut() {
    local domain="$1"
    [[ "$domain" == "-g" ]] && return 0

    local current
    current=$(defaults read "$UA_PLIST" "com.apple.custommenu.apps" 2>/dev/null || echo "")

    if ! echo "$current" | grep -q "$domain"; then
        defaults write "$UA_PLIST" "com.apple.custommenu.apps" -array-add "$domain" 2>/dev/null || true
    fi
}

unregister_app_if_empty() {
    local domain="$1"
    [[ "$domain" == "-g" ]] && return 0

    local remaining
    remaining=$(defaults read "$domain" NSUserKeyEquivalents 2>/dev/null || echo "")
    if [[ -z "$remaining" || "$remaining" == *"does not exist"* || "$remaining" == "{}" ]]; then
        local apps
        apps=$(defaults read "$UA_PLIST" "com.apple.custommenu.apps" 2>/dev/null || echo "")
        if [[ -n "$apps" ]]; then
            local new_apps=()
            while IFS= read -r line; do
                line=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[,;]*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$line" || "$line" == "(" || "$line" == ")" ]] && continue
                [[ "$line" == "$domain" ]] && continue
                new_apps+=("$line")
            done <<< "$apps"

            if (( ${#new_apps[@]} > 0 )); then
                local args=()
                for a in "${new_apps[@]}"; do args+=("$a"); done
                defaults write "$UA_PLIST" "com.apple.custommenu.apps" -array "${args[@]}"
            else
                defaults delete "$UA_PLIST" "com.apple.custommenu.apps" 2>/dev/null || true
            fi
        fi
    fi
}

# ── Apply Changes ──────────────────────────────────────────────────────

apply_changes() {
    local activator="/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    if [[ -x "$activator" ]]; then
        "$activator" -u 2>/dev/null || true
    fi
    killall cfprefsd 2>/dev/null || true
}

# ── Conflict Detection ─────────────────────────────────────────────────

check_all_conflicts() {
    local plist_key="$1"
    local exclude_domain="${2:-}"
    local exclude_menu="${3:-}"
    local human
    human=$(plist_to_human "$plist_key")
    local conflicts=0

    local scan
    scan=$(defaults find NSUserKeyEquivalents 2>/dev/null || echo "")

    local current_domain=""
    while IFS= read -r line; do
        if echo "$line" | grep -q "^Found.*keys in domain"; then
            current_domain=$(echo "$line" | sed "s/.*domain '//;s/'.*//" )
            continue
        fi

        if echo "$line" | grep -q "=.*\"${plist_key}\""; then
            if [[ "$current_domain" == "$exclude_domain" ]]; then
                local menu_item
                menu_item=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=.*//;s/^[[:space:]]*///')
                [[ "$menu_item" == "$exclude_menu" ]] && continue
            fi

            local menu_name
            menu_name=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=.*//;s/^[[:space:]]*///')
            local domain_label
            domain_label=$(domain_display_name "$current_domain")

            if (( conflicts == 0 )); then
                echo ""
                echo -e "  ${YEL}${WARN} Conflicts for ${WHT}${human}${RST}${YEL} (${plist_key}):${RST}"
            fi
            echo -e "    ${RED}${FAIL}${RST}  ${CYN}${domain_label}${RST} ${ARROW} \"${menu_name}\""
            ((conflicts++))
        fi
    done <<< "$scan"

    local -a sys_keys=('@$3' '@$4' '@$5' '@ ' '^@ ' '^@Q' '^@F' '@$N')
    local -a sys_names=(
        "Screenshot Full Screen"
        "Screenshot Selection"
        "Screenshot & Recording Options"
        "Spotlight"
        "Emoji & Symbols"
        "Lock Screen"
        "Toggle Fullscreen"
        "New Folder (Finder)"
    )

    local i
    for i in "${!sys_keys[@]}"; do
        if [[ "$plist_key" == "${sys_keys[$i]}" ]]; then
            if (( conflicts == 0 )); then
                echo ""
                echo -e "  ${YEL}${WARN} Conflicts for ${WHT}${human}${RST}${YEL} (${plist_key}):${RST}"
            fi
            echo -e "    ${RED}${FAIL}${RST}  ${MAG}macOS System${RST} ${ARROW} ${sys_names[$i]}"
            ((conflicts++))
        fi
    done

    if (( conflicts > 0 )); then
        echo ""
        return 0
    fi
    return 1
}

# ════════════════════════════════════════════════════════════════════════
#  COMMANDS
# ════════════════════════════════════════════════════════════════════════

cmd_add() {
    echo -e "\n  ${GRN}${BLD}${KEY} Add Shortcut${RST}\n"

    local app_input domain
    if [[ -n "${1:-}" ]]; then
        app_input="$1"; shift
    else
        echo -e "  ${DIM}Tip: \"global\" for all apps, or app name like \"Safari\"${RST}"
        read -rp "  App (or global): " app_input
    fi
    [[ -z "$app_input" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }
    domain=$(resolve_domain "$app_input")
    echo -e "  ${DIM}${ARROW} Domain: ${domain}${RST}"

    local menu_item
    if [[ -n "${1:-}" ]]; then
        menu_item="$1"; shift
    else
        echo -e "\n  ${DIM}Exact menu item name (e.g. \"Show Package Contents\")${RST}"
        read -rp "  Menu item: " menu_item
    fi
    [[ -z "$menu_item" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }

    local shortcut_input plist_key
    if [[ -n "${1:-}" ]]; then
        shortcut_input="$1"; shift
    else
        echo -e "\n  ${DIM}e.g. cmd+shift+o, or ⌘⇧O${RST}"
        read -rp "  Shortcut: " shortcut_input
    fi
    [[ -z "$shortcut_input" ]] && { echo -e "  ${RED}Aborted.${RST}"; return 1; }
    plist_key=$(human_to_plist "$shortcut_input")
    local human_key
    human_key=$(plist_to_human "$plist_key")

    if check_all_conflicts "$plist_key" "$domain" "$menu_item"; then
        read -rp "  Continue anyway? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || { echo -e "  ${YEL}Cancelled.${RST}"; return 0; }
    else
        echo -e "  ${GRN}${OK} No conflicts for ${WHT}${human_key}${RST}"
    fi

    defaults write "$domain" NSUserKeyEquivalents -dict-add "$menu_item" "$plist_key"
    register_app_shortcut "$domain"
    apply_changes

    local domain_label
    domain_label=$(domain_display_name "$domain")
    echo -e "\n  ${GRN}${BLD}${OK} Added:${RST} ${WHT}${human_key}${RST} ${ARROW} \"${menu_item}\" in ${CYN}${domain_label}${RST}"
    echo -e "  ${DIM}Restart the app for the shortcut to take effect.${RST}\n"
}

cmd_list() {
    local filter="${1:-}"

    echo -e "\n  ${CYN}${BLD}${KEY} Native macOS Keyboard Shortcuts${RST}"
    echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    local scan total=0 current_domain="" domain_printed=0
    scan=$(defaults find NSUserKeyEquivalents 2>/dev/null || echo "")

    if [[ -z "$scan" ]]; then
        echo -e "  ${DIM}No custom shortcuts found.${RST}\n"
        return
    fi

    while IFS= read -r line; do
        if echo "$line" | grep -q "^Found.*keys in domain"; then
            current_domain=$(echo "$line" | sed "s/.*domain '//;s/'.*//" )
            domain_printed=0
            continue
        fi

        if echo "$line" | grep -qE '^\s+".+"\s*=\s*".+"'; then
            local menu_item shortcut_raw human_shortcut
            menu_item=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=.*//')
            shortcut_raw=$(echo "$line" | sed 's/.*=[[:space:]]*"//;s/"[[:space:]]*;[[:space:]]*$//')
            human_shortcut=$(plist_to_human "$shortcut_raw")

            if [[ -n "$filter" ]]; then
                local haystack="${current_domain}|${menu_item}|${human_shortcut}"
                echo "$haystack" | grep -qi "$filter" || continue
            fi

            if (( !domain_printed )); then
                local domain_label
                domain_label=$(domain_display_name "$current_domain")
                echo -e "\n  ${BLU}${BLD}${DOT} ${domain_label}${RST}"
                domain_printed=1
            fi

            printf "    ${WHT}%-16s${RST}  ${ARROW}  %-36s  ${GRY}%s${RST}\n" \
                "$human_shortcut" "$menu_item" "($shortcut_raw)"
            ((total++))
        fi
    done <<< "$scan"

    echo -e "\n  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo -e "  ${CYN}${total} shortcut(s)${RST}"
    [[ -n "$filter" ]] && echo -e "  ${DIM}filter: \"${filter}\"${RST}"
    echo ""
}

cmd_delete() {
    echo -e "\n  ${RED}${BLD}${KEY} Delete Shortcut${RST}\n"

    local app_input domain
    if [[ -n "${1:-}" ]]; then
        app_input="$1"; shift
    else
        read -rp "  App (or global): " app_input
    fi
    domain=$(resolve_domain "$app_input")

    local current
    current=$(defaults read "$domain" NSUserKeyEquivalents 2>/dev/null || echo "")
    if [[ -z "$current" || "$current" == *"does not exist"* ]]; then
        echo -e "  ${DIM}No shortcuts found for $(domain_display_name "$domain")${RST}\n"
        return 1
    fi

    echo -e "  ${DIM}Current shortcuts for $(domain_display_name "$domain"):${RST}"

    local -a menu_items=()
    local idx=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s+".+"\s*=\s*".+"'; then
            local mi sc hsc
            mi=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=.*//')
            sc=$(echo "$line" | sed 's/.*=[[:space:]]*"//;s/"[[:space:]]*;[[:space:]]*$//')
            hsc=$(plist_to_human "$sc")
            ((idx++))
            menu_items+=("$mi")
            printf "    ${YEL}%2d${RST})  ${WHT}%-14s${RST}  ${ARROW}  %s\n" "$idx" "$hsc" "$mi"
        fi
    done <<< "$current"

    if (( idx == 0 )); then
        echo -e "  ${DIM}No shortcuts to delete.${RST}\n"
        return 0
    fi

    echo ""
    local choice
    if [[ -n "${1:-}" ]]; then
        choice="$1"; shift
    else
        read -rp "  Delete # (or menu item name): " choice
    fi

    local target_menu=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= idx )); then
        target_menu="${menu_items[$((choice-1))]}"
    else
        target_menu="$choice"
    fi

    read -rp "  Delete \"${target_menu}\" from $(domain_display_name "$domain")? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo -e "  ${YEL}Cancelled.${RST}"; return 0; }

    python3 -c "
import subprocess, plistlib, sys, os

domain = '$domain'
menu = '''$target_menu'''

if domain == '-g':
    path = os.path.expanduser('~/Library/Preferences/.GlobalPreferences.plist')
else:
    path = os.path.expanduser(f'~/Library/Preferences/{domain}.plist')

result = subprocess.run(['defaults', 'read', domain, 'NSUserKeyEquivalents'],
                       capture_output=True, text=True)
if result.returncode != 0:
    print('Could not read shortcuts', file=sys.stderr)
    sys.exit(1)

result2 = subprocess.run(['defaults', 'export', domain, '-'],
                        capture_output=True)
data = plistlib.loads(result2.stdout)
if 'NSUserKeyEquivalents' in data and menu in data['NSUserKeyEquivalents']:
    del data['NSUserKeyEquivalents'][menu]
    if not data['NSUserKeyEquivalents']:
        del data['NSUserKeyEquivalents']
    subprocess.run(['defaults', 'import', domain, '-'], input=plistlib.dumps(data))
    print('OK')
else:
    print('NOT_FOUND')
    sys.exit(1)
" 2>/dev/null

    if [[ $? -eq 0 ]]; then
        unregister_app_if_empty "$domain"
        apply_changes
        echo -e "  ${GRN}${OK} Deleted \"${target_menu}\" from $(domain_display_name "$domain").${RST}"
        echo -e "  ${DIM}Restart the app for changes to take effect.${RST}\n"
    else
        echo -e "  ${RED}${FAIL} Failed to delete.${RST}\n"
    fi
}

cmd_edit() {
    echo -e "\n  ${YEL}${BLD}${KEY} Edit Shortcut${RST}\n"

    local app_input domain
    if [[ -n "${1:-}" ]]; then
        app_input="$1"; shift
    else
        read -rp "  App (or global): " app_input
    fi
    domain=$(resolve_domain "$app_input")

    local current
    current=$(defaults read "$domain" NSUserKeyEquivalents 2>/dev/null || echo "")
    if [[ -z "$current" || "$current" == *"does not exist"* ]]; then
        echo -e "  ${DIM}No shortcuts found for $(domain_display_name "$domain").${RST}\n"
        return 1
    fi

    echo -e "  ${DIM}Shortcuts for $(domain_display_name "$domain"):${RST}"

    local -a menu_items=() shortcut_raws=()
    local idx=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s+".+"\s*=\s*".+"'; then
            local mi sc hsc
            mi=$(echo "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=.*//')
            sc=$(echo "$line" | sed 's/.*=[[:space:]]*"//;s/"[[:space:]]*;[[:space:]]*$//')
            hsc=$(plist_to_human "$sc")
            ((idx++))
            menu_items+=("$mi")
            shortcut_raws+=("$sc")
            printf "    ${YEL}%2d${RST})  ${WHT}%-14s${RST}  ${ARROW}  %s\n" "$idx" "$hsc" "$mi"
        fi
    done <<< "$current"

    echo ""
    local choice
    read -rp "  Edit #: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > idx )); then
        echo -e "  ${RED}Invalid selection.${RST}\n"
        return 1
    fi

    local target_menu="${menu_items[$((choice-1))]}"
    local old_sc="${shortcut_raws[$((choice-1))]}"
    local old_human
    old_human=$(plist_to_human "$old_sc")

    echo -e "\n  ${DIM}Editing: \"${target_menu}\" — currently ${WHT}${old_human}${RST}"
    echo -e "  ${DIM}(press Enter to keep current value)${RST}"

    local new_menu new_shortcut_input
    read -rp "  New menu item [${target_menu}]: " new_menu
    new_menu="${new_menu:-$target_menu}"

    read -rp "  New shortcut [${old_human}]: " new_shortcut_input

    local new_plist_key
    if [[ -n "$new_shortcut_input" ]]; then
        new_plist_key=$(human_to_plist "$new_shortcut_input")
    else
        new_plist_key="$old_sc"
    fi

    local new_human
    new_human=$(plist_to_human "$new_plist_key")

    if [[ "$new_plist_key" != "$old_sc" ]]; then
        if check_all_conflicts "$new_plist_key" "$domain" "$new_menu"; then
            read -rp "  Continue anyway? [y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] || { echo -e "  ${YEL}Cancelled.${RST}"; return 0; }
        fi
    fi

    if [[ "$new_menu" != "$target_menu" ]]; then
        python3 -c "
import subprocess, plistlib, os
domain = '$domain'
result = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
data = plistlib.loads(result.stdout)
if 'NSUserKeyEquivalents' in data and '''$target_menu''' in data['NSUserKeyEquivalents']:
    del data['NSUserKeyEquivalents']['''$target_menu''']
    subprocess.run(['defaults', 'import', domain, '-'], input=plistlib.dumps(data))
" 2>/dev/null
    fi

    defaults write "$domain" NSUserKeyEquivalents -dict-add "$new_menu" "$new_plist_key"
    register_app_shortcut "$domain"
    apply_changes

    echo -e "\n  ${GRN}${OK} Updated:${RST} ${WHT}${new_human}${RST} ${ARROW} \"${new_menu}\" in $(domain_display_name "$domain")"
    echo -e "  ${DIM}Restart the app for changes to take effect.${RST}\n"
}

cmd_check() {
    echo -e "\n  ${BLU}${BLD}🔍 Check Shortcut${RST}\n"

    local shortcut_input="${1:-}"
    [[ -z "$shortcut_input" ]] && read -rp "  Shortcut to check: " shortcut_input
    [[ -z "$shortcut_input" ]] && return 1

    local plist_key human_key
    plist_key=$(human_to_plist "$shortcut_input")
    human_key=$(plist_to_human "$plist_key")

    echo -e "  ${DIM}Checking ${WHT}${human_key}${RST}${DIM} (plist: \"${plist_key}\")...${RST}"

    if ! check_all_conflicts "$plist_key"; then
        echo -e "  ${GRN}${BLD}${OK} ${WHT}${human_key}${RST}${GRN} is available — no conflicts found.${RST}\n"
    fi
}

cmd_export() {
    local outfile="${1:-$HOME/Desktop/keyboard-shortcuts-backup.plist}"

    echo -e "\n  ${MAG}${BLD}📦 Export Shortcuts${RST}\n"

    python3 -c "
import subprocess, plistlib, os, sys, re

result = subprocess.run(['defaults', 'find', 'NSUserKeyEquivalents'],
                       capture_output=True, text=True)

export_data = {}
current_domain = None

for line in result.stdout.splitlines():
    m = re.match(r\"Found \d+ keys in domain '(.+)'\", line)
    if m:
        current_domain = m.group(1)
        continue

    m2 = re.match(r'\s+\"(.+)\"\s*=\s*\"(.+)\"\s*;', line)
    if m2 and current_domain:
        if current_domain not in export_data:
            export_data[current_domain] = {}
        export_data[current_domain][m2.group(1)] = m2.group(2)

outpath = '$outfile'
with open(outpath, 'wb') as f:
    plistlib.dump(export_data, f)
print(f'Exported {sum(len(v) for v in export_data.values())} shortcuts from {len(export_data)} domains')
print(f'Saved to: {outpath}')
" 2>/dev/null

    echo -e "  ${GRN}${OK} Done.${RST}\n"
}

cmd_import() {
    local infile="${1:-}"
    [[ -z "$infile" ]] && read -rp "  File to import: " infile
    [[ ! -f "$infile" ]] && { echo -e "  ${RED}File not found: ${infile}${RST}"; return 1; }

    echo -e "\n  ${MAG}${BLD}📥 Import Shortcuts${RST}\n"

    python3 -c "
import plistlib, subprocess, sys

with open('$infile', 'rb') as f:
    data = plistlib.load(f)

total = 0
for domain, shortcuts in data.items():
    for menu_item, key_equiv in shortcuts.items():
        cmd = ['defaults', 'write']
        cmd.append(domain)
        cmd.extend(['NSUserKeyEquivalents', '-dict-add', menu_item, key_equiv])
        subprocess.run(cmd)
        total += 1
        if domain not in ('-g', 'NSGlobalDomain'):
            subprocess.run(['defaults', 'write', 'com.apple.universalaccess',
                           'com.apple.custommenu.apps', '-array-add', domain],
                          capture_output=True)

print(f'Imported {total} shortcuts from {len(data)} domains')
" 2>/dev/null

    apply_changes
    echo -e "  ${GRN}${OK} Done. Restart apps for changes to take effect.${RST}\n"
}

cmd_nuke() {
    echo -e "\n  ${RED}${BLD}💀 Remove ALL Custom Shortcuts${RST}\n"
    echo -e "  ${RED}This will delete every NSUserKeyEquivalents entry across all apps.${RST}"
    read -rp "  Type 'CONFIRM' to proceed: " confirm
    [[ "$confirm" == "CONFIRM" ]] || { echo -e "  ${YEL}Cancelled.${RST}\n"; return 0; }

    python3 -c "
import subprocess, re

result = subprocess.run(['defaults', 'find', 'NSUserKeyEquivalents'],
                       capture_output=True, text=True)
domains = set()
for line in result.stdout.splitlines():
    m = re.match(r\"Found \d+ keys in domain '(.+)'\", line)
    if m:
        domains.add(m.group(1))

for d in domains:
    subprocess.run(['defaults', 'delete', d, 'NSUserKeyEquivalents'], capture_output=True)
    print(f'  Cleared: {d}')

subprocess.run(['defaults', 'delete', 'com.apple.universalaccess', 'com.apple.custommenu.apps'],
              capture_output=True)
print(f'Removed shortcuts from {len(domains)} domains')
" 2>/dev/null

    apply_changes
    echo -e "  ${GRN}${OK} All custom shortcuts removed.${RST}\n"
}

# ── Daemon Helpers ────────────────────────────────────────────────────
# The snippet daemon is a compiled Swift binary that registers global
# hotkeys via Carbon RegisterEventHotKey and pastes text via CGEvent.
# It runs as a launchd agent so it starts automatically on login.

ensure_daemon() {
    if [[ -f "$DAEMON_BIN" ]]; then
        return 0
    fi

    echo -e "  ${DIM}Compiling snippet daemon (first time only)...${RST}"
    mkdir -p "$SNIPPET_CONFIG_DIR"

    local src=""
    # Check for source next to this script
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$script_dir/keys-daemon.swift" ]]; then
        src="$script_dir/keys-daemon.swift"
    else
        # Download from GitHub
        src="/tmp/keys-daemon-$$.swift"
        if ! curl -fsSL "$DAEMON_SRC_URL" -o "$src" 2>/dev/null; then
            echo -e "  ${RED}${FAIL} Failed to download daemon source.${RST}"
            return 1
        fi
    fi

    # Create .app bundle structure so macOS grants Accessibility to the app, not Terminal
    local app_contents="$DAEMON_APP/Contents"
    local app_macos="$app_contents/MacOS"
    mkdir -p "$app_macos"

    if ! swiftc -o "$DAEMON_BIN" "$src" -framework AppKit -framework Carbon 2>&1; then
        echo -e "  ${RED}${FAIL} Failed to compile. Install Xcode Command Line Tools: xcode-select --install${RST}"
        [[ "$src" == /tmp/* ]] && rm -f "$src"
        return 1
    fi

    # Create Info.plist for the .app bundle
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

    # Remove old non-bundled binary if it exists
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
    # Stop if running
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    # Create/update plist
    create_daemon_plist
    # Start
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

# ── Snippet Commands ───────────────────────────────────────────────────
# Snippets use a compiled Swift daemon that registers global hotkeys
# and pastes text via the clipboard + simulated Cmd+V.
# Requires Accessibility permission (prompted on first run).

cmd_snippet() {
    case "${1:-}" in
        add)    shift; cmd_snippet_add "$@" ;;
        list|ls) cmd_snippet_list ;;
        delete|rm) shift; cmd_snippet_delete "$@" ;;
        status) cmd_snippet_status ;;
        restart) restart_daemon; echo -e "  ${GRN}${OK} Daemon restarted.${RST}" ;;
        stop)   stop_daemon; echo -e "  ${GRN}${OK} Daemon stopped.${RST}" ;;
        *)      cmd_snippet_help ;;
    esac
}

cmd_snippet_help() {
    echo -e "
  ${BLU}${BLD}${KEY} Snippet — Paste text with a global shortcut${RST}

  ${BLD}USAGE${RST}
    keys snippet add <name> <shortcut> <text>
    keys snippet list
    keys snippet delete <name>
    keys snippet status
    keys snippet restart

  ${BLD}EXAMPLES${RST}
    ${GRY}\$${RST} keys snippet add \"Zoom\" cmd+shift+z \"https://zoom.us/j/123456\"
    ${GRY}\$${RST} keys snippet add \"Email\" cmd+shift+e \"me@example.com\"
    ${GRY}\$${RST} keys snippet list
    ${GRY}\$${RST} keys snippet delete \"Zoom\"

  ${BLD}HOW IT WORKS${RST}
    Runs a lightweight background daemon that listens for global hotkeys
    and pastes your text via the clipboard. Starts automatically on login.
    Requires Accessibility permission (you'll be prompted on first use).
"
}

cmd_snippet_status() {
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

cmd_snippet_add() {
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
        echo -e "\n  ${DIM}e.g. cmd+shift+z${RST}"
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

    # ── Conflict check
    if check_all_conflicts "$plist_key"; then
        read -rp "  Continue anyway? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || { echo -e "  ${YEL}Cancelled.${RST}"; return 0; }
    else
        echo -e "  ${GRN}${OK} No conflicts for ${WHT}${human_key}${RST}"
    fi

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

    # Give daemon a moment to start and register hotkeys
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
        echo -e "  ${DIM}Then run: keys snippet restart${RST}"
    fi
    echo ""
}

cmd_snippet_list() {
    echo -e "\n  ${CYN}${BLD}${KEY} Snippets${RST}"
    echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    if [[ ! -f "$SNIPPET_CONFIG" ]]; then
        echo -e "  ${DIM}No snippets yet. Create one with: keys snippet add${RST}\n"
        return
    fi

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
    done

    echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    local status
    status=$(daemon_status)
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GRN}${OK} Daemon: running${RST}\n"
    else
        echo -e "  ${YEL}${WARN} Daemon: stopped${RST} — run ${WHT}keys snippet restart${RST}\n"
    fi
}

cmd_snippet_delete() {
    echo -e "\n  ${RED}${BLD}${KEY} Delete Snippet${RST}\n"

    local name
    if [[ -n "${1:-}" ]]; then
        name="$1"; shift
    else
        # Show list first
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

    # Check if snippet exists in config
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

    # Remove from config
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

    # Check if any snippets remain
    local remaining
    remaining=$(python3 -c "import json; print(len(json.load(open('$SNIPPET_CONFIG'))))" 2>/dev/null || echo "0")

    if [[ "$remaining" == "0" ]]; then
        stop_daemon
        echo -e "  ${GRN}${OK} Deleted snippet \"${name}\". No snippets left — daemon stopped.${RST}\n"
    else
        restart_daemon
        echo -e "  ${GRN}${OK} Deleted snippet \"${name}\". Daemon restarted with ${remaining} snippet(s).${RST}\n"
    fi

    # Clean up old Automator workflow if it exists
    local service_name="${SNIPPET_PREFIX} - ${name}"
    local workflow_path="${SERVICES_DIR}/${service_name}.workflow"
    [[ -d "$workflow_path" ]] && rm -rf "$workflow_path"
}

# ── Interactive Mode ───────────────────────────────────────────────────

cmd_interactive() {
    while true; do
        echo -e "\n${BLU}${BLD}  ⌨  keys${RST} ${GRY}v${VERSION}${RST} — ${DIM}Native macOS Shortcut Manager${RST}"
        echo -e "  ${GRY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "   ${GRN}a${RST}dd       Add a new shortcut (writes to macOS prefs)"
        echo -e "   ${CYN}l${RST}ist      List all native custom shortcuts"
        echo -e "   ${YEL}e${RST}dit      Edit an existing shortcut"
        echo -e "   ${RED}d${RST}elete    Delete a shortcut"
        echo -e "   ${BLU}c${RST}heck     Check shortcut for conflicts"
        echo -e "   e${MAG}x${RST}port    Export all shortcuts (backup)"
        echo -e "   ${MAG}i${RST}mport    Import shortcuts from backup"
        echo -e "   ${MAG}s${RST}nippet   Paste text with a shortcut (e.g. Zoom link)"
        echo -e "   ${BLU}u${RST}pdate    Update keys to latest version"
        echo -e "   ${RED}n${RST}uke      Remove all custom shortcuts"
        echo -e "   ${GRY}q${RST}uit"
        echo ""
        read -rp "  ${DOT} " choice

        case "$choice" in
            a|add)      cmd_add ;;
            l|list|ls)  cmd_list ;;
            e|edit)     cmd_edit ;;
            d|delete|rm) cmd_delete ;;
            c|check)    cmd_check ;;
            x|export)   cmd_export ;;
            i|import)   cmd_import ;;
            s|snippet)  cmd_snippet_help; read -rp "  ${DOT} snippet " sub; cmd_snippet "$sub" ;;
            u|update)   cmd_update ;;
            n|nuke)     cmd_nuke ;;
            q|quit|exit) echo -e "  ${DIM}Bye.${RST}"; exit 0 ;;
            *)          echo -e "  ${RED}?${RST} Unknown: ${choice}" ;;
        esac
    done
}

# ── Usage ──────────────────────────────────────────────────────────────

usage() {
    echo -e "
${BLU}${BLD}  ⌨  keys${RST} ${GRY}v${VERSION}${RST} — Native macOS Keyboard Shortcut Manager

  ${BLD}USAGE${RST}
    keys <command> [options]

  ${BLD}COMMANDS${RST}
    ${GRN}add${RST} [app] [menu] [shortcut]   Add a shortcut (writes to native macOS prefs)
    ${CYN}list${RST} [filter]                  List all custom shortcuts
    ${YEL}edit${RST} [app]                     Edit a shortcut interactively
    ${RED}delete${RST} [app] [#]               Delete a shortcut
    ${BLU}check${RST} <shortcut>               Check for conflicts system-wide
    ${MAG}export${RST} [file]                  Backup all shortcuts to plist
    ${MAG}import${RST} <file>                  Restore shortcuts from backup
    ${MAG}snippet${RST} add <name> <key> <text>  Paste text with a shortcut
    ${MAG}snippet${RST} list                    List all snippets
    ${MAG}snippet${RST} delete <name>            Delete a snippet
    ${MAG}snippet${RST} status                   Show daemon status
    ${MAG}snippet${RST} restart                  Restart the snippet daemon
    ${BLU}update${RST}                         Update keys to the latest version
    ${RED}nuke${RST}                           Remove ALL custom shortcuts

  ${BLD}SHORTCUT FORMAT${RST}
    Human-readable: ${WHT}cmd+shift+o${RST}  ${WHT}ctrl+alt+k${RST}  ${WHT}cmd+opt+shift+p${RST}
    Symbol style:   ${WHT}⌘⇧O${RST}          ${WHT}⌃⌥K${RST}        ${WHT}⌘⌥⇧P${RST}
    macOS plist:    ${GRY}@\$O${RST}           ${GRY}^~K${RST}        ${GRY}@~\$P${RST}

  ${BLD}EXAMPLES${RST}
    ${GRY}\${RST} keys add Safari \"Show Reader\" cmd+shift+r
    ${GRY}\${RST} keys add global \"Emoji & Symbols\" ctrl+cmd+space
    ${GRY}\${RST} keys add Finder \"Show Package Contents\" cmd+shift+o
    ${GRY}\${RST} keys check cmd+shift+o
    ${GRY}\${RST} keys list
    ${GRY}\${RST} keys list safari
    ${GRY}\${RST} keys delete Finder
    ${GRY}\${RST} keys snippet add \"Zoom\" cmd+shift+z \"https://zoom.us/j/123456\"
    ${GRY}\${RST} keys snippet list
    ${GRY}\${RST} keys export ~/Desktop/my-shortcuts.plist

  ${BLD}HOW IT WORKS${RST}
    This tool uses ${WHT}defaults write${RST} to store shortcuts in the native macOS
    ${WHT}NSUserKeyEquivalents${RST} plist system — the same place System Settings
    writes them. Shortcuts appear in:
      ${CYN}System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts${RST}

  ${BLD}STORAGE${RST}
    Global:   ${GRY}~/Library/Preferences/.GlobalPreferences.plist${RST}
    Per-app:  ${GRY}~/Library/Preferences/<bundle-id>.plist${RST}
    Registry: ${GRY}~/Library/Preferences/com.apple.universalaccess.plist${RST}
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
        # Check if file contents differ even with same version
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
    list|ls)        shift; cmd_list "${1:-}" ;;
    edit)           shift; cmd_edit "${1:-}" ;;
    delete|rm|del)  shift; cmd_delete "$@" ;;
    check|test)     shift; cmd_check "${1:-}" ;;
    export|backup)  shift; cmd_export "${1:-}" ;;
    import|restore) shift; cmd_import "${1:-}" ;;
    snippet)        shift; cmd_snippet "$@" ;;
    update|upgrade) cmd_update ;;
    nuke|reset)     cmd_nuke ;;
    help|-h|--help) usage ;;
    version|-v|--version) echo "keys v${VERSION}" ;;
    "")             cmd_interactive ;;
    *)              echo -e "${RED}Unknown command: $1${RST}"; usage; exit 1 ;;
esac
