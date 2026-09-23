#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum AutoLearnTrackerTests {
    static func run() {
        TestRunner.section("AutoLearnTracker")
        var tracker = AutoLearnTracker()
        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        for _ in 0..<5 { tracker.registerDeletion() }
        TestRunner.assertTrue(!tracker.isAwaitingRetype, "word-only deletion is not enough when space remains")
        tracker.registerDeletion()
        TestRunner.assertTrue(tracker.isAwaitingRetype, "full corrected transaction deletion awaits retype")
        TestRunner.assertEqual(
            tracker.confirmRetype(word: "руддщ", trailing: " "),
            Optional(LearnedCorrection(original: "руддщ", corrected: "hello")),
            "exact retype confirms learned exception"
        )

        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        for _ in 0..<6 { tracker.registerDeletion() }
        TestRunner.assertNil(
            tracker.confirmRetype(word: "другое", trailing: " "),
            "different retype must not create an exception"
        )

        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        tracker.registerDeletion()
        tracker.registerNonDeletion()
        for _ in 0..<5 { tracker.registerDeletion() }
        TestRunner.assertTrue(!tracker.isAwaitingRetype, "partial deletion plus typing cancels learning")
    }
}


// MARK: - Wave 1 "learning" modules (learning_spec.md) — pure, no AX/live input

enum LearnedWordsStoreTests {
    static func run() {
        TestRunner.section("LearnedWordsStore")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400

        let suite = AppIdentity.bundleIdentifier + ".tests.learnedWords." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)

