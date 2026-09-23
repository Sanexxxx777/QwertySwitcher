#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum PrivacyTests {
    static func run() {
        TestRunner.section("Privacy")
        let sanitized = PrivacyService.sanitize("secretWord")
        TestRunner.assertTrue(!sanitized.contains("secretWord"), "diagnostics redact actual word")
        TestRunner.assertTrue(sanitized.contains("10"), "diagnostics retain only useful length")
    }
}


enum ExceptionsTests {
    static func run() {
        TestRunner.section("ExceptionsService")
        let svc = ExceptionsService()
        TestRunner.assertTrue(svc.isValidException("hello"), "hello is valid")
        TestRunner.assertTrue(svc.isValidException("привет"), "привет is valid")
        TestRunner.assertTrue(!svc.isValidException("a"), "single letter invalid")
        TestRunner.assertTrue(!svc.isValidException(String(repeating: "x", count: 30)), "too long invalid")
        TestRunner.assertTrue(!svc.isValidException("key=value"), "= disallowed")
        TestRunner.assertTrue(!svc.isValidException("path/file"), "/ disallowed")
        TestRunner.assertTrue(!svc.isValidException("123"), "digits-only invalid")

        let suite = AppIdentity.bundleIdentifier + ".tests.exceptions." + UUID().uuidString
        guard let isolatedDefaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        isolatedDefaults.set(["legacy.example"], forKey: AppIdentity.keyPrefix + "appExceptions")
        let isolated = ExceptionsService(defaults: isolatedDefaults)
        TestRunner.assertTrue(
            isolated.blocksAutoSwitch(bundleID: "legacy.example"),
            "legacy app exceptions migrate into block-auto profiles"
        )
        isolated.setProfile(
            AppProfile(blockAutoSwitch: false, blockInstantCorrection: true, blockHotkeys: true),
            for: "editor.example"
        )
        TestRunner.assertTrue(
            !isolated.blocksAutoSwitch(bundleID: "editor.example"),
            "profile can allow boundary correction"
        )
        TestRunner.assertTrue(
            isolated.blocksInstantCorrection(bundleID: "editor.example"),
            "profile can independently block instant correction"
        )
        TestRunner.assertTrue(
            isolated.blocksHotkeys(bundleID: "editor.example"),
            "profile can independently block hotkeys"
        )
        isolated.removeProfiles(for: ["editor.example"])
        TestRunner.assertNil(isolated.profile(for: "editor.example"), "profile removal is exact")

        // Plan 006 Step 1: decoded-value caches (write-through + cross-instance invalidation + cap).
        let cacheSuite = AppIdentity.bundleIdentifier + ".tests.exceptions.cache." + UUID().uuidString
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { cacheDefaults.removePersistentDomain(forName: cacheSuite) }
        let cached = ExceptionsService(defaults: cacheDefaults)

        cached.wordExceptions = ["alpha"]
        TestRunner.assertTrue(
            cached.wordExceptions.contains("alpha"), "wordExceptions read-after-write hits the fresh value"
        )
        cached.setProfile(
            AppProfile(blockAutoSwitch: true, blockInstantCorrection: false, blockHotkeys: false),
            for: "cache.example"
        )
        TestRunner.assertTrue(
            cached.profile(for: "cache.example")?.blockAutoSwitch == true,
            "appProfiles read-after-write hits the fresh value"
        )
        cached.learnException(original: "asd", corrected: "фыв")
        TestRunner.assertTrue(cached.isAutoLearned("asd"), "autoLearned read-after-write hits the fresh value")

        let second = ExceptionsService(defaults: cacheDefaults)
        TestRunner.assertTrue(second.wordExceptions.contains("alpha"), "a second instance sees the initial state")
        cached.wordExceptions = ["alpha", "beta"]
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: cacheDefaults)
        // The observer is registered with `queue: .main` (fix, revise round
        // 1): its block is scheduled on the main queue, not run synchronously
        // inline with `post`, even when `post` itself runs on the main
        // thread — it needs one more main-run-loop turn to execute.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        TestRunner.assertTrue(
            second.wordExceptions.contains("beta"),
            "a second instance sees a write from another instance after the change notification fires (next main-thread turn)"
        )

        let capSuite = AppIdentity.bundleIdentifier + ".tests.exceptions.cap." + UUID().uuidString
        guard let capDefaults = UserDefaults(suiteName: capSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { capDefaults.removePersistentDomain(forName: capSuite) }
        let capped = ExceptionsService(defaults: capDefaults)
        for i in 0..<1000 {
            capped.learnException(original: "word\(i)", corrected: "target\(i)")
        }
        TestRunner.assertEqual(capped.autoLearned.count, 1000, "auto-learned store fills to the cap")
        capped.learnException(original: "overflow", corrected: "переполнение")
        TestRunner.assertTrue(!capped.isAutoLearned("overflow"), "the cap refuses a new 1,001st entry")
        TestRunner.assertEqual(capped.autoLearned.count, 1000, "store size stays at the cap after a refused insert")
        capped.learnException(original: "word0", corrected: "новоеслово")
        TestRunner.assertEqual(
            capped.autoLearned["word0"], "новоеслово",
            "an update to an already-learned key still goes through once the store is full"
        )
    }
}


