import Foundation
import CoreGraphics

final class InputBuffer {
    private(set) var keycodes: [UInt16] = []
    private let maxSize = 64

    var isEmpty: Bool { keycodes.isEmpty }
    var count: Int { keycodes.count }

    func append(_ keycode: UInt16) {
        if keycodes.count >= maxSize { keycodes.removeFirst() }
        keycodes.append(keycode)
    }

    func removeLast() {
        guard !keycodes.isEmpty else { return }
        keycodes.removeLast()
    }

    func clear() {
        keycodes.removeAll(keepingCapacity: true)
    }

    func currentWord() -> [UInt16] { keycodes }

    static func isWordBoundary(_ keycode: UInt16) -> Bool {
        switch keycode {
        case 49, 36, 48, 53, 76: return true // space, return, tab, esc, numpad enter
        default: return false
        }
    }

    /// Whether this boundary is safe to trigger an auto-correction on.
    /// Space is safe. Enter/Tab/Esc are NOT — in chat apps like Telegram/Slack,
    /// Enter sends the message instantly and the input field becomes empty,
    /// so our backspaces + retype would land on the wrong (next) context.
    static func isCorrectableBoundary(_ keycode: UInt16) -> Bool {
        keycode == 49 // only plain space
    }

    static func isDeleteKey(_ keycode: UInt16) -> Bool { keycode == 51 }

    /// ALL keys that produce letters in ANY installed layout
    /// Includes , . [ ] ; ' ` because they are б ю х ъ ж э ё in Russian
    static func isLetterKey(_ keycode: UInt16) -> Bool {
        let letterCodes: Set<UInt16> = [
            0,  // A / Ф
            1,  // S / Ы
            2,  // D / В
            3,  // F / А
            4,  // H / Р
            5,  // G / П
            6,  // Z / Я
            7,  // X / Ч
            8,  // C / С
            9,  // V / М
            11, // B / И
            12, // Q / Й
            13, // W / Ц
            14, // E / У
            15, // R / К
            16, // Y / Н
            17, // T / Е
            30, // ] / Ъ
            31, // O / Щ
            32, // U / Г
            33, // [ / Х
            34, // I / Ш
            35, // P / З
            37, // L / Д
            38, // J / О
            39, // ' / Э
            40, // K / Л
            41, // ; / Ж
            43, // , / Б  ← CRITICAL: letter in Russian!
            45, // N / Т
            46, // M / Ь
            47, // . / Ю  ← CRITICAL: letter in Russian!
            50, // ` / Ё
        ]
        return letterCodes.contains(keycode)
    }

    /// Keys that type Cyrillic letters but ASCII punctuation in Latin layouts.
    /// In ru they are letters; in en they behave as word boundaries.
    private static let cyrillicOnlyLetterCodes: Set<UInt16> = [
        30, // ] / Ъ
        33, // [ / Х
        39, // ' / Э
        41, // ; / Ж
        43, // , / Б
        47, // . / Ю
        50, // ` / Ё
    ]

    /// Returns true if this keycode should be treated as a word-boundary / punctuation
    /// given the currently active layout's language code (e.g. "en", "ru").
    ///
    /// In EN layout: `, . ; ' [ ] ``  are punctuation (in RU layout they are letters).
    /// In RU layout: Shift+`,` and Shift+`.` produce `,` and `.` — also punctuation.
    ///               Other keys (; ' [ ] `) stay as shifted letters even with Shift.
    static func isPunctuationIn(keycode: UInt16, languageCode: String?, flags: CGEventFlags = []) -> Bool {
        guard let lang = languageCode else { return false }
        if lang == "en" {
            return cyrillicOnlyLetterCodes.contains(keycode)
        }
        if lang == "ru" && flags.contains(.maskShift) {
            // In ЙЦУКЕН, Shift+б → `,` and Shift+ю → `.`
            return keycode == 43 || keycode == 47
        }
        return false
    }

    /// For the punctuation keycodes above, return the ASCII character the user
    /// actually typed (the trigger that already landed in the text field).
    /// Needed so we can restore it after backspacing over it.
    static func enPunctuationChar(keycode: UInt16) -> String? {
        switch keycode {
        case 30: return "]"
        case 33: return "["
        case 39: return "'"
        case 41: return ";"
        case 43: return ","
        case 47: return "."
        case 50: return "`"
        default: return nil
        }
    }

    /// Numbers and keys that are NOT letters in any layout
    static func isNumberOrSpecial(_ keycode: UInt16) -> Bool {
        let codes: Set<UInt16> = [
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, // 1-0, -, =
            44, // / (точка в RU layout, но не буква)
        ]
        return codes.contains(keycode)
    }

    /// The actual character the user typed on a number/`-`/`=`/`/` key.
    /// Used as a trailing char when correction triggers on a digit.
    static func digitChar(keycode: UInt16) -> String? {
        switch keycode {
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 27: return "-"
        case 24: return "="
        case 44: return "/"
        default: return nil
        }
    }

    static func isModifierActive(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }
}