        // record -> count, not yet active
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: "com.app.one", at: t0),
            .recorded, "first confirmation is just recorded"
        )
        TestRunner.assertEqual(store.allEntries["en:clear"]?.count, 1, "count is 1 after first confirmation")
        TestRunner.assertTrue(!store.isActive(word: "clear", lang: "en"), "single confirmation is not yet active")

        // promote = 2 within the 30-day window
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: "com.app.one", at: t0.addingTimeInterval(5 * day)),
            .promoted, "second confirmation within the window promotes the entry"
        )
        TestRunner.assertTrue(store.isActive(word: "clear", lang: "en"), "promoted entry is active")
        TestRunner.assertTrue(store.activeKeys(lang: "en").contains("clear"), "activeKeys surfaces the bare word")

        // NOT promoted outside the 30-day window -> resets to count 1
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0),
            .recorded, "vmc first confirmation"
        )
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0.addingTimeInterval(31 * day)),
            .recorded, "a confirmation past the 30-day window resets rather than promotes"
        )
        TestRunner.assertTrue(!store.isActive(word: "vmc", lang: "en"), "reset entry is not active")
        TestRunner.assertEqual(store.allEntries["en:vmc"]?.count, 1, "reset entry count is back to 1")

        // unlearn
        store.unlearn(word: "clear", lang: "en")
        TestRunner.assertTrue(!store.isActive(word: "clear", lang: "en"), "unlearn removes activity")
        TestRunner.assertNil(store.allEntries["en:clear"], "unlearn removes the entry entirely")

        // revoke never drops below zero, and a count reaching zero removes the entry.
        // vmc is still count 1 (firstConfirmed = t0+31day) from the reset above — one
        // more confirmation inside its (new) window promotes it to count 2.
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0.addingTimeInterval(32 * day)),
            .promoted, "vmc promoted to count 2"
        )
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertEqual(store.allEntries["en:vmc"]?.count, 1, "revoke decrements by exactly one")
        TestRunner.assertTrue(!store.isActive(word: "vmc", lang: "en"), "count 1 after revoke is not active")
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertNil(store.allEntries["en:vmc"], "revoke down to zero removes the entry")
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertNil(store.allEntries["en:vmc"], "revoke on a missing entry is a safe no-op")

        // disabled mutes both recording and application
        store.recordManualFix(word: "bnb", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "bnb", lang: "en", originApp: nil, at: t0.addingTimeInterval(day))
        TestRunner.assertTrue(store.isActive(word: "bnb", lang: "en"), "bnb promoted before disabling")
        store.isEnabled = false
        TestRunner.assertTrue(!store.isActive(word: "bnb", lang: "en"), "disabled store reports nothing as active")
        store.recordManualFix(word: "ip", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "ip", lang: "en", originApp: nil, at: t0.addingTimeInterval(day))
        TestRunner.assertNil(store.allEntries["en:ip"], "recording while disabled is a no-op")
        store.isEnabled = true
        TestRunner.assertTrue(store.isActive(word: "bnb", lang: "en"), "re-enabling restores prior activity")

        // normalization guard: store expects already-lowercased, non-empty input
        let countBeforeInvalid = store.allEntries.count
        store.recordManualFix(word: "Exit", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "exit", lang: "", originApp: nil, at: t0)
        TestRunner.assertEqual(
            store.allEntries.count, countBeforeInvalid,
            "uppercase input and empty word/lang are silently rejected — caller's job to normalize"
        )

        // eviction: count==1 evicted before count>=2, oldest lastConfirmed first
        let evictionSuite = AppIdentity.bundleIdentifier + ".tests.learnedWordsEviction." + UUID().uuidString
        guard let evictionDefaults = UserDefaults(suiteName: evictionSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { evictionDefaults.removePersistentDomain(forName: evictionSuite) }
        let evictionStore = LearnedWordsStore(defaults: evictionDefaults)

        for i in 0..<299 {
            let base = t0.addingTimeInterval(TimeInterval(i) * day)
            evictionStore.recordManualFix(word: "w\(i)", lang: "en", originApp: nil, at: base)
            evictionStore.recordManualFix(word: "w\(i)", lang: "en", originApp: nil, at: base.addingTimeInterval(60))
        }
        evictionStore.recordManualFix(word: "oldweak", lang: "en", originApp: nil, at: t0.addingTimeInterval(1_000 * day))
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store sits exactly at cap: 299 promoted + 1 weak")

        let overflowOutcome = evictionStore.recordManualFix(
            word: "newweak", lang: "en", originApp: nil, at: t0.addingTimeInterval(2_000 * day)
        )
        TestRunner.assertEqual(overflowOutcome, .capped, "insert past cap reports an eviction")
        TestRunner.assertNil(evictionStore.allEntries["en:oldweak"], "the OLDER count==1 entry is evicted first")
        TestRunner.assertTrue(
            evictionStore.allEntries["en:newweak"] != nil,
            "the just-inserted (newer) weak entry survives while an older weak entry exists"
        )
        TestRunner.assertTrue(
            evictionStore.isActive(word: "w0", lang: "en"), "promoted entries are untouched while any weak entry remains"
        )
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store stays at cap")

        // once no weak entries remain, an overflow evicts the newcomer itself — promoted entries stay protected
        evictionStore.unlearn(word: "newweak", lang: "en")
        let extraBase = t0.addingTimeInterval(3_000 * day)
        evictionStore.recordManualFix(word: "w299", lang: "en", originApp: nil, at: extraBase)
        evictionStore.recordManualFix(word: "w299", lang: "en", originApp: nil, at: extraBase.addingTimeInterval(60))
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store is now 300 promoted entries, zero weak")

        let selfEvictOutcome = evictionStore.recordManualFix(
            word: "loner", lang: "en", originApp: nil, at: t0.addingTimeInterval(4_000 * day)
        )
        TestRunner.assertEqual(selfEvictOutcome, .capped, "overflow against an all-promoted store still reports an eviction")
        TestRunner.assertNil(
            evictionStore.allEntries["en:loner"],
            "with no weak entry to sacrifice, the newcomer itself is evicted — promoted entries are protected"
        )
        TestRunner.assertTrue(evictionStore.isActive(word: "w0", lang: "en"), "no promoted entry is ever evicted by this policy")
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store remains exactly at cap")

        // persistence round-trip
        let persistSuite = AppIdentity.bundleIdentifier + ".tests.learnedWordsPersist." + UUID().uuidString
        guard let persistDefaults = UserDefaults(suiteName: persistSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { persistDefaults.removePersistentDomain(forName: persistSuite) }
        let writer = LearnedWordsStore(defaults: persistDefaults)
        writer.recordManualFix(word: "clear", lang: "en", originApp: "com.app.terminal", at: t0)
        writer.recordManualFix(word: "clear", lang: "en", originApp: "com.app.terminal", at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let reader = LearnedWordsStore(defaults: persistDefaults)
        TestRunner.assertTrue(reader.isActive(word: "clear", lang: "en"), "a promoted entry survives a flush + reload")
        TestRunner.assertEqual(reader.allEntries["en:clear"]?.originApp, "com.app.terminal", "originApp round-trips")
        writer.flush(now: t0) // dirty flag already false — no-op, must not crash
    }
}


enum PersonalFrequencyStoreTests {
    static func run() {
        TestRunner.section("PersonalFrequencyStore")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400

        let suite = AppIdentity.bundleIdentifier + ".tests.personalFreq." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PersonalFrequencyStore(defaults: defaults)

        // length gate is the store's own guard (junk/mixed-script/projection gates are
        // wave-2 caller concerns computed against JunkMeter/LanguageDetector — see the
        // file's doc comment)
        store.bump(word: "ip", lang: "en", isDictionaryWord: false, at: t0)
        TestRunner.assertNil(store.allEntries["en:ip"], "words shorter than 3 letters are never bumped")

        // promotion >= 5
        for i in 0..<4 {
            let outcome = store.bump(
                word: "vmc", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(TimeInterval(i) * day)
            )
            TestRunner.assertEqual(outcome, .bumped, "bump #\(i + 1) is a plain bump, not yet promoted")
        }
        TestRunner.assertTrue(!store.isPromoted(word: "vmc", lang: "en"), "count 4 is not yet promoted")
        let fifthOutcome = store.bump(word: "vmc", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(4 * day))
        TestRunner.assertEqual(fifthOutcome, .promoted, "the 5th bump promotes")
        TestRunner.assertTrue(store.isPromoted(word: "vmc", lang: "en"), "count 5 is promoted")
        TestRunner.assertTrue(store.promotedKeys(lang: "en").contains("vmc"), "promotedKeys surfaces the bare word")

        // promotedNonDictionaryKeys: excludes dictionary-word entries, keeps non-dictionary ones,
        // and never touches promotedKeys/isPromoted (isPromoted backs undoLastCorrection's unlearn)
        TestRunner.assertTrue(
            store.promotedNonDictionaryKeys(lang: "en").contains("vmc"),
            "a promoted non-dictionary word appears in promotedNonDictionaryKeys"
        )
        for i in 0..<5 {
            store.bump(word: "digword", lang: "en", isDictionaryWord: true, at: t0.addingTimeInterval(TimeInterval(i) * day))
        }
        TestRunner.assertTrue(store.isPromoted(word: "digword", lang: "en"), "the dictionary word is promoted too")
        TestRunner.assertTrue(
            store.promotedKeys(lang: "en").contains("digword"), "promotedKeys still includes the dictionary word"
        )
        TestRunner.assertTrue(
            !store.promotedNonDictionaryKeys(lang: "en").contains("digword"),
            "promotedNonDictionaryKeys excludes the dictionary word"
        )
        TestRunner.assertEqual(
            store.promotedKeys(lang: "en"), Set(["vmc", "digword"]),
            "promotedKeys is unchanged by the new method — both entries still present"
        )

        // unlearn
        store.unlearn(word: "vmc", lang: "en")
        TestRunner.assertTrue(!store.isPromoted(word: "vmc", lang: "en"), "unlearn clears promotion")
        TestRunner.assertNil(store.allEntries["en:vmc"], "unlearn removes the entry")

        // disabled mutes both bumping and application
        for i in 0..<5 {
            store.bump(word: "clear", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(TimeInterval(i) * day))
        }
        TestRunner.assertTrue(store.isPromoted(word: "clear", lang: "en"), "clear promoted before disabling")
        store.isEnabled = false
        TestRunner.assertTrue(!store.isPromoted(word: "clear", lang: "en"), "disabled store reports nothing as promoted")
        store.bump(word: "exit", lang: "en", isDictionaryWord: false, at: t0)
        TestRunner.assertNil(store.allEntries["en:exit"], "bumping while disabled is a no-op")
        store.isEnabled = true
        TestRunner.assertTrue(store.isPromoted(word: "clear", lang: "en"), "re-enabling restores prior promotion")

        // count mirrors store size
        TestRunner.assertEqual(store.count, store.allEntries.count, "count mirrors the store size")

        // persistence: count==1 never persisted; dictionary words persist at count>=2, non-dictionary at count>=3
        let persistSuite = AppIdentity.bundleIdentifier + ".tests.personalFreqPersist." + UUID().uuidString
        guard let persistDefaults = UserDefaults(suiteName: persistSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { persistDefaults.removePersistentDomain(forName: persistSuite) }
        let writer = PersonalFrequencyStore(defaults: persistDefaults)

        writer.bump(word: "raz", lang: "ru", isDictionaryWord: true, at: t0)
        writer.flush(now: t0)
        let readerA = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertNil(readerA.allEntries["ru:raz"], "a single confirmation never reaches disk, even for a dictionary word")

        writer.bump(word: "raz", lang: "ru", isDictionaryWord: true, at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let readerB = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertEqual(readerB.allEntries["ru:raz"]?.count, 2, "a dictionary word persists at count 2")

        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0)
        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let readerC = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertNil(readerC.allEntries["ru:zhargon"], "a non-dictionary word at count 2 does not yet reach disk")

        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0.addingTimeInterval(2 * day))
        writer.flush(now: t0.addingTimeInterval(2 * day))
        let readerD = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertEqual(readerD.allEntries["ru:zhargon"]?.count, 3, "a non-dictionary word persists once it reaches count 3")

        // cap
        let capSuite = AppIdentity.bundleIdentifier + ".tests.personalFreqCap." + UUID().uuidString
        guard let capDefaults = UserDefaults(suiteName: capSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { capDefaults.removePersistentDomain(forName: capSuite) }
        let capStore = PersonalFrequencyStore(defaults: capDefaults)
        for i in 0..<1_999 {
            let base = t0.addingTimeInterval(TimeInterval(i) * day)
            capStore.bump(word: "pfw\(i)", lang: "en", isDictionaryWord: false, at: base)
            capStore.bump(word: "pfw\(i)", lang: "en", isDictionaryWord: false, at: base.addingTimeInterval(60))
        }
        capStore.bump(word: "oldweak", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(5_000 * day))
        TestRunner.assertEqual(capStore.count, 2_000, "cap store sits exactly at cap: 1999 non-weak words + 1 weak")

        let capOutcome = capStore.bump(word: "newweak", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(6_000 * day))
        TestRunner.assertEqual(capOutcome, .capped, "insert past cap reports an eviction")
        TestRunner.assertNil(capStore.allEntries["en:oldweak"], "the OLDER count==1 entry is evicted first")
        TestRunner.assertTrue(
            capStore.allEntries["en:newweak"] != nil, "the newer weak entry survives while an older one exists"
        )
        TestRunner.assertEqual(capStore.count, 2_000, "cap store stays at cap")
    }
}


enum CorrectionFeedbackTrackerTests {
    static func run() {
        TestRunner.section("CorrectionFeedbackTracker")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // revert: word == corrected, reverse direction, within 8s
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(5))
            TestRunner.assertEqual(
                verdict,
                .revertOfAutoCorrection(original: "руддщ", corrected: "hello", wasLearned: false),
                "DS reversing a recent auto-correction within 8s is a revert"
            )
        }

        // not-revert: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "other", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(2))
            TestRunner.assertEqual(verdict, .manualFix, "a different word is never classified as a revert")
        }

        // not-revert: same direction (not reversed)
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "ru", targetLang: "en", at: t0.addingTimeInterval(2))
            TestRunner.assertEqual(verdict, .manualFix, "DS in the same direction as the correction is not a revert")
        }

        // not-revert: past the 8s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(9))
            TestRunner.assertEqual(verdict, .manualFix, "DS past the 8s window is not a revert")
        }

        // not-revert: after reset()
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            tracker.reset()
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1))
            TestRunner.assertEqual(verdict, .manualFix, "reset() clears the pending auto-correction")
        }

        // toggle: one-shot slot — DS#2 toggles, DS#3 on the same reverse gesture is a plain manual fix
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let toggle = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(3))
            TestRunner.assertEqual(
                toggle, .toggleOfManualFix(word: "clear", lang: "en"),
                "DS reversing a recent manual conversion within 10s toggles it"
            )
            let thirdPress = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(5))
            TestRunner.assertEqual(thirdPress, .manualFix, "the toggle slot is one-shot — a third DS is a plain manual fix")
        }

        // not-toggle: past the 10s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let verdict = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(11))
            TestRunner.assertEqual(verdict, .manualFix, "DS past the 10s toggle window is a plain manual fix")
        }

        // not-toggle: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let verdict = tracker.classifyDoubleShift(word: "other", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(3))
            TestRunner.assertEqual(verdict, .manualFix, "a different word is never classified as a toggle")
        }

        // revert-of-revert: DS toward the annulled correction, within 15s, lifts the exception
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(10)),
                "DS on the reverted word within 15s lifts the just-created exception"
            )
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(11)),
                "revert-of-revert is one-shot — the slot is consumed after the first match"
            )
        }

        // not-revert-of-revert: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "other", targetLang: "en", at: t0.addingTimeInterval(5)),
                "a different word never lifts the exception"
            )
        }

        // not-revert-of-revert: past the 15s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(16)),
                "past the 15s window, the exception is not lifted"
            )
        }

        // reset() clears every kind of pending state at once
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            tracker.reset()
            TestRunner.assertEqual(
                tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1)),
                .manualFix, "reset clears the pending auto-correction"
            )
            TestRunner.assertEqual(
                tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1)),
                .manualFix, "reset clears the pending manual conversion"
            )
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(1)),
                "reset clears the pending revert"
            )
        }
    }
}