enum TimedPauseTests {
    static func run() {
        TestRunner.section("TimedPauseService")
        let suite = AppIdentity.bundleIdentifier + ".tests.pause." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = PreferencesService(defaults: defaults)
        prefs.isAutoSwitchEnabled = true
        let start = Date(timeIntervalSince1970: 1_000)
        let service = TimedPauseService(
            prefsService: prefs, defaults: defaults, schedulesTimers: false, now: start
        )
        service.pause(for: 900, now: start)
        TestRunner.assertTrue(service.isActive, "timed pause persists a resume deadline")
        TestRunner.assertTrue(!prefs.isAutoSwitchEnabled, "timed pause disables auto-switch")
        TestRunner.assertTrue(
            !service.reconcile(now: Date(timeIntervalSince1970: 1_899)),
            "pause remains active before its deadline"
        )
        TestRunner.assertTrue(
            service.reconcile(now: Date(timeIntervalSince1970: 1_900)),
            "pause resumes exactly at its deadline"
        )
        TestRunner.assertTrue(prefs.isAutoSwitchEnabled, "deadline restores auto-switch")
        TestRunner.assertTrue(!service.isActive, "deadline clears the stored schedule")

        service.pause(for: 900, now: start)
        prefs.isAutoSwitchEnabled = true
        NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)
        TestRunner.assertTrue(
            !service.isActive,
            "a manual toggle cancels the pending automatic resume"
        )

        let viewModelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("UI/Views/MainViewModel.swift")
        let viewModelSource = (try? String(contentsOf: viewModelURL, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            viewModelSource.contains("guard !isSyncingAutoSwitch else { return }"),
            "settings-window synchronization does not echo and cancel a timed pause"
        )
    }
}


