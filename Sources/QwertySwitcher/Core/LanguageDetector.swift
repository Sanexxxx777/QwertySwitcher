import Foundation
import AppKit

final class LanguageDetector {
    private let dictionary: WordDictionary
    let inputSourceManager: InputSourceManager
    private let prefsService: PreferencesService
    private let ngramAnalyzer = NGramAnalyzer()
    private let wordFrequency = WordFrequency()

    private var previousWordLanguage: String?
    /// Was 15 — LARGER than the `collisionGap` below, which meant the language
    /// of the previous word alone could manufacture a "clear winner" out of a
    /// tie. Harmless while words were letters-only; once punctuation joined the
    /// run it became an English-corrupting bug: "key." renders as the real
    /// Russian word "луню", scoring 88 against English's 91 — a 3-point gap the
    /// collision gate holds — until +15 of context bias pushes it to 103 and
    /// the gate opens. Context is a hint, so it must never on its own clear the
    /// bar that exists to demand a decisive win.
    private let contextBias = 5
    private let collisionGap = 10
    /// Margin required to overrule text that is already a valid word in the
    /// user's current layout. Deliberately far above `collisionGap`: the two
    /// outcomes are not equally bad.
    private let incumbentGap = 25

    /// Bundle id of the frontmost app, kept current by subscribing to
    /// `NSWorkspace.didActivateApplicationNotification` (event-driven, off
    /// the CGEventTap callback) rather than querying `NSWorkspace` inside
    /// `detect()` itself — `detect()` runs synchronously in the callback and
    /// AppKit calls there are exactly what the hot-path ban exists for (before
    /// 0.7.0, `canAutoCorrect` did a synchronous frontmost-app read on every
    /// word boundary via `ExceptionsService.isCurrentAppExcepted` — this
    /// cache is what replaced it there; that method now only runs from
    /// `StatusBarController`'s non-hot-path status refresh). Seeded once at
    /// init (a one-time, non-hot-path read) so the very first word
    /// of a session — before any activation notification has fired — is
    /// still covered.
    private var currentAppBundleID: String?