// MARK: - Wave 2: integration (learning_spec.md "Тесты → Волна 2")

/// Write-time normalization primitives `KeyboardMonitor.normalizedLearnableCore`
/// reuses — `core(of:)`'s multi-core rejection and
/// `isReservedForDisambiguation`'s closed-list membership are both plain,
/// stateless statics on `LanguageDetector` and testable directly without any
/// keystroke fixture. The `resynced`/`disabled` branches of
/// `normalizedLearnableCore` itself are KeyboardMonitor-private glue with no
/// independent seam — covered by code review + the KM integration tests
/// below, not re-tested here in isolation.
enum LearningNormalizationTests {
    static func run() {
        TestRunner.section("Wave 2 — write-time normalization primitives")

        TestRunner.assertNil(LanguageDetector.core(of: "model/path"), "two letter runs separated by a symbol → no core (>1 core rejected)")
        TestRunner.assertNil(LanguageDetector.core(of: "--flag=value"), "flag=value → no single core")
        TestRunner.assertEqual(LanguageDetector.core(of: "/model"), "model", "leading symbol stripped, trailing none")
        TestRunner.assertEqual(LanguageDetector.core(of: "clear"), "clear", "pure word is its own core")
        TestRunner.assertNil(LanguageDetector.core(of: "123"), "digits-only has no letter core")

        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("vs", language: "en"), "'vs' (conflictPairs value) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("мы", language: "ru"), "'мы' (conflictPairs key) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("на", language: "ru"), "'на' (twoLetterWords ru) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("of", language: "en"), "'of' (twoLetterWords en + conflictPairs value) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("и", language: "ru"), "'и' (oneLetterWords ru) is reserved")
        TestRunner.assertTrue(!LanguageDetector.isReservedForDisambiguation("clear", language: "en"), "'clear' is NOT in any disambiguation list")
        TestRunner.assertTrue(!LanguageDetector.isReservedForDisambiguation("vs", language: "ru"), "'vs' is only reserved for its OWN language side")
    }
}


