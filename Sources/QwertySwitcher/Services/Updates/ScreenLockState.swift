import CoreGraphics
import Foundation

/// Whether the console session's screen is currently locked. While it is,
/// `loginwindow` holds secure event input for the whole session — which the
/// updater's ordinary "no secure input" gate would read as "a password field
/// is focused" and defer an install for hours (field e2e 10.09.2026). A
/// locked screen is the opposite: the one moment nobody can be typing.
///
/// `CGSessionCopyCurrentDictionary` is public CoreGraphics API; the key is
/// the same one `ioreg`/`CGSession` expose. Any failure to read it answers
/// `false` so the conservative gates stay in charge.
enum ScreenLockState {
    static var isLocked: Bool {
        guard let dict = (CGSessionCopyCurrentDictionary() as NSDictionary?) as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let flag = dict["CGSSessionScreenIsLocked"] as? Int { return flag != 0 }
        return false
    }
}
