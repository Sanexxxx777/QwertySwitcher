import Foundation
import Carbon

struct KeyboardLayout {
    let id: String          // "com.apple.keylayout.ABC"
    let name: String        // "ABC"
    let source: TISInputSource
    let languageCode: String // "en", "ru"

    var isEnglish: Bool { languageCode == "en" }
    var isRussian: Bool { languageCode == "ru" }
}

enum DetectionResult {
    case noSwitch
    case switchTo(layout: KeyboardLayout, correctedWord: String)
}