/// learning_spec.md "Тесты → Волна 2" #4 — Instant-байпас.
enum InstantLearningBypassTests {
    static func run() {
        TestRunner.section("Wave 2 — InstantCorrectionAnalyzer learned bypass")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the learned-bypass fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        guard let clearStrokes = InstantCorrectionFixtures.keystrokes(for: "сдуфк", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'сдуфк' fixture can type every character")
            return
        }
        func convert(_ strokes: [BufferedKeystroke]) -> (KeyboardLayout) -> String {
            { layout in inputSources.convertKeystrokes(strokes, toLayout: layout) }
        }

        // Empty Set = the ordinary path. Until 0.11.0 junkGate silenced the
        // flagship "сдуфк" case here (its own reading passed the one-table
        // `isClean`), so "clear" could only ever fire through the learned
        // bypass. Since 0.11.0 `isClean` reads the PLAUSIBLE table (bigram in
        // ≥8 dictionary words): "фк" occurs in 6 ru words, the own reading is
        // no longer "clean", the gate stays open and "clear" wins on ordinary
        // scoring with NO learned entry at all — the recall gain the K=8
        // stand measured (4/15 → 11/15 field words fixed instantly).
        let ordinary = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: []
        )
        TestRunner.assertEqual(ordinary.result?.correctedWord, "clear", "0.11.0 (plausible bigrams K=8): 'сдуфк' fires 'clear' on the ordinary scored path, no learned entry needed")
        TestRunner.assertTrue(ordinary.result?.wasLearned == false, "ordinary fire is NOT flagged wasLearned")