enum SettingsBackupTests {
    static func run() {
        TestRunner.section("SettingsBackupService")
        let suite = AppIdentity.bundleIdentifier + ".tests.backup." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = PreferencesService(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let perApp = PerAppLayoutService(inputSourceManager: InputSourceManager(), prefsService: prefs)
        let snippets = SnippetService(defaults: defaults)
        let learnedWords = LearnedWordsStore(defaults: defaults)
        // Mechanism C lives in its own store and is never handed to
        // `SettingsBackupService` at all — bumped here only so the "backup
        // never contains a C word" assertion below is checking something
        // real, not a tautology over an empty store.
        let personalFreq = PersonalFrequencyStore(defaults: defaults)
        let service = SettingsBackupService(
            prefsService: prefs, exceptionsService: exceptions, perAppLayoutService: perApp,
            snippetService: snippets, learnedWordsStore: learnedWords
        )

        prefs.isInstantCorrectionEnabled = false
        prefs.activeLayoutIDs = ["layout.en", "layout.ru"]
        exceptions.wordExceptions = ["qwerty", "привет"]
        exceptions.setProfile(
            AppProfile(blockAutoSwitch: false, blockInstantCorrection: true, blockHotkeys: false),
            for: "app.example"
        )
        perApp.isEnabled = true
        perApp.manualOverrides = ["app.example": "layout.ru"]
        _ = snippets.setSnippet(trigger: "addr", replacement: "Владивосток")
        let learnedT0 = Date(timeIntervalSince1970: 2_000)
        learnedWords.recordManualFix(word: "clear", lang: "en", originApp: "com.app.terminal", at: learnedT0)
        learnedWords.recordManualFix(
            word: "clear", lang: "en", originApp: "com.app.terminal", at: learnedT0.addingTimeInterval(86_400)
        )
        learnedWords.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: learnedT0)
        personalFreq.bump(word: "неразглашаемоеслово", lang: "ru", isDictionaryWord: false, at: learnedT0)

        guard let data = try? service.encodedBackup(now: Date(timeIntervalSince1970: 1_000)) else {
            TestRunner.assertTrue(false, "settings backup encodes")
            return
        }
        let json = String(data: data, encoding: .utf8) ?? ""
        TestRunner.assertTrue(json.contains("\"clear\""), "backup includes an active Mechanism A entry")
        TestRunner.assertTrue(json.contains("\"vmc\""), "backup includes a not-yet-promoted Mechanism A entry too")
        TestRunner.assertTrue(
            !json.contains("неразглашаемоеслово"),
            "backup never contains a Mechanism C (personal frequency) word"
        )
        TestRunner.assertTrue(!json.contains("personalFreq"), "backup has no Mechanism C field at all")

        prefs.isInstantCorrectionEnabled = true
        exceptions.wordExceptions = []
        exceptions.appProfiles = [:]
        perApp.isEnabled = false
        perApp.manualOverrides = [:]
        snippets.snippets = [:]
        learnedWords.removeAll()
        do {
            try service.importBackup(data)
            TestRunner.assertTrue(!prefs.isInstantCorrectionEnabled, "import restores preferences")
            TestRunner.assertTrue(exceptions.wordExceptions.contains("привет"), "import restores word exceptions")
            TestRunner.assertTrue(
                exceptions.blocksInstantCorrection(bundleID: "app.example"),
                "import restores per-feature app profiles"
            )
            TestRunner.assertEqual(
                perApp.manualOverrides["app.example"] ?? "", "layout.ru",
                "import restores manual per-app layout overrides"
            )
            TestRunner.assertEqual(
                snippets.replacement(for: "addr") ?? "", "Владивосток",
                "import restores local text snippets"
            )
            TestRunner.assertTrue(
                learnedWords.isActive(word: "clear", lang: "en"), "import restores an active Mechanism A entry"
            )
            TestRunner.assertEqual(
                learnedWords.allEntries["en:clear"]?.count, 2, "import restores the exact confirmation count"
            )
            TestRunner.assertEqual(
                learnedWords.allEntries["en:clear"]?.originApp, "com.app.terminal", "import restores originApp"
            )
            TestRunner.assertTrue(
                !learnedWords.isActive(word: "vmc", lang: "en"),
                "a not-yet-promoted Mechanism A entry round-trips as still not active"
            )
            TestRunner.assertEqual(
                learnedWords.allEntries["en:vmc"]?.count, 1, "not-yet-promoted entry keeps count 1 through import"
            )
        } catch {
            TestRunner.assertTrue(false, "valid settings backup imports: \(error.localizedDescription)")
        }

        if let valid = try? service.decodeAndValidate(data),
           let badData = try? JSONEncoder().encode(SettingsBackup(
                formatVersion: 99, createdAt: valid.createdAt, preferences: valid.preferences,
                wordExceptions: valid.wordExceptions, appProfiles: valid.appProfiles,
                autoLearned: valid.autoLearned, snippets: valid.snippets,
                perAppLayoutEnabled: valid.perAppLayoutEnabled,
                manualLayoutOverrides: valid.manualLayoutOverrides,
                rememberedLayouts: valid.rememberedLayouts,
                learnedWords: valid.learnedWords
           )) {
            do {
                _ = try service.decodeAndValidate(badData)
                TestRunner.assertTrue(false, "unsupported backup version is rejected")
            } catch SettingsBackupService.BackupError.unsupportedVersion(99) {
                TestRunner.assertTrue(true, "unsupported backup version is rejected")
            } catch {
                TestRunner.assertTrue(false, "unsupported version reports the expected error")
            }
        } else {
            TestRunner.assertTrue(false, "unsupported-version fixture encodes")
        }

        if let valid = try? service.decodeAndValidate(data) {
            let uppercaseEntry = LearnedWordBackupEntry(
                lang: "en", word: "Clear", count: 2, firstConfirmed: 0, lastConfirmed: 1, originApp: nil
            )
            if let badData = try? JSONEncoder().encode(SettingsBackup(
                formatVersion: valid.formatVersion, createdAt: valid.createdAt, preferences: valid.preferences,
                wordExceptions: valid.wordExceptions, appProfiles: valid.appProfiles,
                autoLearned: valid.autoLearned, snippets: valid.snippets,
                perAppLayoutEnabled: valid.perAppLayoutEnabled,
                manualLayoutOverrides: valid.manualLayoutOverrides,
                rememberedLayouts: valid.rememberedLayouts,
                learnedWords: [uppercaseEntry]
            )) {
                do {
                    _ = try service.decodeAndValidate(badData)
                    TestRunner.assertTrue(false, "a non-lowercased learned-word entry is rejected")
                } catch SettingsBackupService.BackupError.invalidData {
                    TestRunner.assertTrue(true, "a non-lowercased learned-word entry is rejected")
                } catch {
                    TestRunner.assertTrue(false, "invalid learned-word entry reports the expected error")
                }
            } else {
                TestRunner.assertTrue(false, "invalid-learned-word fixture encodes")
            }
        } else {
            TestRunner.assertTrue(false, "valid backup fixture decodes for the invalid-learned-word test")
        }
    }
}


enum SnippetTests {
    static func run() {
        TestRunner.section("SnippetService")
        let suite = AppIdentity.bundleIdentifier + ".tests.snippets." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SnippetService(defaults: defaults)

        TestRunner.assertTrue(service.isValidTrigger("addr"), "letter-only trigger is valid")
        TestRunner.assertTrue(!service.isValidTrigger("a"), "one-letter trigger is rejected")
        TestRunner.assertTrue(!service.isValidTrigger("addr 1"), "trigger with whitespace/digits is rejected")
        TestRunner.assertTrue(
            service.setSnippet(trigger: "ADDR", replacement: "line one\nline two"),
            "multiline snippet is stored"
        )
        TestRunner.assertEqual(
            service.replacement(for: "addr") ?? "", "line one\nline two",
            "snippet lookup is case-insensitive"
        )
        service.removeSnippet(trigger: "addr")
        TestRunner.assertNil(service.replacement(for: "addr"), "snippet removal is exact")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        let monitorSource = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            monitorSource.contains("expandSnippet(keystrokes: captured"),
            "word-boundary path checks snippets before language correction"
        )
        TestRunner.assertTrue(
            monitorSource.contains("trailingAlreadyOnScreen: false"),
            "snippet expansion suppresses and retypes the boundary in one transaction"
        )
    }
}


