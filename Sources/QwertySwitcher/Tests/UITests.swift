#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum SwitchBlockReasonTests {
    static func run() {
        TestRunner.section("SwitchBlockReason — resolves the single status-bar/menu/tooltip reason")

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil
            ),
            .none,
            "everything working → no reason, no line in the menu"
        )
        TestRunner.assertNil(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil
            ).title,
            "'.none' has no title — absence of a line, never a reassuring filler"
        )

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, secureInputAppName: "Safari"
            ),
            .secureInput(appName: "Safari"),
            "secure input with a known app name is reported as its own case"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, secureInputAppName: "Safari"
            ).title,
            "Пароль в Safari — переключение приостановлено",
            "known app name is folded into the line"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, secureInputAppName: nil
            ).title,
            "Ввод пароля — переключение приостановлено",
            "unknown app name falls back to the generic wording — never a guessed name"
        )
        TestRunner.assertTrue(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, secureInputAppName: nil
            ).blocksSwitching,
            "secure input blocks switching"
        )

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .missingPermissions, isAutoSwitchEnabled: true, secureInputAppName: nil
            ).title,
            "Нет разрешения Универсального доступа",
            "missing permissions wins over every other check"
        )

        for downHealth: EventTapHealth in [.starting, .unavailable, .stopped] {
            TestRunner.assertEqual(
                SwitchBlockReason.resolve(
                    health: downHealth, isAutoSwitchEnabled: true, secureInputAppName: nil
                ).title,
                "Перехват клавиш остановлен",
                "\(downHealth) health reads as 'interception stopped'"
            )
        }

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: false, secureInputAppName: nil
            ).title,
            "Автопереключение выключено",
            "healthy tap but auto-switch off"
        )

        // Priority: health problems outrank auto-switch even when it's also
        // off — the user should see the more urgent, actionable cause first,
        // not whichever check happens to run last.
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .missingPermissions, isAutoSwitchEnabled: false, secureInputAppName: nil
            ).title,
            "Нет разрешения Универсального доступа",
            "missing permissions outranks auto-switch-off"
        )

        // Per-app profile block (0.7.0's per-app profiles otherwise leave
        // this badge silent while the app itself is effectively disabled).
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, "Terminal")
            ).title,
            "Автопереключение выключено для Terminal",
            "app-profile auto-switch block names the app"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, nil)
            ).title,
            "Автопереключение выключено для этого приложения",
            "unknown app name falls back to generic wording, same as secure input"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                appProfileBlock: (.instantCorrectionOnly, "Ghostty")
            ).title,
            "Мгновенная коррекция выключена для Ghostty",
            "instant-correction-only block is worded as a partial restriction, not a full stop"
        )
        TestRunner.assertNil(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                appProfileBlock: nil
            ).title,
            "no app-profile block passed → still '.none', unchanged from before 0.7.0"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: false, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, "Terminal")
            ).title,
            "Автопереключение выключено",
            "global auto-switch-off outranks an app-profile block — no point naming one app when it's off everywhere"
        )

        // Game Mode (gamemode-spec-20260831.md) — checked LAST, after the
        // per-app profile block.
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                gameDetected: true, gameAppName: "Chess"
            ).title,
            "Игра — коррекция приостановлена",
            "game mode is reported when nothing more global explains the silence"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                gameDetected: true, gameAppName: nil
            ).title,
            "Игра — коррекция приостановлена",
            "game mode title does not depend on a known app name"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, "Terminal"), gameDetected: true, gameAppName: "Terminal"
            ).title,
            "Автопереключение выключено для Terminal",
            "priority: an app-profile block outranks game-mode detection — the deliberate setting explains it first"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: false, secureInputAppName: nil,
                gameDetected: true, gameAppName: "Chess"
            ).title,
            "Автопереключение выключено",
            "priority: global auto-switch-off outranks game-mode detection too"
        )
        TestRunner.assertNil(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, secureInputAppName: nil,
                gameDetected: false
            ).title,
            "no game-mode block passed → still '.none'"
        )
    }
}