        // The learned bypass still stands BEFORE the junk gate and still
        // fires the same word, flagged as learned — the two paths agree.
        let learned = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: ["clear"]
        )
        TestRunner.assertNil(ordinary.silence, "0.11.0: the ordinary path is no longer silenced for 'сдуфк'")
        TestRunner.assertEqual(learned.result?.correctedWord, "clear", "learned bypass fires 'сдуфк' → clear through the ordinary gate")
        TestRunner.assertTrue(learned.result?.wasLearned == true, "fired result is flagged wasLearned")

        // ownIsWord: own reading is a REAL ru dictionary word (wordLevel!=0)
        // — the learned bypass's own-guard blocks it exactly like the
        // ordinary path would, even though the ceiling itself is not
        // applied in this branch.
        guard let ownWordStrokes = InstantCorrectionFixtures.keystrokes(for: "омск", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'омск' fixture can type every character")
            return
        }
        let ownWordEnReading = inputSources.convertKeystrokes(ownWordStrokes, toLayout: enLayout).lowercased()
        let blockedByOwnWord = analyzer.evaluate(
            keystrokes: ownWordStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(ownWordStrokes), learnedActive: [ownWordEnReading]
        )
        TestRunner.assertNil(blockedByOwnWord.result, "own reading is a real ru word ('омск') — learned bypass stays silent even with a matching active entry")

        // Below minLength: never evaluated regardless of learnedActive.
        let short = Array(clearStrokes.prefix(InstantCorrectionAnalyzer.minLength - 1))
        let shortResult = analyzer.evaluate(
            keystrokes: short, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(short), learnedActive: ["cle"]
        )
        TestRunner.assertNil(shortResult.result, "shorter than minLength never fires, even with an exact-matching learnedActive entry")

        // mixedScript candidate: even an EXACT learnedActive match must not
        // fire when the candidate text itself is mixed-script garbage.
        let mixedCandidate = "cleeх" // latin + one cyrillic х
        let mixedResult = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: { layout in layout.id == ruLayout.id ? "фываю" : mixedCandidate },
            learnedActive: [mixedCandidate]
        )
        TestRunner.assertNil(mixedResult.result, "mixed-script candidate never fires even with a matching learnedActive entry")

        // count==1 (not yet promoted) end-to-end through the real store: a
        // single confirmation never reaches `activeKeys`, so the bypass
        // never sees it.
        let suite = AppIdentity.bundleIdentifier + ".tests.instantLearnedCount1." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)
        store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
        let count1Result = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertTrue(count1Result.result?.wasLearned != true, "count==1 (not yet promoted) never reaches the bypass via the real store — a fire here is the ordinary scored path (0.11.0), never the learned one")
    }
}


