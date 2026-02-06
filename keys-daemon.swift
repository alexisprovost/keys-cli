import AppKit
import Carbon

// ── Snippet storage ───────────────────────────────────────────────────
var snippetTexts: [UInt32: String] = [:]

// ── Key code mapping ──────────────────────────────────────────────────
func charToKeyCode(_ ch: Character) -> UInt32? {
    let map: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        " ": 0x31,
    ]
    return map[Character(String(ch).lowercased())]
}

// ── Parse plist shortcut format (@$Z → modifiers + keycode) ───────────
func parseShortcut(_ s: String) -> (UInt32, UInt32)? {
    var mods: UInt32 = 0
    var key: Character?
    for ch in s {
        switch ch {
        case "@": mods |= UInt32(cmdKey)
        case "$": mods |= UInt32(shiftKey)
        case "~": mods |= UInt32(optionKey)
        case "^": mods |= UInt32(controlKey)
        default: key = ch
        }
    }
    guard let k = key, let code = charToKeyCode(k) else { return nil }
    return (mods, code)
}

// ── Paste text via clipboard + simulated Cmd+V ────────────────────────
func pasteText(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(50_000) // 50ms for clipboard to settle

    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// ── Carbon hotkey callback ────────────────────────────────────────────
func hotkeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    GetEventParameter(event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil,
                      MemoryLayout<EventHotKeyID>.size,
                      nil,
                      &hkID)
    if let text = snippetTexts[hkID.id] {
        pasteText(text)
    }
    return noErr
}

// ── Main ──────────────────────────────────────────────────────────────

// Request Accessibility permission (prompts user on first run)
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
if !trusted {
    fputs("⚠ Accessibility permission required. Grant it in the dialog, then restart.\n", stderr)
}

// Load snippets
let path = NSString(string: "~/.config/keys/snippets.json").expandingTildeInPath
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let snippets = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
      !snippets.isEmpty
else {
    fputs("No snippets found at ~/.config/keys/snippets.json\n", stderr)
    exit(1)
}

// Install Carbon event handler
var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &eventSpec, nil, nil)

// Register each snippet's hotkey
var nextID: UInt32 = 1
for (name, info) in snippets {
    guard let shortcut = info["shortcut"] as? String,
          let text = info["text"] as? String,
          let (mods, keyCode) = parseShortcut(shortcut)
    else { continue }

    let hkID = EventHotKeyID(signature: OSType(0x4B455953), id: nextID)
    snippetTexts[nextID] = text

    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
    if status == noErr {
        print("✔ \(name) registered")
    }
    nextID += 1
}

print("keys-daemon: \(snippetTexts.count) snippet(s) active")

// Run event loop
NSApplication.shared.run()