enum StatusInkContrastTests {
    static func run() {
        TestRunner.section("StatusInk — measured contrast, both appearances")

        let inks: [(String, NSColor)] = [
            ("green", StatusInk.greenNS), ("amber", StatusInk.amberNS), ("red", StatusInk.redNS)
        ]
        for (appearanceName, appearance, surfaces) in [
            ("light", NSAppearance.Name.aqua, StatusInk.lightSurfaces),
            ("dark", NSAppearance.Name.darkAqua, StatusInk.darkSurfaces)
        ] {
            guard let look = NSAppearance(named: appearance) else {
                TestRunner.skip("appearance \(appearanceName) unavailable")
                continue
            }
            look.performAsCurrentDrawingAppearance {
                for (name, ink) in inks {
                    let ratios = surfaces.compactMap { Contrast.ratio(ink, $0) }
                    guard ratios.count == surfaces.count, let worst = ratios.min() else {
                        TestRunner.assertTrue(false, "\(name)/\(appearanceName): color not convertible to sRGB")
                        continue
                    }
                    TestRunner.assertTrue(
                        worst >= 4.5,
                        "\(name) on \(appearanceName): worst surface \(String(format: "%.2f", worst)):1 ≥ 4.5:1"
                    )
                }
            }
        }

        // Sanity anchors for the formula itself — if these drift, the ratios
        // above are measuring nothing.
        if let blackOnWhite = Contrast.ratio(.black, .white) {
            TestRunner.assertTrue(
                abs(blackOnWhite - 21.0) < 0.01,
                "black on white is 21:1 (got \(String(format: "%.2f", blackOnWhite)))"
            )
        }
        if let same = Contrast.ratio(.white, .white) {
            TestRunner.assertTrue(abs(same - 1.0) < 0.01, "a color against itself is 1:1")
        }
    }
}


enum DockIconPolicyTests {
    static func run() {
        TestRunner.section("DockIconPolicy — reference-counted Dock icon across Settings/Exceptions/About/License/onboarding")

        var policy = DockIconPolicy()
        TestRunner.assertEqual(policy.openWindowCount, 0, "starts with nothing open")

        TestRunner.assertTrue(policy.windowOpened(), "the FIRST window to open should show the Dock icon")
        TestRunner.assertEqual(policy.openWindowCount, 1, "count after first open")

        TestRunner.assertTrue(!policy.windowOpened(), "a second concurrently open window must NOT re-trigger showing the icon")
        TestRunner.assertEqual(policy.openWindowCount, 2, "count after second open")

        TestRunner.assertTrue(!policy.windowClosed(), "closing one of two open windows must NOT hide the icon yet")
        TestRunner.assertEqual(policy.openWindowCount, 1, "one window still open")

        TestRunner.assertTrue(policy.windowClosed(), "closing the LAST open window should hide the Dock icon")
        TestRunner.assertEqual(policy.openWindowCount, 0, "count back to zero")

        TestRunner.assertTrue(!policy.windowClosed(), "closing with nothing open is a safe no-op, not a negative count")
        TestRunner.assertEqual(policy.openWindowCount, 0, "count never goes negative")

        // Re-open after fully closing — must behave exactly like the very
        // first open (regression guard: a stale count from a earlier close
        // 5-window session should never suppress the icon on the next open).
        TestRunner.assertTrue(policy.windowOpened(), "re-opening after a full close shows the icon again")
    }
}