/// learning_spec.md "Тесты → Волна 2" #5 — Boundary-байпас. Conflict-pair
/// arbitration and junk-override own-guard regressions are covered by the
/// EXISTING `ConflictPairDisambiguationTests`/`JunkOverrideDetectionTests`
/// suites (anti-regression, spec #7) — not duplicated here.
enum BoundaryLearningBypassTests {
    static func run() {
        TestRunner.section("Wave 2 — LanguageDetector.detect learned bypass (boundary)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the boundary learned-bypass fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        // Genuinely out-of-dictionary on BOTH sides, own-reading CLEAN by
        // JunkMeter (so the PRE-EXISTING, unrelated junk-override — which
        // requires the OWN reading to be JUNK — cannot be what fires here;
        // this isolates the wave-2 learned bypass specifically). Unlike the
        // flagship "сдуфк"→clear instant example, "clear" itself is ALREADY
        // a real en dictionary word and would switch at the boundary with an
        // EMPTY provider too, so it can't demonstrate this bypass here.
        let ruBigramsForSearch = dictionary.possibleBigrams(language: "ru")
        var oovWord: String?
        var oovStrokes: [BufferedKeystroke]?
        for candidate in ["florn", "blurf", "wexil", "drupel", "clanth", "brenzo", "twindle", "sparlo"] {
            guard !dictionary.mightContain(candidate, language: "en"),
                  !dictionary.isPrefixOfBundledWord(candidate, language: "en"),
                  let strokes = InstantCorrectionFixtures.keystrokes(for: candidate, reverse: enReverse) else { continue }
            let ownReading = inputSources.convertKeystrokes(strokes, toLayout: ruLayout)
            guard let ownCore = LanguageDetector.core(of: ownReading)?.lowercased(),
                  !LanguageDetector.isMixedScript(ownCore),
                  !dictionary.mightContain(ownCore, language: "ru"),
                  !dictionary.isPrefixOfBundledWord(ownCore, language: "ru"),
                  let ruBigramsForSearch, JunkMeter.isClean(ownCore, language: "ru", possibleBigrams: ruBigramsForSearch)
            else { continue }
            oovWord = candidate
            oovStrokes = strokes
            break
        }
        guard let oovWord, let oovStrokes else {
            TestRunner.skip("no candidate OOV word had a clean, non-dictionary ru own-reading — widen the candidate list")
            return
        }

        // learned OOV word corrects.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? [oovWord] : [] }
            switch detector.detect(keystrokes: oovStrokes, typedLayout: ruLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, "en", "learned OOV '\(oovWord)' switches to en")
                TestRunner.assertEqual(word, oovWord, "learned OOV word corrects to the learned entry")
            case .noSwitch:
                TestRunner.assertTrue(false, "learned OOV word must correct at the boundary once active")
            }
        }

        // 0.11.0 (field 08–10.09.2026: 21 of 38 Double Shifts were 2–3-letter
        // tickers — bsc/okx/xrp/sc/hh — that the learned path could never
        // fire on): an ACTIVE learned entry of length 2 now corrects at the
        // boundary. The write gate (`KeyboardMonitor.learnableCoreDecision`,
        // ShortTokenTests) is what keeps a real short word of the own language
        // from ever being learned; the apply side no longer refuses by length.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? ["xz"] : [] }
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: "xz", reverse: InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)) else {
                TestRunner.assertTrue(false, "'xz' fixture can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: ruLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, "en", "len==2 active learned entry switches to en (0.11.0)")
                TestRunner.assertEqual(word, "xz", "len==2 active learned entry corrects to the learned token")
            case .noSwitch:
                TestRunner.assertTrue(false, "len==2 active learned entry must correct at the boundary (0.11.0 short tokens)")
            }
        }

        // 0.11.0: a vowel-less learned target ("vmc", "bsc", "xrp") is
        // authorized by an EXACT learned match — `learnedHitApplies` checks
        // `!isMixedScript` instead of `JunkMeter.isClean`, because an exact
        // hit on a twice-confirmed pair is stronger evidence than the bigram
        // heuristic that required a vowel. Before 0.11.0 this stayed
        // noSwitch and the flagship "vmc" case was instant-only.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? ["vmc"] : [] }
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: "vmc", reverse: InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)) else {
                TestRunner.assertTrue(false, "'vmc' fixture can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: ruLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, "en", "vowel-less active learned target 'vmc' switches to en (0.11.0)")
                TestRunner.assertEqual(word, "vmc", "vowel-less active learned target corrects to the learned token")
            case .noSwitch:
                TestRunner.assertTrue(false, "vowel-less active learned target 'vmc' must correct at the boundary (0.11.0)")
            }
        }

        // Empty provider (the default) — byte-for-byte unchanged: the SAME
        // OOV run with no learned entry stays noSwitch.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            switch detector.detect(keystrokes: oovStrokes, typedLayout: ruLayout) {
            case .switchTo:
                TestRunner.assertTrue(false, "default (empty) learnedWordsProvider must never correct an OOV word")
            case .noSwitch:
                TestRunner.assertTrue(true, "default empty provider: OOV word stays noSwitch — byte-for-byte unchanged")
            }
        }
    }
}