enum SmartCaseTests {
    static func run() {
        TestRunner.section("SmartCaseNormalizer")
        TestRunner.assertEqual(
            SmartCaseNormalizer.normalized("ПРивет", capitalizeSentenceStart: false) ?? "",
            "Привет", "accidentally held Shift is normalized"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("USA", capitalizeSentenceStart: false),
            "all-caps acronym is preserved"
        )
        TestRunner.assertEqual(
            SmartCaseNormalizer.normalized("hello", capitalizeSentenceStart: true) ?? "",
            "Hello", "plain word after sentence punctuation is capitalized"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("iPhone", capitalizeSentenceStart: true),
            "camelCase brand is preserved"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("hello-world", capitalizeSentenceStart: true),
            "non-word token is preserved"
        )

        var tracker = SentenceStartTracker()
        tracker.observeBoundary(".")
        TestRunner.assertTrue(
            !tracker.shouldCapitalizeNextWord,
            "a period alone does not arm capitalization — the gap after it does"
        )
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        TestRunner.assertTrue(
            tracker.shouldCapitalizeNextWord,
            "sentence punctuation keeps capitalization armed across following whitespace"
        )
        TestRunner.assertTrue(tracker.consumeForWord(), "period + Space arms capitalization for one word")
        TestRunner.assertTrue(!tracker.consumeForWord(), "capitalization intent is consumed once")
        tracker.observeBoundary("!")
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        tracker.reset()
        TestRunner.assertTrue(!tracker.consumeForWord(), "context reset clears sentence intent")

        // Field log 21–23.09.2026: four wrong capitalizations out of 22.
        tracker.observeBoundary(".")
        TestRunner.assertTrue(
            !tracker.consumeForWord(),
            "word typed right after the period, no gap (RU '.' instead of 'ю': узна.т, т.е) stays lowercase"
        )
        tracker.observeBoundary(".")
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: true)
        TestRunner.assertTrue(
            !tracker.consumeForWord(),
            "sentence opened by a number keeps the next word lowercase (Готово. 5 минут)"
        )
        tracker.observeBoundary(".")
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        TestRunner.assertTrue(
            !tracker.consumeForWord(leadHasDigit: true),
            "digits glued to the first word keep it lowercase (Готово. 5км)"
        )
        tracker.observeBoundary(".")
        tracker.reset() // KeyboardMonitor: backspace with an empty current word
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        TestRunner.assertTrue(
            !tracker.consumeForWord(),
            "backspaced period no longer capitalizes (спасиб. ⌫ о. → спасибо., готово. ⌫ теперь)"
        )

        // What must keep working.
        for mark in ["?", "!"] {
            tracker.observeBoundary(mark)
            tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
            TestRunner.assertTrue(tracker.consumeForWord(), "'\(mark)' + Space capitalizes the next word")
        }
        tracker.observeBoundary("?")
        tracker.observeEmptyBoundary(isGap: false, leadHasDigit: false) // "?!" / "..."
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        TestRunner.assertTrue(tracker.consumeForWord(), "stacked punctuation then Space still capitalizes")
        tracker.observeBoundary(" ")
        tracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        TestRunner.assertTrue(!tracker.consumeForWord(), "a gap without a sentence end does not capitalize")

        let monitorSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        let source = (try? String(contentsOf: monitorSource, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            source.contains("if !captured.isEmpty { sentenceStartTracker.observeBoundary(trailing) }"),
            "empty whitespace boundaries do not clear sentence capitalization"
        )
        TestRunner.assertTrue(
            source.contains(
                "sentenceStartTracker.observeEmptyBoundary(isGap: proseBoundary, leadHasDigit: leadHasDigit)"
            ),
            "empty boundaries feed the gap/number rule to the sentence tracker"
        )
        TestRunner.assertTrue(
            source.contains("sentenceStartTracker.consumeForWord(leadHasDigit: leadHasDigit)"),
            "digits glued to a word reach the sentence tracker"
        )
        TestRunner.assertTrue(
            source.contains(
                "if buffer.isEmpty, pendingLeadingSymbols.isEmpty || pendingLeadHasDigit {\n"
                    + "                sentenceStartTracker.reset()"
            ),
            "backspace past the current word resets sentence capitalization unless it only ate a leading '.'/'('"
        )
    }
}


