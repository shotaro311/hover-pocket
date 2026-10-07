import AppKit
import Carbon

enum AppShortcutBindings {
    static let defaults = ["panel": "Cmd+Alt+P", "chat": "Cmd+Alt+C", "library": "Cmd+Alt+L", "settings": "Cmd+Alt+O", "voice": "Cmd+Alt+V", "regionRecording": "Cmd+Alt+G"]
    static let actions = ["panel", "chat", "library", "settings", "voice", "screenshot", "recording", "regionRecording"]
    static let keys: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "O": 31, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "Space": 49, "Return": 36, "Left": 123, "Right": 124, "Down": 125, "Up": 126
    ]
    struct Key: Hashable { let code: UInt32; let modifiers: UInt32 }
    static func parse(_ text: String) throws -> Key? {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let pieces = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count >= 2, let last = pieces.last, let code = keys.first(where: { $0.key.lowercased() == last.lowercased() })?.value else {
            throw LibraryError.message("Cmd・Ctrl・Altと文字、数字、Fキーを組み合わせてください。")
        }
        var modifiers: UInt32 = 0
        for piece in pieces.dropLast() {
            let bit: UInt32
            switch piece.lowercased() {
            case "cmd", "command": bit = UInt32(cmdKey)
            case "ctrl", "control": bit = UInt32(controlKey)
            case "alt", "option": bit = UInt32(optionKey)
            case "shift": bit = UInt32(shiftKey)
            default: throw LibraryError.message("修飾キーを確認してください。")
            }
            guard modifiers & bit == 0 else { throw LibraryError.message("同じ修飾キーが重複しています。") }
            modifiers |= bit
        }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { throw LibraryError.message("Cmd・Ctrl・Altのいずれかを含めてください。") }
        return Key(code: code, modifiers: modifiers)
    }
    static func format(code: UInt32, modifiers: UInt32) -> String {
        guard modifiers != 0, let name = keys.first(where: { $0.value == code })?.key else { return "" }
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Alt") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        return (parts + [name]).joined(separator: "+")
    }
    static func validate(_ bindings: [String: String]) throws -> [String: Key] {
        guard Set(bindings.keys) == Set(actions) else { throw LibraryError.message("ショートカットの操作を確認してください。") }
        var result: [String: Key] = [:], used = Set<Key>()
        for action in actions {
            guard let key = try parse(bindings[action] ?? "") else { continue }
            guard used.insert(key).inserted else { throw LibraryError.message("同じキーが複数の操作に設定されています。") }
            result[action] = key
        }
        return result
    }
}