    /// Terminals/editors where `ax=none` (see CLAUDE.md) makes correction
    /// mistakes unrecoverable and the AX-based repair paths unavailable.
    /// Junk-override ONLY — it does not touch the rest of `detect()`,
    /// which already tolerates these apps via the ordinary dictionary path.
    private static let junkOverrideTerminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "net.kovidgoyal.kitty",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "org.alacritty", "co.zeit.hyper", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    private static let skipPatterns: [NSRegularExpression] = {
        let patterns = [
            #"^\d+$"#,                          // numbers
            #"^0x[0-9a-fA-F]+$"#,               // hex
            #"^[a-zA-Z_]\w*[A-Z]\w*$"#,         // camelCase
            #"^[a-zA-Z_]+_[a-zA-Z_]+$"#,        // snake_case
            #"^https?://"#,                      // URLs
            #"^[\w.]+@[\w.]+"#,                  // emails
            #"^[/~][\w/.]+"#,                    // unix paths
            #"^\.[a-z]+"#,                       // extensions
            #"^[A-Z]{2,}$"#,                     // ACRONYMS
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Same detection `InputSourceManager.isTestBinary` uses to keep TIS
    /// layout switching from touching the real system during `--test` runs.
    /// Reused here for the same reason: the real frontmost app when the test
    /// binary launches is ambient, uncontrolled state (it's often a terminal
    /// — which would silently blocklist every junk-override fixture) and
    /// must never leak into a deterministic test run.
    private static var isTestBinary: Bool {
        CommandLine.arguments.contains("--test")
    }

    init(dictionary: WordDictionary, inputSourceManager: InputSourceManager,
         prefsService: PreferencesService) {
        self.dictionary = dictionary
        self.inputSourceManager = inputSourceManager
        self.prefsService = prefsService
        self.currentAppBundleID = Self.isTestBinary
            ? nil
            : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivatedForJunkOverrideGate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appActivatedForJunkOverrideGate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        currentAppBundleID = app.bundleIdentifier
    }

    var activeLayouts: [KeyboardLayout] {
        inputSourceManager.resolvedActiveLayouts(preferredIDs: prefsService.activeLayoutIDs)
    }

    func detect(keycodes: [UInt16]) -> DetectionResult {
        detect(keystrokes: keycodes.map { BufferedKeystroke(keycode: $0, flags: []) })
    }

    /// - Parameter typedLayout: the layout `keystrokes` were ACTUALLY typed
    ///   on, when known. Callers reusing raw keycodes captured earlier
    ///   (Double Shift's buffer/history fallback) must pass it explicitly —
    ///   the active layout can drift between typing a word and acting on it
    ///   later (manual switch, another correction), and defaulting to
    ///   "whatever is active now" silently scrambles the swap direction (see
    ///   CLAUDE.md "марже" bug). Omitted only by the live-typing callers
    ///   (`processCurrentWord`/`tryInstantCorrection`), where the word is
    ///   still being typed and the active layout IS the typed layout.
    func detect(keystrokes: [BufferedKeystroke], typedLayout: KeyboardLayout? = nil) -> DetectionResult {
        guard let currentLayout = typedLayout ?? inputSourceManager.currentLayout else { return .noSwitch }
        let layouts = activeLayouts
        guard layouts.count >= 2 else { return .noSwitch }
        guard layouts.contains(where: { $0.id == currentLayout.id }) else { return .noSwitch }

        let currentText = inputSourceManager.convertKeystrokes(keystrokes, toLayout: currentLayout)
        if Self.shouldSkip(currentText) { return .noSwitch }

        // Snapshot BEFORE the loop below overwrites `previousWordLanguage`
        // with this word's own winner (line ~126) — the native-context and
        // one-letter gates further down need the context as it stood WHEN
        // this word was typed, not the outcome being decided right now.
        let contextLanguageBeforeThisWord = previousWordLanguage

        // Junk-override's "own" side: the literal on-screen reading in the
        // CURRENTLY TYPED layout, letter-core only. Computed once, unlike
        // the per-target-layout `projections()` scan below, because it does
        // not depend on which OTHER layout ends up as the override target
        // (points A and C below both need the same value).
        let ownCoreForOverride: String? = {
            guard let core = Self.core(of: currentText) else { return nil }
            return Self.isMixedScript(core) ? nil : core
        }()

        var candidates: [(layout: KeyboardLayout, word: String, score: Int, inDictionary: Bool, core: String)] = []

        for layout in layouts {
            // A run can hold keys that are punctuation in one alphabet and
            // letters in the other (`;`=ж, `,`=б, `.`=ю, `[`=х, `]`=ъ, `'`=э).
            // Score only the LETTER CORE, but replace the whole run — and try
            // both readings of a trailing ambiguous key, because "ghbdtn." is
            // "привет" + "." and NOT the non-word "приветю".
            let readings = projections(keystrokes, to: layout, asTyped: currentText)
            guard let best = readings.max(by: { scoreWord($0.core, language: layout.languageCode)
                                                 < scoreWord($1.core, language: layout.languageCode) })
            else { continue }
            let word = best.replacement
            let core = best.core
            guard !word.isEmpty, !core.isEmpty else { continue }
            if Self.isMixedScript(core) { continue }

            let dictionaryScore = scoreWord(core, language: layout.languageCode)
            let inDictionary = dictionaryScore > 0
            var score = dictionaryScore

            // N-gram bonus/penalty — on the core, not the run: a trailing "."
            // or "," is not evidence about which alphabet the WORD is in.
            let ngramScore = ngramAnalyzer.score(core, language: layout.languageCode)
            score += ngramScore

            // Word frequency bonus
            score += wordFrequency.bonus(core, language: layout.languageCode)

            // Context bias
            if score > 0, layout.languageCode == previousWordLanguage {
                score += contextBias
            }

            // Current layout tie-breaker
            if score > 0, layout.id == currentLayout.id {
                score += 5
            }

            if score > 0 {
                candidates.append((layout, word, score, inDictionary, core))
            }
        }

        guard !candidates.isEmpty else {
            previousWordLanguage = currentLayout.languageCode

            // Junk-override, point A: neither reading scored a single point,
            // but the screen may plainly be gibberish in the CURRENT layout
            // ("русский коряво написан ⇒ пишу на английском" — owner's TODO,
            // 16.08.2026). On success `previousWordLanguage` is the TARGET
            // language, not `currentLayout`'s (overwriting the assignment
            // above), mirroring the ordinary switchTo path below.
            if let ownCore = ownCoreForOverride,
               let otherLayout = layouts.first(where: { $0.languageCode != currentLayout.languageCode }),
               !isJunkOverrideBlockedByTerminal() {
                let otherLang = otherLayout.languageCode
                // Two readings of the SAME run: the whole conversion, and —
                // when the run ends in a key that reads as punctuation here —
                // the head only, keeping the trailing punctuation exactly as
                // typed ("src." must stay "src." + ".", never become "ю").
                // Both are tried; the trailing-peeled one is preferred so a
                // user's own punctuation is never swallowed into the word.
                let targetReadings = projections(keystrokes, to: otherLayout, asTyped: currentText)
                    .filter { !Self.isMixedScript($0.core) }
                let ordered = targetReadings.count > 1
                    ? [targetReadings[1], targetReadings[0]]
                    : targetReadings
                for reading in ordered {
                    guard junkOverrideFires(
                        ownCore: ownCore, ownLang: currentLayout.languageCode,
                        targetCore: reading.core, targetLang: otherLang,
                        context: contextLanguageBeforeThisWord
                    ) else { continue }
                    previousWordLanguage = otherLang
                    DebugLog.shared.log(
                        "KM",
                        "detect: junk-override \(currentLayout.languageCode)\(ownCore.count)"
                            + "→\(otherLang)\(reading.core.count)"
                    )
                    return .switchTo(layout: otherLayout, correctedWord: reading.replacement)
                }
            }
            return .noSwitch
        }

        candidates.sort { $0.score > $1.score }
        let best = candidates[0]
        previousWordLanguage = best.layout.languageCode

        if best.layout.id == currentLayout.id { return .noSwitch }

        // Rewriting text the user already typed correctly is the one failure
        // this feature must not have ("промахи нам не надо" — 05.08.2026, a
        // correct 9-letter Russian word was flipped to latin on a trailing
        // period; log 08:24:05 "correction: ru→en len=9 trig=."). The hole:
        // `scoreWord` returns 80-100 for a dictionary hit and 0 for a miss, so
        // a correctly-typed word that simply isn't in our 714K list scores 0
        // and never becomes a candidate at all — leaving the other layout's
        // gibberish as the SOLE candidate, where the collision gate below
        // (which needs two) can't touch it, and a handful of n-gram points
        // wins unopposed. So: the winner must be a real word of the target
        // language. Cost is a missed correction (recoverable — Double Shift),
        // never corrupted text (not recoverable without noticing it first).
        guard best.inDictionary else {
            // Junk-override, point C: exactly the guard the words-only rule
            // used to be. `best` already won on score against `own`, it is
            // just not a dictionary word — the junk-override gate is the
            // only thing that can still authorize it.
            if let ownCore = ownCoreForOverride, !isJunkOverrideBlockedByTerminal() {
                let otherLang = best.layout.languageCode
                if junkOverrideFires(
                    ownCore: ownCore, ownLang: currentLayout.languageCode,
                    targetCore: best.core, targetLang: otherLang,
                    context: contextLanguageBeforeThisWord
                ) {
                    previousWordLanguage = otherLang
                    DebugLog.shared.log(
                        "KM", "detect: junk-override \(currentLayout.languageCode)\(ownCore.count)→\(otherLang)\(best.core.count)"
                    )
                    return .switchTo(layout: best.layout, correctedWord: best.word)
                }
                // `best.core` was `readings.max`'s pick at a ZERO score —
                // ties there resolve to whichever projection came first, not
                // necessarily the one that best fits the target gate. Try
                // the other projection of the same run under the same rule
                // before giving up.
                if let alt = projections(keystrokes, to: best.layout, asTyped: currentText)
                    .first(where: { $0.core != best.core && !Self.isMixedScript($0.core) }),
                   junkOverrideFires(
                       ownCore: ownCore, ownLang: currentLayout.languageCode,
                       targetCore: alt.core, targetLang: otherLang,
                       context: contextLanguageBeforeThisWord
                   ) {
                    previousWordLanguage = otherLang
                    DebugLog.shared.log(
                        "KM", "detect: junk-override \(currentLayout.languageCode)\(ownCore.count)→\(otherLang)\(alt.core.count)"
                    )
                    return .switchTo(layout: best.layout, correctedWord: alt.replacement)
                }
            }
            return .noSwitch
        }

        // Conflict-pair disambiguation: a two-letter Russian dictionary word
        // ("мы"/"ли"/"во") and a live English token the owner types daily
        // ("vs"/"kb"/"dj") are two readings of the SAME physically-typed
        // keys — see `conflictPairs`. `best` can only be "ru" here (the
        // same-layout early return above already excluded
        // `best.layout.id == currentLayout.id`), so `currentLayout` is EN
        // and `currentText`'s core is exactly what the owner physically
        // typed, read as English.
        if best.layout.languageCode == "ru",
           let enToken = Self.conflictPairs[best.core.lowercased()],
           Self.core(of: currentText)?.lowercased() == enToken {
            switch contextLanguageBeforeThisWord {
            case "en":
                // Owner is mid-sentence in English — "vs" lives, untouched.
                return .noSwitch
            case "ru":
                // Owner is mid-sentence in Russian — fall through, «мы»
                // gets fixed like any other correction.
                break
            default:
                // Start of input, no context to lean on. An AX probe of the
                // text before the caret (`AXTextSelectionService.valueAndCaret`
                // + `CaretWordExtractor`) could settle this the way it does
                // elsewhere, but this call is synchronous, inside the
                // CGEventTap callback (`processCurrentWord` ← `handleEvent`
                // ← `eventTapCallback` — the tap already logs WARNINGs for
                // slow callbacks, and AX messaging can stall ~0.15s, see
                // TextReplacer's own comment on the same API). The one place
                // an AX round-trip already happens off that thread
                // (`TextReplacer.replaceCurrentWord`, on
                // `replacementQueue.async`) runs AFTER this decision is
                // final — for `.noSwitch` that path is never even reached —
                // so reusing it would mean building a new defer-the-decision
                // mechanism, not reusing an existing one. Falling back to
                // capitalization instead: Shift held on the FIRST keystroke
                // ("Vs") reads as a sentence-opening «Мы»; lowercase is left
                // alone (Double Shift still fixes it manually).
                guard keystrokes.first?.flags.contains(.maskShift) == true else { return .noSwitch }
            }
        }

        // The SAME conflict pair, read from the other end. Above, the owner
        // typed on EN and the Russian reading won; here they typed on RU and
        // the English reading wins — «ща» (a real word, and how the owner
        // actually opens a message) against "of" (a real word too, and one
        // that outscores «ща» by ~30 points on frequency alone, past both
        // gaps). The block above can never catch this direction: it keys off
        // `best.core`, which is the ENGLISH side here, while `conflictPairs`
        // is keyed by the Russian word. Same three-way resolution as above,
        // mirrored: an established EN context means the owner is writing
        // English and simply left the layout on RU (convert), no context at
        // all means what is on screen is the safer bet (leave it — Double
        // Shift still converts on demand). An established RU context needs
        // no case here at all: the native-context lock immediately below
        // already returns `.noSwitch` for any dictionary word of the current
        // layout under its own context.
        if let ownCore = ownCoreForOverride,
           let enToken = Self.conflictPairs[ownCore.lowercased()],
           best.core.lowercased() == enToken,
           contextLanguageBeforeThisWord == nil {
            return .noSwitch
        }

        // Native-context incumbent lock. A dictionary-valid word of the
        // CURRENT layout's language, typed while that same language is
        // already the established context, is never worth overwriting — no
        // score gap buys it back. Without this, frequency+bigram bonuses on
        // the other side can outrun `incumbentGap`(25) outright: "руку"
        // (ru dictionary word) loses to "here" on points alone, "рук"→"her",
        // "беру"→"the", "берут"→"then". Deliberately independent of the gap
        // below — the invariant is a native-language dictionary word is
        // never perturbed by anything, because a missed correction is cheap
        // and corrupting a word the user just typed in their own
        // already-established language is not. Neutral/opposite context
        // (context nil or the other language) is unaffected — that's the
        // "blind typing" case the gap-based gate below still has to cover.
        if let incumbent = candidates.first(where: { $0.layout.id == currentLayout.id }),
           incumbent.inDictionary,
           incumbent.layout.languageCode == contextLanguageBeforeThisWord {
            return .noSwitch
        }

        // One-letter winners are the weakest possible evidence (`scoreWord`
        // scores them 70 against 80-100 for a real word) and, unlike longer
        // runs, the OWN reading of a single letter almost never scores at
        // all — there is no incumbent and no gap to hold the line. All 7
        // false switches the corpus sweep found (d/c/e/b/f/j/r, 15.08.2026)
        // happened with the OPPOSITE language already established as
        // context — an English word typed live right after another English
        // word, one stray letter away from a Cyrillic one-letter reading —
        // so that's exactly what this blocks: an EXPLICIT opposite-language
        // context. Neutral context (nil, previousWordLanguage never set —
        // e.g. the very first word of a session) is deliberately left
        // alone: that's field feature 0.6.8's actual scenario ("b"+space ->
        // "и", regression test at KeyboardMonitorIntegrationTests "Auto-
        // correction reaches one-letter words"), and narrowing it further
        // than the corpus evidence demands would break a shipped feature
        // for no measured gain.
        if best.core.count == 1,
           let context = contextLanguageBeforeThisWord,
           context != best.layout.languageCode {
            return .noSwitch
        }

        // Collision: need clear winner
        if candidates.count >= 2 && (candidates[0].score - candidates[1].score) < collisionGap {
            return .noSwitch
        }

        // Asymmetric burden of proof. If what the user typed ALREADY reads as a
        // real word in the language of their current layout, they were almost
        // certainly typing that word — and overwriting it is the expensive
        // mistake, while skipping is the cheap one (Double Shift recovers it).
        // Without this, English words whose latin keys spell a valid Russian
        // word lose on a few n-gram points: "key." → "луню", "bye." → "иную",
        // "next." → "тучею" (58 such collisions counted in the bundled
        // dictionaries). A plain gap can't separate them — both sides are
        // genuine dictionary hits — so the incumbent gets a wide moat instead.
        if let incumbent = candidates.first(where: { $0.layout.id == currentLayout.id }),
           incumbent.inDictionary,
           best.score - incumbent.score < incumbentGap {
            return .noSwitch
        }

        return .switchTo(layout: best.layout, correctedWord: best.word)
    }

    func lastConvertedWord(keycodes: [UInt16]) -> String? {
        lastConvertedWord(keystrokes: keycodes.map { BufferedKeystroke(keycode: $0, flags: []) })
    }

    func lastConvertedWord(keystrokes: [BufferedKeystroke]) -> String? {
        guard let current = inputSourceManager.currentLayout else { return nil }
        return inputSourceManager.convertKeystrokes(keystrokes, toLayout: current)
    }

    func currentRussianLayout() -> KeyboardLayout? {
        inputSourceManager.currentLayout?.isRussian == true ? inputSourceManager.currentLayout : nil
    }

    /// Resolves what Double Shift's buffer/history swap should do with
    /// `keystrokes` typed on `typedLayout`: prefers the scored `detect()`
    /// result (same calibration as every other correction), but falls back
    /// to a FORCED swap to "the other" active layout when the scorer sees no
    /// reason to switch away from the current interpretation (`.noSwitch`) —
    /// typically because it's already a good word. That forced fallback is
    /// what makes a SECOND, immediate Double Shift on a word the first press
    /// just converted toggle it back predictably, instead of falling through
    /// to the caret-word/Undo paths (see CLAUDE.md Double Shift toggle bug).
    /// Returns nil when there's nothing sensible to do: fewer than 2 active
    /// layouts, `typedLayout` isn't one of them, or the forced fallback
    /// produces empty text.
    func swapTarget(
        keystrokes: [BufferedKeystroke], typedLayout: KeyboardLayout
    ) -> (layout: KeyboardLayout, word: String)? {
        let layouts = activeLayouts
        guard layouts.count >= 2, layouts.contains(where: { $0.id == typedLayout.id }) else { return nil }

        switch detect(keystrokes: keystrokes, typedLayout: typedLayout) {
        case .switchTo(let layout, let word):
            return (layout, word)
        case .noSwitch:
            guard let other = layouts.first(where: { $0.id != typedLayout.id }) else { return nil }
            let word = inputSourceManager.convertKeystrokes(keystrokes, toLayout: other)
            guard !word.isEmpty else { return nil }
            return (other, word)
        }
    }

    func resetContext() { previousWordLanguage = nil }

    // MARK: - Multi-level scoring (Dictionary + SpellCheck + N-grams + Frequency)

    /// One reading of a run under a candidate layout: which part is the word
    /// (`core`, the only thing worth scoring) and what the whole run becomes on
    /// screen if this layout wins (`replacement`).
    private struct Projection {
        let core: String
        let replacement: String
    }

    /// Splits a rendered run into `[leading non-letters][core][trailing non-letters]`.
    /// Returns nil when the letters are INTERRUPTED by a non-letter — two cores
    /// mean this is not one word ("model/path", "a;b", "--flag=value"), and
    /// that single rule is what keeps shell commands safe.
    private static func core(of rendered: String) -> String? {
        let core = rendered.drop(while: { !$0.isLetter })
            .prefix(while: { $0.isLetter })
        guard !core.isEmpty else { return nil }
        let rest = rendered.drop(while: { !$0.isLetter }).dropFirst(core.count)
        guard !rest.contains(where: { $0.isLetter }) else { return nil }
        return String(core)
    }

    /// Up to two readings per layout. The second exists because an ambiguous
    /// trailing key is genuinely ambiguous: typing "ghbdtn." means "привет."
    /// (a word plus a full stop), not the non-word "приветю" — but typing
    /// "nfr;t" means "также", where the very same class of key IS a letter.
    /// Only the dictionary can tell them apart, so we score both and keep the
    /// better one.
    private func projections(
        _ keystrokes: [BufferedKeystroke],
        to layout: KeyboardLayout,
        // Rendered ONCE by the caller and passed in: it doesn't depend on the
        // candidate layout, and every `convertKeystrokes` is a `UCKeyTranslate`
        // per character. This runs on each word boundary, so the difference
        // between 5 and 3 renders per word is free to take.
        asTyped: String
    ) -> [Projection] {
        var result: [Projection] = []

        let whole = inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        if let core = Self.core(of: whole) {
            result.append(Projection(core: core, replacement: whole))
        }

        // Trailing keys that the user SAW as punctuation while typing: peel them
        // off, convert only the head, and leave them exactly as typed.
        let trailingPunct = asTyped.reversed().prefix(while: { !$0.isLetter }).count
        if trailingPunct > 0, trailingPunct < keystrokes.count {
            let head = Array(keystrokes.dropLast(trailingPunct))
            let tail = String(asTyped.suffix(trailingPunct))
            let headRendered = inputSourceManager.convertKeystrokes(head, toLayout: layout)
            if let core = Self.core(of: headRendered) {
                result.append(Projection(core: core, replacement: headRendered + tail))
            }
        }

        return result
    }

    /// The complete set of one-letter words, spelled out rather than looked up.
    /// The Bloom filter cannot be trusted at this length: with ~0.5% false
    /// positives and an alphabet of only 59 candidates, "б", "ж" and "ъ" would
    /// eventually pass as words and start rewriting text. The real list is
    /// short, closed and unambiguous, so it belongs in the code.
    private static let oneLetterWords: [String: Set<Character>] = [
        "ru": ["а", "и", "в", "к", "о", "с", "у", "я"],
        "en": ["a", "i"]
    ]

    /// Same rationale as `oneLetterWords`, one letter longer. At length 2 the
    /// bundled dictionaries are almost entirely garbage (650 of ~1024 possible
    /// en_US pairs and 774 of ~1024 possible ru_RU pairs are listed "words"),
    /// so the Bloom filter would pass nearly every two-letter run — including
    /// the reversed-layout typo itself ("yf" for «на»/yt for «не») — as a
    /// dictionary hit and let `incumbentGap` protect the garbage instead of
    /// the real word. Membership here must be a closed, hand-picked list, and
    /// it must be symmetric between languages: a one-sided list would let a
    /// real word of one language score in the OTHER language too (e.g. if
    /// "ok" were absent from `en` while its ru-layout reading "щл" stayed
    /// unlisted, that's fine — but if "ok" were present without a matching ru
    /// check, ru gibberish under an en word could never lose fairly). "vs" /
    /// "kb" / "dj" — English tokens whose RU-layout reading is also a real
    /// Russian word («мы» / «ли» / «во») — are deliberately NOT listed here.
    /// 0.6.13 kept them in `en` as a blanket lock protecting the owner's
    /// English usage, which permanently broke the RU side instead (the owner
    /// rejected that trade). See `conflictPairs` below for the context-based
    /// resolution that replaced it.
    private static let twoLetterWords: [String: Set<String>] = [
        // "ща" ↔ "of" (same physical keys o+f) — added 16.08.2026 alongside
        // `conflictPairs` below, same mechanism as "мы"/"ли"/"во" ↔ "vs"/
        // "kb"/"dj".
        "ru": ["на", "не", "но", "он", "мы", "за", "по", "от", "до", "из", "их", "им", "ей", "ты", "вы",
               "да", "же", "ли", "бы", "то", "ни", "ну", "со", "во", "ко", "об", "ой", "ах", "ох", "эй", "ща"],
        "en": ["am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "id", "if", "in", "is", "it",
               "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we", "ex", "re"]
    ]

    /// Conflict pairs: two-letter runs where an English token the owner
    /// types daily and a real Russian word are the SAME physically-typed
    /// keys — "vs"↔«мы», "kb"↔«ли», "dj"↔«во». Neither side can be muted
    /// outright (see `twoLetterWords` above), so `detect()` resolves them by
    /// context instead. Keyed by the RU word (the side `detect()` looks this
    /// up from — its `best.core` when the winner reads as Russian); extend
    /// by adding more en↔ru pairs here.
    private static let conflictPairs: [String: String] = [
        "мы": "vs",
        "ли": "kb",
        "во": "dj",
        "ща": "of"
    ]

    private func scoreWord(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
        if lowered.count == 1 {
            guard let letter = lowered.first,
                  Self.oneLetterWords[language]?.contains(letter) == true else { return 0 }
            // Below the 84-100 a dictionary hit scores: a one-letter word is
            // real, but it is also the weakest possible evidence, and it has
            // to lose to any longer word competing for the same run.
            return 70
        }
        if lowered.count == 2 {
            guard Self.twoLetterWords[language]?.contains(lowered) == true else { return 0 }
            return 84
        }
        guard lowered.count >= 2 else { return 0 }

        // BloomFilter-only membership check (pure in-memory, no IPC) — this
        // runs synchronously on every word boundary (space/punctuation) for
        // every candidate layout, inside the CGEventTap callback.
        // `dictionary.contains`/`isSpellCheckerValid` used to be called here,
        // confirming via `NSSpellChecker.checkSpelling` — a call that can
        // block for 100+ms (macOS spell-checking IPC), which is exactly what
        // disabled the event tap and dropped keystrokes during normal typing
        // (CLAUDE.md perf audit). `mightContain` accepts the BloomFilter's
        // ~0.5% false-positive rate instead: the cost is an occasional missed
        // correction (falls through to `.noSwitch`, user can still Double
        // Shift manually) or a slightly wider net for a genuinely valid word
        // outside the bundled 714K list — never a blocked keystroke.
        if dictionary.mightContain(lowered, language: language) {
            let lengthBonus = min(20, lowered.count * 2)
            return 80 + lengthBonus  // 84-100
        }

        return 0
    }

    /// Junk-override's full condition set, in the order they're cheapest to
    /// fail first. Mirrors `override_fires` in
    /// Scripts/research/false_switch_sim.py — the corpus numbers documented
    /// there (false switches, OOV recall, nonling false positives) are the
    /// authority on these thresholds, so keep both in sync on any change.
    /// `possibleBigrams` availability is checked here rather than by the
    /// callers because `junk`/`clean` need it to even run — nil from either
    /// language degrades to "don't fire", never to "treat as impossible" or
    /// "treat as always possible".
    private func junkOverrideFires(
        ownCore: String, ownLang: String,
        targetCore: String, targetLang: String,
        context: String?
    ) -> Bool {
        guard ownCore.count >= 3, targetCore.count >= 4 else { return false }
        guard context != ownLang else { return false }
        guard scoreWord(ownCore, language: ownLang) == 0 else { return false }
        guard let ownBigrams = dictionary.possibleBigrams(language: ownLang),
              let targetBigrams = dictionary.possibleBigrams(language: targetLang)
        else { return false }
        guard JunkMeter.isJunk(ownCore, language: ownLang, possibleBigrams: ownBigrams) else { return false }
        guard JunkMeter.isClean(targetCore, language: targetLang, possibleBigrams: targetBigrams) else { return false }
        return true
    }

    /// Junk-override is disabled — ONLY for junk-override, the rest of
    /// `detect()` is unaffected — while a terminal/editor is frontmost:
    /// `ax=none` there (CLAUDE.md) means there is no way to verify or repair
    /// a wrong guess, so the cost of a mistake is higher than in an
    /// AX-readable app. `currentAppBundleID` is a cache updated by
    /// `appActivatedForJunkOverrideGate`, never a live `NSWorkspace` query —
    /// see the property's doc comment for why.
    private func isJunkOverrideBlockedByTerminal() -> Bool {
        guard let bundleID = currentAppBundleID else { return false }
        return Self.junkOverrideTerminalBundleIDs.contains(bundleID)
    }

    static func shouldSkip(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for p in skipPatterns {
            if p.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    static func isMixedScript(_ text: String) -> Bool {
        var hasCyrillic = false, hasLatin = false
        for s in text.unicodeScalars {
            if (0x0400...0x04FF).contains(s.value) { hasCyrillic = true }
            if (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) { hasLatin = true }
            if hasCyrillic && hasLatin { return true }
        }
        return false
    }

    /// Best-guess source language of already-rendered `text` (AX selection,
    /// clipboard, word before caret) from its OWN characters — Cyrillic vs
    /// Latin letters, majority wins on mixed content. Never looks at the
    /// active layout: for ready-made text there are no original keystrokes,
    /// and the active layout may have nothing to do with what produced this
    /// text (see CLAUDE.md "марже" bug). Returns nil when the text carries no
    /// Cyrillic/Latin letters at all (pure digits/punctuation/emoji) —
    /// callers must treat that as "can't tell", never guess.
    static func dominantScriptLanguageCode(_ text: String) -> String? {
        var cyrillic = 0, latin = 0
        for s in text.unicodeScalars {
            if (0x0400...0x04FF).contains(s.value) { cyrillic += 1 }
            else if (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) { latin += 1 }
        }
        guard cyrillic > 0 || latin > 0 else { return nil }
        return cyrillic >= latin ? "ru" : "en"
    }
}