enum PreferencesServiceTests {
    static func run() {
        TestRunner.section("PreferencesService — instant correction toggle")
        let key = AppIdentity.keyPrefix + "instantCorrection"
        let previouslySet = UserDefaults.standard.object(forKey: key)
        defer {
            if let previouslySet {
                UserDefaults.standard.set(previouslySet, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        TestRunner.assertTrue(
            PreferencesService().isInstantCorrectionEnabled,
            "instant correction defaults to enabled when never configured"
        )

        let prefs = PreferencesService()
        prefs.isInstantCorrectionEnabled = false
        TestRunner.assertTrue(
            !PreferencesService().isInstantCorrectionEnabled,
            "instant correction can be disabled and persists"
        )
        prefs.isInstantCorrectionEnabled = true
        TestRunner.assertTrue(
            PreferencesService().isInstantCorrectionEnabled,
            "instant correction can be re-enabled"
        )

        // isLayoutSoundEnabled — separate from isSoundEnabled by design (see
        // SoundService: the master sound gate stays isSoundEnabled).
        let soundKey = AppIdentity.keyPrefix + "layoutSoundEnabled"
        let previousSoundSet = UserDefaults.standard.object(forKey: soundKey)
        defer {
            if let previousSoundSet {
                UserDefaults.standard.set(previousSoundSet, forKey: soundKey)
            } else {
                UserDefaults.standard.removeObject(forKey: soundKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: soundKey)
        TestRunner.assertTrue(
            PreferencesService().isLayoutSoundEnabled,
            "layout-switch sound defaults to enabled when never configured"
        )
        prefs.isLayoutSoundEnabled = false
        TestRunner.assertTrue(
            !PreferencesService().isLayoutSoundEnabled,
            "layout-switch sound can be disabled independently and persists"
        )
        TestRunner.assertTrue(
            PreferencesService().isSoundEnabled,
            "disabling the layout-switch sound alone does not touch the master sound gate"
        )

        // layoutSoundName — which system sound plays (see SoundService).
        let layoutSoundKey = AppIdentity.keyPrefix + "layoutSoundName"
        let previousLayoutSound = UserDefaults.standard.object(forKey: layoutSoundKey)
        defer {
            if let previousLayoutSound {
                UserDefaults.standard.set(previousLayoutSound, forKey: layoutSoundKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layoutSoundKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: layoutSoundKey)
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, "Pop",
            "layout sound defaults to 'Pop' when never configured — neutral, not an alert cue"
        )
        prefs.layoutSoundName = "Glass"
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, "Glass",
            "layout sound choice persists across instances (saved/read from prefs)"
        )
        prefs.layoutSoundName = SoundService.noSoundName
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, SoundService.noSoundName,
            "'Без звука' is a storable, readable choice like any other"
        )
    }
}


enum SoundServiceTests {
    static func run() {
        TestRunner.section("SoundService — sound-name resolution (pure, no NSSound touched)")
        TestRunner.assertTrue(
            SoundService.systemSoundNames.contains("Pop"),
            "curated system sound list includes the default 'Pop'"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: "Pop"), "Pop",
            "a known system sound name resolves to itself"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: SoundService.noSoundName), nil,
            "'Без звука' resolves to nil — stays silent, not a fallback sound"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: "TotallyBogusSoundName"), "Pop",
            "an unrecognized/corrupted stored name falls back to Pop — safe fallback, not a crash"
        )

        TestRunner.section("SoundService — gates override the selected sound")
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: false, isLayoutSoundEnabled: true, storedName: "Glass"),
            nil,
            "master sound gate off overrides any selected sound"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: true, isLayoutSoundEnabled: false, storedName: "Glass"),
            nil,
            "layout-sound gate off overrides any selected sound"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: true, isLayoutSoundEnabled: true, storedName: "Glass"),
            "Glass",
            "both gates on — the selected sound plays"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(
                isSoundEnabled: true, isLayoutSoundEnabled: true, storedName: SoundService.noSoundName
            ),
            nil,
            "both gates on but 'Без звука' selected — still stays silent"
        )
    }
}


enum SoundServiceToggleCueTests {
    static func run() {
        TestRunner.section("SoundService.toggleCue — pure resolver for the auto-switch on/off cue")

        guard let onCue = SoundService.toggleCue(enabled: true, isSoundEnabled: true, storedName: "Glass") else {
            TestRunner.assertTrue(false, "ON cue resolves when sound is enabled")
            return
        }
        TestRunner.assertEqual(onCue.name, "Glass", "ON reuses the owner's chosen layout-switch timbre")
        TestRunner.assertEqual(onCue.volume, 1.0, "ON plays at full volume")

        guard let offCue = SoundService.toggleCue(enabled: false, isSoundEnabled: true, storedName: "Glass") else {
            TestRunner.assertTrue(false, "OFF cue resolves when sound is enabled")
            return
        }
        TestRunner.assertEqual(offCue.name, "Glass", "OFF is the SAME timbre as ON, not a different sound")
        TestRunner.assertEqual(offCue.volume, 0.45, "OFF plays quieter than ON — reads as softer, not an alert")

        TestRunner.assertNil(
            SoundService.toggleCue(enabled: true, isSoundEnabled: false, storedName: "Glass"),
            "master sound gate off silences the toggle cue entirely"
        )
        TestRunner.assertNil(
            SoundService.toggleCue(enabled: false, isSoundEnabled: false, storedName: "Glass"),
            "master sound gate off silences OFF too"
        )
        TestRunner.assertNil(
            SoundService.toggleCue(enabled: true, isSoundEnabled: true, storedName: SoundService.noSoundName),
            "'Без звука' selected → toggle stays silent even with sound enabled"
        )

        guard let fallbackCue = SoundService.toggleCue(
            enabled: true, isSoundEnabled: true, storedName: "TotallyBogusSoundName"
        ) else {
            TestRunner.assertTrue(false, "an unrecognized stored name still resolves via the safe fallback")
            return
        }
        TestRunner.assertEqual(fallbackCue.name, "Pop", "corrupted/stale stored name falls back to Pop, not a crash")
    }
}