/// learning_spec.md "Тесты → Волна 2" #6 — B-интеграция, through
/// `KeyboardMonitor`'s real (non-CGEvent) surface: `undoLastCorrection()`
/// and the public `classifyDoubleShiftGesture` entry point HotkeyManager
/// calls. Deliberately avoids `KeyboardMonitorHarness`/synthetic `CGEvent`
/// construction (macOS 27 beta SkyLight deadlock risk, same reason
/// `KeyboardMonitorIntegrationTests` gates on `syntheticKeyboardEventsAreSafe`)
/// — `FakeTextReplacer.replaceCurrentWord` never constructs a `CGEvent`, so
/// seeding `SwitchUndoManager` directly and calling `undoLastCorrection()`/
/// `classifyDoubleShiftGesture()` exercises the real production code with no
/// live-input dependency at all.
enum LearningKeyboardMonitorIntegrationTests {
    private static func makeMonitor(inputSources: InputSourceManager, dictionary: WordDictionary) -> (
        monitor: KeyboardMonitor, replacer: FakeTextReplacer, learnedWords: LearnedWordsStore,
        personalFreq: PersonalFrequencyStore, exceptions: ExceptionsService, switchUndo: SwitchUndoManager,
        feedbackTracker: CorrectionFeedbackTracker
    )? {
        let suite = AppIdentity.bundleIdentifier + ".tests.kmLearning." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.removePersistentDomain(forName: suite) // clean slate, this suite name is fresh anyway
        let prefs = PreferencesService(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let learnedWords = LearnedWordsStore(defaults: defaults)
        let personalFreq = PersonalFrequencyStore(defaults: defaults)
        let feedbackTracker = CorrectionFeedbackTracker()
        let switchUndo = SwitchUndoManager()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let replacer = FakeTextReplacer(inputSources: inputSources)
        let monitor = KeyboardMonitor(
            languageDetector: detector, textReplacer: replacer,
            statsService: StatisticsService(), prefsService: prefs,
            exceptionsService: exceptions, yoficatorService: YoficatorService(),
            switchUndoManager: switchUndo, perAppLayoutService: PerAppLayoutService(inputSourceManager: inputSources, prefsService: prefs),
            instantCorrectionAnalyzer: analyzer,
            secureInputDetector: SecureInputDetector(secureCheck: { false }, axProbe: { false }),
            learnedWordsStore: learnedWords, personalFrequencyStore: personalFreq, feedbackTracker: feedbackTracker
        )
        return (monitor, replacer, learnedWords, personalFreq, exceptions, switchUndo, feedbackTracker)
    }

    static func run() {
        TestRunner.section("Wave 2 — KeyboardMonitor integration (undo-hook + classify dispatch, no live input)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the KeyboardMonitor learning fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        // 6a: undo-hook creates an exception and unlearns from BOTH stores
        // (boundary-откат через undoLastCorrection, "коррекция+пробел+DS"
        // scenario — DS falling through to Cmd+Opt+Z's own handler once the
        // buffer/history are empty is pre-existing routing, unchanged here;
        // this covers ONLY the new exception+unlearn side effect).
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            let t0 = Date()
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0)
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0.addingTimeInterval(1))
            TestRunner.assertTrue(bundle.learnedWords.isActive(word: "clear", lang: "en"), "setup: 'clear' is active before undo")

            bundle.switchUndo.record(
                originalKeycodes: [], originalWord: "сдуфк", correctedWord: "clear",
                trailing: nil, originalLayoutID: ruLayout.id, targetLayoutID: enLayout.id
            )
            _ = bundle.monitor.undoLastCorrection()

            TestRunner.assertTrue(!bundle.learnedWords.isActive(word: "clear", lang: "en"), "undo-hook unlearns the learned entry")
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "undo-hook learns the exception, keyed by the ORIGINAL word")
        }

        // 6b: эвристический revert (instant-case) — `feedbackTracker` is the
        // seam a real instant success callback feeds via
        // `recordAutoCorrection`; `classifyDoubleShiftGesture` (the SAME
        // public entry point HotkeyManager's selection/clipboard/caret paths
        // call) recognizes the reversal and unlearns/excepts exactly like
        // the DS-eligible buffer/history/run paths would.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
            TestRunner.assertTrue(bundle.learnedWords.isActive(word: "clear", lang: "en"), "setup: 'clear' is active")

            bundle.feedbackTracker.recordAutoCorrection(
                original: "сдуфк", corrected: "clear", targetLang: "en", wasLearned: true, at: Date()
            )
            bundle.monitor.classifyDoubleShiftGesture(word: "clear", sourceLang: "en", targetLang: "ru")

            TestRunner.assertTrue(!bundle.learnedWords.isActive(word: "clear", lang: "en"), "heuristic revert unlearns the learned entry")
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "heuristic revert learns the exception")
        }

        // 6c: a non-eligible classify call (positiveRecord: nil, exactly
        // what HotkeyManager's 3 paths always pass) never mutates
        // LearnedWordsStore even on a `.manualFix` verdict.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            let before = bundle.learnedWords.allEntries.count
            bundle.monitor.classifyDoubleShiftGesture(word: "hello", sourceLang: "en", targetLang: "ru")
            TestRunner.assertEqual(
                bundle.learnedWords.allEntries.count, before,
                "classifyDoubleShiftGesture (HotkeyManager's entry point) never records positively — selection/clipboard/caret content stays out of LearnedWordsStore"
            )
        }

        // 6d: revert-of-revert lifts the exception the revert just created.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            bundle.switchUndo.record(
                originalKeycodes: [], originalWord: "сдуфк", correctedWord: "clear",
                trailing: nil, originalLayoutID: ruLayout.id, targetLayoutID: enLayout.id
            )
            _ = bundle.monitor.undoLastCorrection()
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "setup: undo created the exception")

            bundle.monitor.classifyDoubleShiftGesture(word: "сдуфк", sourceLang: "ru", targetLang: "en")
            TestRunner.assertTrue(!bundle.exceptions.isAutoLearned("сдуфк"), "revert-of-revert (DS back toward the corrected direction, ≤15s) lifts the exception")
        }
    }
}


