#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Honest Python port of the INSTANT (mid-word) correction path —
Core/InstantCorrectionAnalyzer.swift `evaluate()`, PLUS the
KeyboardMonitor-level gate that decides whether it is even called on a
given keystroke (`ambiguousKeyRecent`) — NOT the boundary/space-triggered
`LanguageDetector.detect()` path (that one is already ported in
false_switch_sim.py, imported here for its keyboard map / dictionaries /
n-gram / frequency tables / corpora).

Question: after today's dictionary cleanup (garbage truncations like
"прив"/"сдел"/"иис" removed from Resources/Dictionaries), can
InstantCorrectionAnalyzer.minLength be lowered from 4 to 3?

Ported faithfully from (read 2026-08-16):
  Core/InstantCorrectionAnalyzer.swift — evaluate(), combinedScore(),
    wordLevelScore(), the constants (minLength, currentCeiling=5,
    candidateFloor=35, margin=30).
  Dictionary/WordDictionary.swift — mightContain (bloom -> exact-set
    approximation, same call as false_switch_sim.py), isPrefixOfBundledWord
    (binary search over the sorted len>=2 word list -> ported with
    bisect over the same DICT sets false_switch_sim.py already loads).
  Core/LanguageDetector.swift — shouldSkip (skipPatterns regexes),
    isMixedScript — both are static funcs InstantCorrectionAnalyzer calls
    directly.
  Core/KeyboardMonitor.swift — tryInstantCorrection's gate:
    `!ambiguousKeyRecent` (KeyboardMonitor.ambiguousKeyRecent / the
    lastAmbiguousKeyIndex bookkeeping) — an alphabet-ambiguous physical key
    ([ ] ' ; , . `, i.e. ъ х э ж б ю ё in Russian) blocks tryInstantCorrection
    while it is within the last 2 keystrokes of the run.
  Core/NGramAnalyzer.swift, Core/WordFrequency.swift — reused verbatim via
    false_switch_sim.ngram / freq_bonus (already a faithful port there).

Run:  python3 instant_minlen_sim.py
"""
import bisect
import os
import re
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import false_switch_sim as fs  # noqa: E402  (KEY2RU/RU2KEY, DICT, ngram, freq_bonus, corpora)

# ============================================================================
# Physical-key model (KeyboardMonitor's `runKeystrokes`/`buffer`: keycodes,
# not characters). fs.KEY2RU/RU2KEY are keyed by the physical-key label used
# throughout that file (the roman letter/punct printed on the physical key).
# ============================================================================
AMBIGUOUS_KEYS = {"[", "]", "'", ";", ",", ".", "`"}  # InputBuffer.cyrillicOnlyLetterCodes


def to_keys(word, lang):
    """Physical keys needed to type `word` (of language `lang`) — i.e. what
    InputBuffer.append(keycode:) receives, key for key, regardless of which
    layout ends up active while pressing them."""
    if lang == "ru":
        return [fs.RU2KEY[ch] for ch in word]
    return list(word)


def convert(keys, layout):
    """InputSourceManager.convertKeystrokes(keystrokes, toLayout:) — render
    physical keys as text under a given layout."""
    if layout == "ru":
        return "".join(fs.KEY2RU[k] for k in keys)
    return "".join(keys)


def ambiguous_recent(keys_prefix):
    """KeyboardMonitor.ambiguousKeyRecent: true while an alphabet-ambiguous
    physical key is still within the last keystroke of the run typed so
    far (lastAmbiguousKeyIndex bookkeeping, reset per word — keys_prefix here
    IS the whole word-so-far, so no separate reset needed). Narrowed from
    "last 2 keystrokes" to "last 1" on 21.08.2026 — the real field corpus
    (Scripts/research/kc_trace_words.py, 26h trace) found ambiguousKeyRecent
    was the 2nd-largest cause (31%, after the junk-gate's 62%) of instant
    staying silent on words the boundary path then had to fix; the 2-key
    window was measured to add zero new false positives at the 1-key width
    (see this file's own measures 1/1b/2/2b + instant_junk_gate_sim.py)."""
    last_idx = None
    for i, k in enumerate(keys_prefix, start=1):
        if k in AMBIGUOUS_KEYS:
            last_idx = i
    if last_idx is None:
        return False
    return (len(keys_prefix) - last_idx) < 1


# ============================================================================
# WordDictionary — mightContain (bloom -> exact set, same approximation
# false_switch_sim.py already documents and uses) + isPrefixOfBundledWord
# (binary search over the sorted len>=2 word list).
# ============================================================================
SORTED_DICT = {lang: sorted(fs.DICT[lang]) for lang in ("ru", "en")}


def might_contain(word, lang):
    return word in fs.DICT[lang]


def is_prefix_of_bundled_word(prefix, lang):
    words = SORTED_DICT[lang]
    idx = bisect.bisect_left(words, prefix)
    if idx >= len(words):
        return False
    return words[idx].startswith(prefix)


def word_level_score(lowered, lang):
    if might_contain(lowered, lang):
        return 80 + min(20, len(lowered) * 2)
    if is_prefix_of_bundled_word(lowered, lang):
        return 35
    return 0


# ============================================================================
# LanguageDetector.shouldSkip / isMixedScript — static helpers
# InstantCorrectionAnalyzer.evaluate() calls directly on currentText/
# candidateText.
# ============================================================================
SKIP_PATTERNS = [
    re.compile(r"^\d+$"),
    re.compile(r"^0x[0-9a-fA-F]+$"),
    re.compile(r"^[a-zA-Z_]\w*[A-Z]\w*$"),
    re.compile(r"^[a-zA-Z_]+_[a-zA-Z_]+$"),
    re.compile(r"^https?://"),
    re.compile(r"^[\w.]+@[\w.]+"),
    re.compile(r"^[/~][\w/.]+"),
    re.compile(r"^\.[a-z]+"),
    re.compile(r"^[A-Z]{2,}$"),
]


def should_skip(text):
    return any(p.search(text) for p in SKIP_PATTERNS)


def is_mixed_script(text):
    return fs.is_mixed_script(text)


# ============================================================================
# InstantCorrectionAnalyzer.combinedScore / evaluate — verbatim port.
# ============================================================================
CURRENT_CEILING = 5
CANDIDATE_FLOOR = 35
MARGIN = 30


def combined_score(word, lang):
    lowered = word.lower()
    if len(lowered) < 2:
        return (0, 0)
    wl = word_level_score(lowered, lang)
    total = wl + fs.ngram(lowered, lang) + fs.freq_bonus(lowered, lang)
    return (total, wl)


def evaluate_instant(keys_prefix, current_lang, other_langs, min_length):
    """Returns (winner_lang, corrected_word) or None. Mirrors
    InstantCorrectionAnalyzer.evaluate() exactly, including guard order."""
    if len(keys_prefix) < min_length:
        return None
    current_text = convert(keys_prefix, current_lang)
    if not current_text or should_skip(current_text):
        return None
    cur_total, cur_wl = combined_score(current_text, current_lang)
    if cur_wl != 0 or cur_total > CURRENT_CEILING:
        return None
    best = None
    for lang in other_langs:
        cand_text = convert(keys_prefix, lang)
        if not cand_text or is_mixed_script(cand_text):
            continue
        cand_total, cand_wl = combined_score(cand_text, lang)
        if cand_wl <= 0:
            continue
        if cand_total < CANDIDATE_FLOOR:
            continue
        if cand_total - cur_total < MARGIN:
            continue
        if best is None or cand_total > best[1]:
            best = (lang, cand_total, cand_text)
    if best is None:
        return None
    return best[0], best[2]


def first_instant_fire(keys, current_lang, other_lang, min_length, max_len):
    """Scan prefixes [min_length..max_len] (inclusive), applying the
    ambiguousKeyRecent gate exactly like tryInstantCorrection does on every
    keystroke. Returns (fire_length, winner_lang, winner_word) of the FIRST
    prefix that fires, or None."""
    for i in range(min_length, max_len + 1):
        prefix = keys[:i]
        if ambiguous_recent(prefix):
            continue
        result = evaluate_instant(prefix, current_lang, [other_lang], min_length)
        if result is not None:
            return i, result[0], result[1]
    return None


# ============================================================================
# Self-check — documented behaviors that must reproduce BEFORE trusting the
# sweep numbers.
# ============================================================================
def self_check():
    problems = []

    # 1. "работа" typed hf,jnf under EN active (0.6.13: fires on the 5th
    #    letter — the comma key at position 3 blocks tryInstantCorrection
    #    for the next 2 keystrokes via ambiguousKeyRecent).
    # A fire at prefix length N converts the WORD-SO-FAR (N letters), not the
    # eventual full word — checked against word[:N], not the complete word.
    keys = to_keys("работа", "ru")
    assert keys == list("hf,jnf"), f"работа keys mismatch: {keys}"
    r = first_instant_fire(keys, "en", "ru", min_length=4, max_len=len(keys) - 1)
    if r is None or r[2] != "работа"[: r[0]]:
        problems.append(f"'работа' (hf,jnf, minLength=4) did not fire correctly: {r}")
    else:
        expected_len = 5
        tag = "OK" if r[0] == expected_len else "OK (different length than documented 5, not a failure)"
        print(f"[self-check] 'работа' hf,jnf @ minLength=4: fires at letter {r[0]} -> '{r[2]}' ({tag})")

    # 2. "привет" typed ghbdtn under EN active — no ambiguous keys, must fire
    #    well before the space (minLength=4).
    keys2 = to_keys("привет", "ru")
    assert keys2 == list("ghbdtn"), f"привет keys mismatch: {keys2}"
    r2 = first_instant_fire(keys2, "en", "ru", min_length=4, max_len=len(keys2) - 1)
    if r2 is None or r2[2] != "привет"[: r2[0]]:
        problems.append(f"'привет' (ghbdtn, minLength=4) did not fire correctly: {r2}")
    else:
        print(f"[self-check] 'привет' ghbdtn @ minLength=4: fires at letter {r2[0]} -> '{r2[2]}' (OK)")

    # 3. "bbc" -> "иис": dictionary-cleanup self-check. "иис" must be absent
    #    from ru_RU.txt (exact entry AND as a bundled-word prefix), so the
    #    instant path must NOT fire on "bbc" typed honestly in EN at
    #    minLength=3 (its own full length).
    iis_exact = might_contain("иис", "ru")
    iis_prefix = is_prefix_of_bundled_word("иис", "ru")
    bbc_in_en_dict = might_contain("bbc", "en")
    print(f"[self-check] dict state: 'иис' exact={iis_exact} prefix-of-bundled={iis_prefix}"
          f"   'bbc' in en_US.txt={bbc_in_en_dict}")
    if iis_exact:
        problems.append("'иис' still an exact ru dictionary entry — cleanup incomplete")
    if iis_prefix:
        # Not a live FP today (guarded independently: "bbc" itself is now a
        # recognized EN word, so the current.wordLevel==0 gate blocks this
        # candidate before it is even scored) — but it means the ORIGINAL
        # vector is only masked, not closed: "иис" is still a genuine prefix
        # of "иисус" (a real dictionary word), so wordLevelScore("иис","ru")
        # still scores 35 as a candidate. Recorded as an anomaly, not a
        # self-check failure.
        print("[self-check] ANOMALY note: 'иис' is a genuine prefix of a real word ('иисус') —"
              " candidate scoring for 'bbc' is masked only by 'bbc' itself now being in en_US.txt,"
              " not by the ru-side cleanup; see 'Аномалии' in the report")
    keys3 = to_keys("bbc", "en")
    r3 = evaluate_instant(keys3, "en", ["ru"], min_length=3)
    if r3 is not None:
        problems.append(f"'bbc' @ minLength=3 STILL fires: {r3} (was the known pre-cleanup FP)")
    else:
        print("[self-check] 'bbc' honest EN @ minLength=3: no fire (OK — pre-cleanup FP is gone)")

    # 4. Garbage truncation class removed — spot-check membership.
    removed_now_absent = {w: (w not in fs.DICT["ru"]) for w in ("иис", "сдел", "рабо")}
    still_present = {w: v for w, v in removed_now_absent.items() if not v}
    if still_present:
        problems.append(f"expected-removed garbage words still in ru dict: {still_present}")
    else:
        print(f"[self-check] garbage-truncation class absent from ru_RU.txt: {list(removed_now_absent)} (OK)")
    # Anomaly (not a failure): "прив" was NOT removed by the cleanup — it
    # survived because it independently qualifies (frequency list / spell
    # check), unlike "иис"/"сдел"/"рабо". Recorded, not asserted.
    priv_present = "прив" in fs.DICT["ru"]
    print(f"[self-check] ANOMALY note: 'прив' present in ru_RU.txt = {priv_present}"
          " (kept intentionally by dict_repair.py's own criteria — NOT part of the garbage class"
          " removed today, unlike сдел/рабо/иис; see 'Аномалии' in the report)")

    if problems:
        print("\n[self-check] FAILED:")
        for p in problems:
            print("  -", p)
        return False
    print("[self-check] ALL OK\n")
    return True


# ============================================================================
# Measure 1 — FP on honest native typing (own layout, own top-10000 corpus).
# Checks prefixes [minLength .. len(word)-1] — mid-word only, excludes the
# just-completed full word (that moment is the boundary path's business).
# ============================================================================
def sweep_native_fp(freq, own_lang, min_length, topn=10000):
    other = "en" if own_lang == "ru" else "ru"
    fired = []
    checkable = 0
    for w, _cnt in freq[:topn]:
        if len(w) - 1 < min_length:
            continue  # no valid mid-word prefix at all for this length
        checkable += 1
        keys = to_keys(w, own_lang)
        r = first_instant_fire(keys, own_lang, other, min_length, max_len=len(w) - 1)
        if r is not None:
            fired.append((w, r[0], r[1], r[2]))
    return fired, checkable


def sweep_native_fp_full_length(freq, own_lang, min_length, topn=10000):
    """Same coverage-gap fix as measure 2b, applied to measure 1: honest
    words whose length equals min_length (e.g. 3-letter words at
    minLength=3, same class the 'bbc' self-check probes) get NO mid-word
    prefix under the len-1 range and would otherwise go unchecked."""
    other = "en" if own_lang == "ru" else "ru"
    fired = []
    checkable = 0
    for w, _cnt in freq[:topn]:
        if len(w) < min_length:
            continue
        checkable += 1
        keys = to_keys(w, own_lang)
        r = first_instant_fire(keys, own_lang, other, min_length, max_len=len(w))
        if r is not None:
            fired.append((w, r[0], r[1], r[2]))
    return fired, checkable


# ============================================================================
# Measure 2 — FP on the nonlinguistic corpus (token typed in its stated
# layout). Same mid-word-only prefix range as measure 1.
# ============================================================================
def sweep_nonling_fp(min_length):
    fired = []
    checkable = 0
    for tok, layout in fs.NONLING:
        alphabet = fs.EN_AL if layout == "en" else fs.RU_AL
        if not all(c in alphabet for c in tok):
            continue
        if len(tok) - 1 < min_length:
            continue
        checkable += 1
        other = "en" if layout == "ru" else "ru"
        keys = to_keys(tok, layout)
        r = first_instant_fire(keys, layout, other, min_length, max_len=len(tok) - 1)
        if r is not None:
            fired.append((tok, layout, r[0], r[1], r[2]))
    return fired, checkable


# ============================================================================
# Measure 2b — nonling FP at FULL token length (not excluded like measure 2).
# Most of nonling_corpus.txt is exactly 3 characters (tmp, src, git, ls...),
# which the mid-word-only range (measure 2) structurally never reaches at
# minLength=3 (range 3..2 is empty — same edge case as the "bbc" self-check).
# A 3-letter token IS a live instant-correction risk in practice: the tap
# sequence hits minLength right as the LAST letter of the token lands,
# before Space is pressed, so this checks that exact point directly instead
# of leaving it uncovered.
# ============================================================================
def sweep_nonling_fp_full_length(min_length):
    fired = []
    checkable = 0
    for tok, layout in fs.NONLING:
        alphabet = fs.EN_AL if layout == "en" else fs.RU_AL
        if not all(c in alphabet for c in tok):
            continue
        if len(tok) < min_length:
            continue
        checkable += 1
        other = "en" if layout == "ru" else "ru"
        keys = to_keys(tok, layout)
        r = first_instant_fire(keys, layout, other, min_length, max_len=len(tok))
        if r is not None:
            fired.append((tok, layout, r[0], r[1], r[2]))
    return fired, checkable


# ============================================================================
# Measure 3 — gain: own-language word X typed in the WRONG active layout Y.
# Compares first-fire length at minLength=3 vs minLength=4 over the SAME
# mid-word prefix range methodology (word length >= 4 needed for minLength=3
# to have any candidate prefix at all).
# ============================================================================
def sweep_gain(freq, own_lang, topn=10000):
    other = "en" if own_lang == "ru" else "ru"  # the WRONG active layout
    rows = []
    considered = 0
    for w, _cnt in freq[:topn]:
        if len(w) - 1 < 3:
            continue
        considered += 1
        keys = to_keys(w, own_lang)
        r4 = first_instant_fire(keys, other, own_lang, min_length=4, max_len=len(w) - 1)
        r3 = first_instant_fire(keys, other, own_lang, min_length=3, max_len=len(w) - 1)
        rows.append((w, r3[0] if r3 else None, r4[0] if r4 else None))
    return rows, considered


def summarize_gain(rows):
    earlier = 0
    fires3 = 0
    fires4 = 0
    gains = []
    for _w, l3, l4 in rows:
        if l3 is not None:
            fires3 += 1
        if l4 is not None:
            fires4 += 1
        if l3 is not None and (l4 is None or l3 < l4):
            earlier += 1
            if l4 is not None:
                gains.append(l4 - l3)
    avg_gain = sum(gains) / len(gains) if gains else 0.0
    return {
        "n": len(rows), "fires3": fires3, "fires4": fires4,
        "earlier": earlier, "avg_gain_when_both_fire": avg_gain,
        "gain_samples": len(gains),
    }


# ============================================================================
# Main
# ============================================================================
def main():
    ok = self_check()
    if not ok:
        print("\nSELF-CHECK FAILED — numbers below are NOT trustworthy, printing anyway for diagnosis.\n")

    print("=" * 90)
    for min_length in (4, 3):
        print(f"--- minLength = {min_length} ---")

        fired_ru, chk_ru = sweep_native_fp(fs.FREQ_RU, "ru", min_length)
        fired_en, chk_en = sweep_native_fp(fs.FREQ_EN, "en", min_length)
        print(f"[1] native honest-typing FP (mid-word, excludes full word length):"
              f" ru {len(fired_ru)}/{chk_ru} checkable   en {len(fired_en)}/{chk_en} checkable")
        for w, ln, lang, cw in fired_ru:
            print(f"      ru FP: '{w}' fires at letter {ln} -> {lang}:'{cw}'")
        for w, ln, lang, cw in fired_en:
            print(f"      en FP: '{w}' fires at letter {ln} -> {lang}:'{cw}'")

        fired_ru2, chk_ru2 = sweep_native_fp_full_length(fs.FREQ_RU, "ru", min_length)
        fired_en2, chk_en2 = sweep_native_fp_full_length(fs.FREQ_EN, "en", min_length)
        print(f"[1b] native honest-typing FP (INCLUDING full word length, e.g. words of exactly"
              f" minLength letters): ru {len(fired_ru2)}/{chk_ru2} checkable"
              f"   en {len(fired_en2)}/{chk_en2} checkable")
        for w, ln, lang, cw in fired_ru2:
            print(f"      ru FP (full-len): '{w}' fires at letter {ln} -> {lang}:'{cw}'")
        for w, ln, lang, cw in fired_en2:
            print(f"      en FP (full-len): '{w}' fires at letter {ln} -> {lang}:'{cw}'")

        fired_nl, chk_nl = sweep_nonling_fp(min_length)
        print(f"[2] nonling-corpus FP (mid-word, excludes full token length): {len(fired_nl)}/{chk_nl} checkable")
        for tok, layout, ln, lang, cw in fired_nl:
            print(f"      NONLING FP: '{tok}' [{layout}] fires at letter {ln} -> {lang}:'{cw}'")

        fired_nl2, chk_nl2 = sweep_nonling_fp_full_length(min_length)
        print(f"[2b] nonling-corpus FP (INCLUDING full token length, e.g. 3-letter tokens at"
              f" minLength=3): {len(fired_nl2)}/{chk_nl2} checkable")
        for tok, layout, ln, lang, cw in fired_nl2:
            print(f"      NONLING FP (full-len): '{tok}' [{layout}] fires at letter {ln} -> {lang}:'{cw}'")
        print()

    print("=" * 90)
    print("--- gain: minLength=3 vs minLength=4 (own word typed in the WRONG active layout) ---")
    rows_ru, n_ru = sweep_gain(fs.FREQ_RU, "ru")
    rows_en, n_en = sweep_gain(fs.FREQ_EN, "en")
    sum_ru = summarize_gain(rows_ru)
    sum_en = summarize_gain(rows_en)
    for tag, s in (("ru->en", sum_ru), ("en->ru", sum_en)):
        pct_earlier = 100.0 * s["earlier"] / s["n"] if s["n"] else 0.0
        print(f"[3] {tag}: n={s['n']}  fires@3={s['fires3']} ({100.0*s['fires3']/s['n']:.1f}%)"
              f"  fires@4={s['fires4']} ({100.0*s['fires4']/s['n']:.1f}%)"
              f"  earlier-by->=1-letter={s['earlier']} ({pct_earlier:.1f}%)"
              f"  avg_gain(letters, both fire, n={s['gain_samples']})={s['avg_gain_when_both_fire']:.2f}")


if __name__ == "__main__":
    main()