enum LogRetentionTests {
    static func run() {
        TestRunner.section("DebugLog — logs expire by age, not just by size")
        let now = Date()
        TestRunner.assertTrue(
            DebugLog.isExpired(created: now.addingTimeInterval(-6 * 86_400), now: now, maxAgeDays: 5),
            "a file first written six days ago is past the five-day cap"
        )
        TestRunner.assertTrue(
            !DebugLog.isExpired(created: now.addingTimeInterval(-4 * 86_400), now: now, maxAgeDays: 5),
            "four days old is still within the window"
        )
        TestRunner.assertTrue(
            !DebugLog.isExpired(created: now, now: now, maxAgeDays: 5),
            "a file created just now never expires on the same launch"
        )
    }
}


enum DebugLogTests {
    static func run() {
        TestRunner.section("DebugLog — verbose gate & rotation")

        let verboseKey = AppIdentity.keyPrefix + "verboseLog"
        let previousVerbose = UserDefaults.standard.object(forKey: verboseKey)
        defer {
            if let previousVerbose {
                UserDefaults.standard.set(previousVerbose, forKey: verboseKey)
            } else {
                UserDefaults.standard.removeObject(forKey: verboseKey)
            }
        }

        // (a) level filtering
        let levelDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-level-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: levelDir) }

        UserDefaults.standard.set(false, forKey: verboseKey)
        let levelLog = DebugLog(directory: levelDir)
        levelLog.log("KM", "detect: noSwitch len=5 cur=en", level: .verbose)
        levelLog.log("KM", "significant event", level: .normal)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(
            !levelLog.currentContents.contains("noSwitch"),
            "verbose-level events are dropped while verbose logging is off"
        )
        TestRunner.assertTrue(
            levelLog.currentContents.contains("significant event"),
            "normal-level events are always written regardless of the verbose setting"
        )

        UserDefaults.standard.set(true, forKey: verboseKey)
        levelLog.log("KM", "detect: noSwitch len=6 cur=ru", level: .verbose)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(
            levelLog.currentContents.contains("noSwitch"),
            "verbose-level events are written once verbose logging is turned on"
        )

        // Owner's decision 19.09.2026 (field acceptance): the verbose log is a
        // diagnostic tool for us, and without the per-key trace it cannot
        // answer whether a correction hit a real word or junk. So the trace
        // IS written in verbose mode — the protection is that the file is
        // owner-only (asserted right below) and that the exported report
        // strips these lines (`DiagnosticsExportService` suite).
        levelLog.log("KM", "key kc=44 run=7 buf=6 lead=0", level: .verbose)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(levelLog.currentContents.contains("key kc="),
                              "verbose mode writes the per-key trace — the log's whole diagnostic value")
        UserDefaults.standard.set(false, forKey: verboseKey)
        levelLog.log("KM", "key kc=45 run=8 buf=7 lead=0", level: .verbose)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(!levelLog.currentContents.contains("key kc=45"),
                              "with verbose logging off the per-key trace is dropped like any other verbose event")
        UserDefaults.standard.set(true, forKey: verboseKey)
        let directoryMode = (try? FileManager.default.attributesOfItem(atPath: levelDir.path))?[.posixPermissions] as? Int
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: levelLog.fileURL.path))?[.posixPermissions] as? Int
        TestRunner.assertEqual(directoryMode, 0o700, "diagnostic directory is owner-only")
        TestRunner.assertEqual(fileMode, 0o600, "diagnostic file is owner-only")

        // (b) rotation preserves content instead of truncating it
        let rotateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-rotate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rotateDir) }
        let rotateLog = DebugLog(directory: rotateDir)
        let filler = String(repeating: "x", count: 900)
        for i in 0..<700 {
            rotateLog.log("KM", "filler \(i) \(filler)")
        }
        rotateLog.log("LIC", "MARKER_AFTER_ROTATION")
        rotateLog.waitForPendingWrites()

        let rotatedFileURL = rotateDir.appendingPathComponent("debug.1.log")
        TestRunner.assertTrue(
            FileManager.default.fileExists(atPath: rotatedFileURL.path),
            "exceeding the size limit creates a second debug.1.log file"
        )
        let rotatedContents = (try? String(contentsOf: rotatedFileURL, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            rotatedContents.contains("filler 0 "),
            "rotation preserves earlier content in debug.1.log instead of truncating it to a tail"
        )
        TestRunner.assertTrue(
            rotateLog.currentContents.contains("MARKER_AFTER_ROTATION"),
            "logging continues into a fresh debug.log right after rotation"
        )

        // (c) Plan 006 Step 2: the timestamp is captured at call time, not
        // write time — it must survive even a backed-up queue.
        let gapDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-gap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: gapDir) }
        let gapLog = DebugLog(directory: gapDir)
        // `queue` is private — block it with 200 lines first, so the two
        // timed lines below are still sitting unwritten when their real
        // 50ms gap happens.
        for i in 0..<200 {
            gapLog.log("KM", "queue filler \(i)")
        }
        gapLog.log("GAP", "first")
        Thread.sleep(forTimeInterval: 0.05)
        gapLog.log("GAP", "second")
        gapLog.waitForPendingWrites()

        let gapFormatter = DateFormatter()
        gapFormatter.dateFormat = "HH:mm:ss.SSS"
        gapFormatter.locale = Locale(identifier: "en_US_POSIX")
        let gapLines = gapLog.currentContents.split(separator: "\n").filter { $0.contains("[GAP]") }
        if gapLines.count == 2,
           let firstStamp = gapFormatter.date(from: String(gapLines[0].prefix(12))),
           let secondStamp = gapFormatter.date(from: String(gapLines[1].prefix(12))) {
            let deltaMs = secondStamp.timeIntervalSince(firstStamp) * 1000
            TestRunner.assertTrue(
                deltaMs >= 40,
                "timestamp reflects call time, not write time — a 50ms gap survives a queue backed up by 200 lines (delta=\(deltaMs)ms)"
            )
        } else {
            TestRunner.assertTrue(false, "both GAP lines are written with a parseable HH:mm:ss.SSS timestamp")
        }

        // Revise round 1, defect 2: a deleted log FILE (or its whole
        // DIRECTORY — `PrivacyService.deleteAllLocalData()` removes the
        // entire logs directory) must be recreated on the next write, not
        // lost into an unlinked inode held by the persistent `writeHandle`.
        // SAFETY: confirm each log's path is not under the real
        // ~/Library/Logs/QwertySwitcher before deleting anything — abort
        // this whole test rather than ever touch a real user log.
        let realLogsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/QwertySwitcher", isDirectory: true)

        // (d) deleted FILE
        let deletedFileDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-deleted-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: deletedFileDir) }
        let deletedFileLog = DebugLog(directory: deletedFileDir)
        guard !deletedFileLog.fileURL.path.hasPrefix(realLogsDir.path) else {
            TestRunner.assertTrue(
                false, "SAFETY STOP: deleted-file test's log path resolved under the real logs directory"
            )
            return
        }
        deletedFileLog.log("KM", "before deletion")
        deletedFileLog.waitForPendingWrites()
        try? FileManager.default.removeItem(at: deletedFileLog.fileURL)
        TestRunner.assertTrue(
            !FileManager.default.fileExists(atPath: deletedFileLog.fileURL.path),
            "the log file is actually gone before the recreate-on-write check"
        )
        deletedFileLog.log("KM", "after file deletion")
        deletedFileLog.waitForPendingWrites()
        TestRunner.assertTrue(
            FileManager.default.fileExists(atPath: deletedFileLog.fileURL.path),
            "a deleted log FILE is recreated on the next write"
        )
        TestRunner.assertTrue(
            deletedFileLog.currentContents.contains("after file deletion"),
            "the new line actually lands in the recreated file"
        )
        let recreatedFileMode = (try? FileManager.default.attributesOfItem(
            atPath: deletedFileLog.fileURL.path
        ))?[.posixPermissions] as? Int
        TestRunner.assertEqual(recreatedFileMode, 0o600, "the recreated file keeps mode 0600")

        // (e) deleted DIRECTORY
        let deletedDirDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-deleted-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: deletedDirDir) }
        let deletedDirLog = DebugLog(directory: deletedDirDir)
        guard !deletedDirLog.fileURL.path.hasPrefix(realLogsDir.path) else {
            TestRunner.assertTrue(
                false, "SAFETY STOP: deleted-directory test's log path resolved under the real logs directory"
            )
            return
        }
        deletedDirLog.log("KM", "before directory deletion")
        deletedDirLog.waitForPendingWrites()
        try? FileManager.default.removeItem(at: deletedDirDir)
        TestRunner.assertTrue(
            !FileManager.default.fileExists(atPath: deletedDirDir.path),
            "the whole log directory is actually gone before the recreate-on-write check"
        )
        deletedDirLog.log("KM", "after directory deletion")
        deletedDirLog.waitForPendingWrites()
        TestRunner.assertTrue(
            FileManager.default.fileExists(atPath: deletedDirDir.path),
            "a deleted log DIRECTORY is recreated on the next write"
        )
        let recreatedDirMode = (try? FileManager.default.attributesOfItem(
            atPath: deletedDirDir.path
        ))?[.posixPermissions] as? Int
        TestRunner.assertEqual(recreatedDirMode, 0o700, "the recreated directory keeps mode 0700")
        TestRunner.assertTrue(
            deletedDirLog.currentContents.contains("after directory deletion"),
            "the new line lands in the file inside the recreated directory"
        )
        let recreatedFileInDirMode = (try? FileManager.default.attributesOfItem(
            atPath: deletedDirLog.fileURL.path
        ))?[.posixPermissions] as? Int
        TestRunner.assertEqual(
            recreatedFileInDirMode, 0o600, "the recreated file inside the recreated directory keeps mode 0600"
        )
    }
}