/// Structural guard for the 0.10.0 license removal: `AuthorLinksView.swift`
/// (its replacement) carries all four outbound links + the author's Telegram
/// handle, and `LicenseView.swift` no longer exists at all — same
/// source-read precedent as `ComboWindowGuardTests` (no live window to click
/// through in this headless harness).
enum AuthorLinksViewTests {
    static func run() {
        TestRunner.section("AuthorLinksView — outbound links present, LicenseView gone")

        let viewsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("UI/Views")

        guard let source = try? String(
            contentsOf: viewsDir.appendingPathComponent("AuthorLinksView.swift"), encoding: .utf8
        ) else {
            TestRunner.assertTrue(false, "AuthorLinksView.swift not readable — test needs updating")
            return
        }

        for url in [
            "https://shulgin.is-a.dev/store/prosto/",
            "https://shulgin.is-a.dev/",
            "https://shulgin.is-a.dev/store/",
            "https://t.me/Aleksandr_NFA",
        ] {
            TestRunner.assertTrue(source.contains(url), "AuthorLinksView links to \(url)")
        }
        TestRunner.assertTrue(source.contains("@Aleksandr_NFA"), "AuthorLinksView names the Telegram handle")

        TestRunner.assertTrue(
            !FileManager.default.fileExists(atPath: viewsDir.appendingPathComponent("LicenseView.swift").path),
            "LicenseView.swift no longer exists — replaced by AuthorLinksView in 0.10.0"
        )

        // Plan 010 (honest texts): the word count and engine description in
        // AboutView, and the clipboard/learning-store honesty in
        // PrivacyService.policyText, must not drift from the code again.
        TestRunner.section("AboutView / PrivacyService — claims match the code (Plan 010 guard)")

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .deletingLastPathComponent()      // Sources/
            .deletingLastPathComponent()      // project root

        guard let aboutSource = try? String(
            contentsOf: viewsDir.appendingPathComponent("AboutView.swift"), encoding: .utf8
        ) else {
            TestRunner.assertTrue(false, "AboutView.swift not readable — test needs updating")
            return
        }

        guard let enWords = try? String(
            contentsOf: projectRoot.appendingPathComponent("Resources/Dictionaries/en_US.txt"), encoding: .utf8
        ), let ruWords = try? String(
            contentsOf: projectRoot.appendingPathComponent("Resources/Dictionaries/ru_RU.txt"), encoding: .utf8
        ) else {
            TestRunner.assertTrue(false, "dictionary files not readable — test needs updating")
            return
        }
        let realTotal = enWords.split(separator: "\n").count + ruWords.split(separator: "\n").count

        guard let match = aboutSource.range(of: #"≈([\d\s]+)\s*слов"#, options: .regularExpression) else {
            TestRunner.assertTrue(false, "AboutView does not carry a '≈N слов' claim — test needs updating")
            return
        }
        let digitsOnly = aboutSource[match].filter { $0.isNumber }
        guard let claimedTotal = Int(digitsOnly) else {
            TestRunner.assertTrue(false, "could not parse a number out of AboutView's '≈N слов' claim")
            return
        }
        let deviation = abs(Double(claimedTotal) - Double(realTotal)) / Double(realTotal)
        TestRunner.assertTrue(
            deviation <= 0.01,
            "AboutView's word count (\(claimedTotal)) is within 1% of the real dictionary total (\(realTotal))"
        )

        TestRunner.assertTrue(
            !aboutSource.contains("NSSpellChecker"),
            "AboutView no longer claims NSSpellChecker is part of the engine"
        )

        guard let privacySource = try? String(
            contentsOf: projectRoot.appendingPathComponent("Sources/QwertySwitcher/Services/PrivacyService.swift"),
            encoding: .utf8
        ) else {
            TestRunner.assertTrue(false, "PrivacyService.swift not readable — test needs updating")
            return
        }
        guard let policyRange = privacySource.range(of: "static let policyText"),
              let clipboardRange = privacySource.range(
                  of: "Буфер обмена", range: policyRange.upperBound..<privacySource.endIndex
              ) else {
            TestRunner.assertTrue(false, "PrivacyService.policyText / its clipboard paragraph not found")
            return
        }
        let clipboardParagraph = privacySource[clipboardRange.lowerBound...]
        TestRunner.assertTrue(
            clipboardParagraph.contains("Double Shift"),
            "PrivacyService's clipboard paragraph names Double Shift, not just paste-without-formatting"
        )
        let policyText = privacySource[policyRange.lowerBound...]
        TestRunner.assertTrue(
            policyText.contains("исправляли через Double Shift"),
            "PrivacyService.policyText names the Double-Shift learned-pairs store (LearnedWordsStore)"
        )
        TestRunner.assertTrue(
            policyText.contains("личный частотник"),
            "PrivacyService.policyText names the personal-frequency store (PersonalFrequencyStore)"
        )
    }
}
#endif