/// learning_spec.md "Verify" #4 — the full replay scenario, driven through
/// public APIs only (store + evaluate + detect), no live input, no
/// KeyboardMonitor: "«сдуфк»+DS ×2 → promoted → evaluate с Set чинит сквозь
/// junkGate → revert → unlearn+исключение → больше не чинит."
enum LearningReplayChainTests {
    static func run() {
        TestRunner.section("Wave 2 — replay chain (Verify #4): record ×2 → fires → revert → stops firing")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the replay-chain fixture")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)
        guard let strokes = InstantCorrectionFixtures.keystrokes(for: "сдуфк", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'сдуфк' fixture can type every character")
            return
        }
        func convert(_ layout: KeyboardLayout) -> String { inputSources.convertKeystrokes(strokes, toLayout: layout) }

        let suite = AppIdentity.bundleIdentifier + ".tests.replayChain." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Not yet fixed — no active entry.
        let before = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertTrue(before.result?.wasLearned != true, "before any DS confirmation the learned bypass cannot fire (0.11.0: the ordinary scored path may — see InstantLearningBypassTests)")

        // Owner confirms via Double Shift twice ("сдуфк"+DS ×2).
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0), .recorded,
            "first DS confirmation is recorded"
        )
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0.addingTimeInterval(1)), .promoted,
            "second DS confirmation promotes the entry"
        )

        // Third time: instant fires THROUGH the junk gate.
        let fired = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertEqual(fired.result?.correctedWord, "clear", "promoted entry fires through the junk gate on the third occurrence")

        // Owner reverts (DS/undo): the real KeyboardMonitor path unlearns
        // from the store AND learns the exception — replicated here at the
        // store/service level per the spec's "публичные API" scope.
        store.unlearn(word: "clear", lang: "en")
        exceptions.learnException(original: "сдуфк", corrected: "clear")

        // Fourth time: no longer fires — the active set is empty again.
        let after = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertTrue(after.result?.wasLearned != true, "after revert the learned bypass is gone; at the analyzer level the ordinary scored path may still fire (0.11.0) — the KeyboardMonitor exception check asserted next is what blocks the fourth occurrence")
        TestRunner.assertTrue(exceptions.isAutoLearned("сдуфк"), "the exception is in place for the KeyboardMonitor-level exception check too")
    }
}
#endif