// MARK: - Onboarding state machine
//
// Guards the 04.08.2026 fix: the onboarding window used to vanish behind
// System Settings and there was no honest rule for when a restart is needed.
// The window plumbing is AppKit (live-only), but "which grants are in → what
// do we show" is pure and is pinned here.
enum OnboardingStateTests {
    static func run() {
        TestRunner.section("Onboarding — permission state → step")

        let nothing = OnboardingStatus(hasAccessibility: false, hasInputMonitoring: false,
                                       isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: nothing), .grantAccessibility,
                               "no permissions at all → ask for Accessibility first")

        // Input Monitoring is derived from Accessibility on this system (there
        // is no separate kTCCServiceListenEvent row for our bundle id), so it
        // must never be the first thing we ask for.
        let onlyInputMonitoring = OnboardingStatus(hasAccessibility: false, hasInputMonitoring: true,
                                                   isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: onlyInputMonitoring), .grantAccessibility,
                               "Input Monitoring without Accessibility still asks for Accessibility")

        let onlyAccessibility = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: false,
                                                 isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: onlyAccessibility), .grantInputMonitoring,
                               "Accessibility granted → next step is Input Monitoring")

        let running = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                       isInterceptionRunning: true)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: running), .ready,
                               "both grants + live interception → ready")

        let justGranted = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                           isInterceptionRunning: false, secondsSinceAllGranted: 1)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: justGranted), .verifying,
                               "grants just landed and the tap is still coming up → verifying, not a restart prompt")

        let borderline = OnboardingStatus(
            hasAccessibility: true, hasInputMonitoring: true, isInterceptionRunning: false,
            secondsSinceAllGranted: OnboardingStateMachine.restartGraceSeconds - 0.01
        )
        TestRunner.assertEqual(OnboardingStateMachine.step(for: borderline), .verifying,
                               "just inside the grace window is still verifying")

        let stalled = OnboardingStatus(
            hasAccessibility: true, hasInputMonitoring: true, isInterceptionRunning: false,
            secondsSinceAllGranted: OnboardingStateMachine.restartGraceSeconds
        )
        TestRunner.assertEqual(OnboardingStateMachine.step(for: stalled), .stalled,
                               "grants in place but no interception past the grace window → stalled")

        TestRunner.assertTrue(OnboardingStateMachine.offersRestart(.stalled),
                              "restart is offered in the stalled state")
        TestRunner.assertTrue(!OnboardingStateMachine.offersRestart(.verifying)
                              && !OnboardingStateMachine.offersRestart(.ready)
                              && !OnboardingStateMachine.offersRestart(.grantAccessibility)
                              && !OnboardingStateMachine.offersRestart(.grantInputMonitoring),
                              "restart is never offered anywhere else — permissions are picked up hot")

        TestRunner.assertTrue(!OnboardingStateMachine.canFinish(.grantAccessibility)
                              && !OnboardingStateMachine.canFinish(.grantInputMonitoring),
                              "window can't be confirmed away while a permission is missing")
        TestRunner.assertTrue(OnboardingStateMachine.canFinish(.verifying)
                              && OnboardingStateMachine.canFinish(.stalled)
                              && OnboardingStateMachine.canFinish(.ready),
                              "once both grants are in, the user may confirm — the tap self-heals on its own poll")

        TestRunner.assertEqual(OnboardingStateMachine.pendingPermission(for: nothing), .accessibility,
                               "pending permission with nothing granted is Accessibility")
        TestRunner.assertEqual(OnboardingStateMachine.pendingPermission(for: onlyAccessibility), .inputMonitoring,
                               "pending permission after Accessibility is Input Monitoring")
        TestRunner.assertNil(OnboardingStateMachine.pendingPermission(for: running),
                             "nothing pending when both are granted — no repeat prompts")

        // A missing timestamp must not be read as "waited forever".
        let noTimestamp = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                           isInterceptionRunning: false, secondsSinceAllGranted: nil)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: noTimestamp), .verifying,
                               "unknown wait time counts as 0s, not as stalled")

        TestRunner.assertTrue(!OnboardingStateMachine.hint(for: .grantInputMonitoring).contains("Перезапусти"),
                              "the Input Monitoring hint does not claim a restart is required")
        TestRunner.assertTrue(OnboardingStateMachine.hint(for: .stalled).contains("перезапуск"),
                              "the stalled hint is the only one that mentions restarting")
    }
}
#endif
