#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Bench for the CANDIDATE symmetric junk-gate on the INSTANT (mid-word)
correction path (owner's fix hypothesis, 19.08.2026 field defect: mid-word
ru->en correction fires on OOV Russian input — jargon/typo/name — because
the "ru-prefix must be dictionary-word to block" gate stays silent for
words outside the dictionary while the en candidate still wins).

Gate under test: at each keystroke, if the OWN reading of the prefix typed
SO FAR (in the currently active layout) is CLEAN by the junk metric — has a
vowel AND every bigram is possible in that language, mirroring the
boundary-path junk-override (Core/JunkMeter.swift, 0.6.15) — instant does
NOT fire at that prefix length. The boundary path (space) and Double Shift
get the final say instead, since they see the whole word.

This is a MEASUREMENT script only — no source under Sources/ is touched.

Ported pieces (read 2026-08-19 before writing this bench):
  Scripts/research/instant_minlen_sim.py — evaluate_instant(), first_instant_fire(),
    to_keys(), convert(), ambiguous_recent() — the honest port of
    Core/InstantCorrectionAnalyzer.swift + KeyboardMonitor's ambiguousKeyRecent
    gate. minLength is 4 in the shipped 0.6.15 build (raising it to 3 was
    measured and REJECTED — see that file's docstring / CLAUDE.md TODO).
  Scripts/research/false_switch_sim.py — junk()/clean() (the existing honest
    port of Core/JunkMeter.swift, already used by the boundary-path
    junk-override and cross-checked against the Swift source below), plus
    fs.DICT / fs.FREQ_RU / fs.FREQ_EN / fs.NONLING / fs.RU2KEY / fs.KEY2RU.
  Sources/QwertySwitcher/Core/JunkMeter.swift — isJunk/isClean: vowel sets
    (ru "аеёиоуыэюя", en "aeiouy") + possibleBigrams (all bigrams occurring
    in ANY dictionary word of length>=3). Verified line-by-line against
    false_switch_sim.junk/clean — see "Что я проверил" printed at the end.

Run:  python3 instant_junk_gate_sim.py
"""
import os
import random
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import instant_minlen_sim as im   # noqa: E402  (evaluate_instant, first_instant_fire, to_keys, convert, ambiguous_recent)
import false_switch_sim as fs     # noqa: E402  (junk, clean, DICT, FREQ_RU, FREQ_EN, NONLING, RU2KEY, KEY2RU)

MIN_LENGTH = 4  # InstantCorrectionAnalyzer.minLength, shipped 0.6.15 value.


# ============================================================================
# The candidate gate: same scan as im.first_instant_fire, plus a check BEFORE
# evaluate_instant at every prefix length — mirrors ambiguousKeyRecent's
# "continue" pattern exactly (a keystroke can be skipped and re-tried on the
# NEXT keystroke; the gate is not a one-time verdict on the whole word).
# ============================================================================
def first_instant_fire_gated(keys, current_lang, other_lang, min_length, max_len):
    for i in range(min_length, max_len + 1):
        prefix = keys[:i]
        if im.ambiguous_recent(prefix):
            continue
        own_text = im.convert(prefix, current_lang)
        if fs.clean(own_text, current_lang):
            continue  # gated: own reading of the prefix looks like a real word
        result = im.evaluate_instant(prefix, current_lang, [other_lang], min_length)
        if result is not None:
            return i, result[0], result[1]
    return None


# ============================================================================
# Keyboard-neighbor map for the "typo" mutation corpora (measures 3b/4b).
# Physical QWERTY adjacency (same keys fs.RU2KEY/fs.KEY2RU are keyed by) —
# approximate, good enough for "replace one letter with a neighboring key",
# NOT a claim of pixel-accurate stagger geometry.
# ============================================================================
ADJACENT = {
    'q': "wa", 'w': "qeas", 'e': "wrds", 'r': "edft", 't': "rfgy",
    'y': "tghu", 'u': "yhji", 'i': "ujko", 'o': "iklp", 'p': "ol[",
    '[': "p']", ']': "['",
    'a': "qwsz", 's': "qweadzx", 'd': "wersfxc", 'f': "ertdgcv",
    'g': "rtyfhvb", 'h': "tyugjbn", 'j': "yuihknm", 'k': "uiojlm,",
    'l': "iopk;.", ';': "lp['.", "'": "[];",
    'z': "asx", 'x': "zsdc", 'c': "xdfv", 'v': "cfgb", 'b': "vghn",
    'n': "bhjm", 'm': "njk,", ',': "mkl.", '.': ",l;",
    '`': "q",
}


def mutate_keys(keys, rng, max_tries=10):
    """One-letter keyboard-neighbor typo. Returns (mutated_keys, position) or
    None if no adjacency data for any tried position (shouldn't happen for
    real words — all 33 physical keys are covered)."""
    idxs = list(range(len(keys)))
    rng.shuffle(idxs)
    for i in idxs[:max_tries]:
        orig = keys[i]
        opts = ADJACENT.get(orig)
        if not opts:
            continue
        choices = [c for c in opts if c != orig]
        if not choices:
            continue
        out = list(keys)
        out[i] = rng.choice(choices)
        return out, i
    return None


def build_mutation_corpus(freq_list, lang, seed, target_n=5000, len_lo=5, len_hi=9):
    rng = random.Random(seed)
    rows = []
    for w, _cnt in freq_list:
        if len(rows) >= target_n:
            break
        if not (len_lo <= len(w) <= len_hi):
            continue
        keys = im.to_keys(w, lang)
        m = mutate_keys(keys, rng)
        if m is None:
            continue
        mutated_keys, pos = m
        mutated_word = im.convert(mutated_keys, lang)
        rows.append((f"{w}~{mutated_word}(pos{pos})", mutated_keys))
    return rows


def load_wordlist(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.strip().lower()
            if w:
                out.append(w)
    return out


REMOVED_RU = load_wordlist(f"{BASE}/removed_ru.txt")
REMOVED_EN = load_wordlist(f"{BASE}/removed_en.txt")


# ============================================================================
# Generic measure runner. rows: iterable of (label, keys) where keys is the
# FULL physical-key sequence for that item (max_len = len(keys)).
# ============================================================================
def run_measure(rows, current_lang, other_lang, check_recoverable=False):
    """check_recoverable: for measures where `label` IS the honest full target
    word (measures 1/2 only — measure 3/4 labels are typo/OOV strings, this
    check is meaningless there and left off), also count how many BLOCKED
    items are themselves a bundled dictionary word of the candidate language
    — i.e. still recoverable by the boundary path (space) or Double Shift
    once the whole word is on screen, NOT a hard loss."""
    n = 0
    fired = 0
    blocked = 0
    recoverable = 0
    examples_blocked = []
    examples_not_blocked = []
    for label, keys in rows:
        max_len = len(keys)
        if max_len < MIN_LENGTH:
            continue
        n += 1
        baseline = im.first_instant_fire(keys, current_lang, other_lang, MIN_LENGTH, max_len)
        if baseline is None:
            continue
        fired += 1
        gated = first_instant_fire_gated(keys, current_lang, other_lang, MIN_LENGTH, max_len)
        base_len, base_lang, base_cand = baseline
        own_reading = im.convert(keys[:base_len], current_lang)
        own_status = "CLEAN" if fs.clean(own_reading, current_lang) else "junk"
        if gated is None:
            blocked += 1
            is_recoverable = check_recoverable and label in fs.DICT[base_lang]
            if is_recoverable:
                recoverable += 1
            if len(examples_blocked) < 20:
                examples_blocked.append((label, own_reading, own_status, base_lang, base_cand, is_recoverable))
        else:
            if len(examples_not_blocked) < 20:
                examples_not_blocked.append((label, own_reading, own_status, base_lang, base_cand, gated[0]))
    return {"n": n, "fired": fired, "blocked": blocked, "recoverable": recoverable,
            "check_recoverable": check_recoverable,
            "examples_blocked": examples_blocked, "examples_not_blocked": examples_not_blocked}


def print_measure(name, corpus_label, res):
    n, fired, blocked = res["n"], res["fired"], res["blocked"]
    frac = (100.0 * blocked / fired) if fired else 0.0
    print(f"{name} | {corpus_label} | N={n} | fired_now={fired} | blocked_by_gate={blocked} | "
          f"{frac:.1f}%")
    if res["check_recoverable"] and blocked:
        rec = res["recoverable"]
        print(f"      of blocked, still a bundled dictionary word (recoverable at boundary/DS): "
              f"{rec}/{blocked} ({100.0*rec/blocked:.1f}%)   HARD loss (not in either dict): "
              f"{blocked-rec}/{blocked} ({100.0*(blocked-rec)/blocked:.1f}%)")
    for label, own_reading, status, blang, bcand, is_rec in res["examples_blocked"]:
        tag = " [recoverable@boundary]" if is_rec else (" [HARD loss]" if res["check_recoverable"] else "")
        print(f"      BLOCKED: '{label}' -> own='{own_reading}' [{status}] "
              f"(baseline fired -> {blang}:'{bcand}'){tag}")
    if not res["examples_blocked"] and res["examples_not_blocked"]:
        for label, own_reading, status, blang, bcand, gated_len in res["examples_not_blocked"][:5]:
            print(f"      NOT blocked (still fires): '{label}' -> own='{own_reading}' [{status}] "
                  f"-> {blang}:'{bcand}' (gated fire len {gated_len})")
    print()


# ============================================================================
# Measure 1 — recall loss ru->en: EN word typed while ru is active.
# ============================================================================
def measure_1():
    rows = []
    for w, _cnt in fs.FREQ_EN[:10000]:
        if 4 <= len(w) <= 10:
            rows.append((w, im.to_keys(w, "en")))
    return run_measure(rows, "ru", "en", check_recoverable=True)


# ============================================================================
# Measure 2 — recall loss en->ru: RU word typed while en is active.
# ============================================================================
def measure_2():
    rows = []
    for w, _cnt in fs.FREQ_RU[:10000]:
        if 4 <= len(w) <= 10:
            rows.append((w, im.to_keys(w, "ru")))
    return run_measure(rows, "en", "ru", check_recoverable=True)


# ============================================================================
# Measure 3 — FP protection ru->en: honest OOV/typo Russian-ish text typed
# while ru is active, instant currently mis-flips to en.
# ============================================================================
def measure_3():
    rows_removed = [(w, im.to_keys(w, "ru")) for w in REMOVED_RU if len(w) >= 4]
    rows_mutated = build_mutation_corpus(fs.FREQ_RU, "ru", seed=20260819)
    rows_nonling = [(tok, im.to_keys(tok, "ru")) for tok, layout in fs.NONLING
                     if layout == "ru" and len(tok) >= 4 and all(c in fs.RU_AL for c in tok)]
    return {
        "removed_ru (len>=4)": run_measure(rows_removed, "ru", "en"),
        "ru_50k mutated (len5-9, n=5000, seed=20260819)": run_measure(rows_mutated, "ru", "en"),
        "nonling_corpus (ru-tagged, len>=4)": run_measure(rows_nonling, "ru", "en"),
    }


# ============================================================================
# Measure 4 — FP protection en->ru: honest OOV/typo English-ish text typed
# while en is active, instant currently mis-flips to ru.
# ============================================================================
def measure_4():
    rows_removed = [(w, im.to_keys(w, "en")) for w in REMOVED_EN if len(w) >= 4]
    rows_mutated = build_mutation_corpus(fs.FREQ_EN, "en", seed=20260819)
    rows_nonling = [(tok, im.to_keys(tok, "en")) for tok, layout in fs.NONLING
                     if layout == "en" and len(tok) >= 4 and all(c in fs.EN_AL for c in tok)]
    return {
        "removed_en (len>=4)": run_measure(rows_removed, "en", "ru"),
        "en_50k mutated (len5-9, n=5000, seed=20260819)": run_measure(rows_mutated, "en", "ru"),
        "nonling_corpus (en-tagged, len>=4)": run_measure(rows_nonling, "en", "ru"),
    }


# ============================================================================
# Measure 5 — sanity: legitimate en->ru mid-word corrections must keep firing
# (own reading during typing is JUNK — no vowel — so the gate must not touch
# them).
# ============================================================================
def measure_5():
    print("=" * 90)
    print("[5] SANITY CHECK — instant must keep firing on honest en->ru corrections")
    print("=" * 90)
    all_ok = True
    for word in ("работа", "привет"):
        keys = im.to_keys(word, "ru")
        baseline = im.first_instant_fire(keys, "en", "ru", MIN_LENGTH, len(keys))
        gated = first_instant_fire_gated(keys, "en", "ru", MIN_LENGTH, len(keys))
        ok = baseline is not None and gated == baseline
        all_ok = all_ok and ok
        if baseline is not None:
            own_reading = im.convert(keys[:baseline[0]], "en")
            status = "CLEAN" if fs.clean(own_reading, "en") else "junk"
            print(f"  '{word}' (keys={''.join(keys)}): baseline fires at letter {baseline[0]} "
                  f"-> {baseline[1]}:'{baseline[2]}'   own='{own_reading}' [{status}]   "
                  f"gated={'SAME' if gated == baseline else gated}   {'OK' if ok else 'FAIL'}")
        else:
            print(f"  '{word}': baseline did NOT fire at all — sanity corpus itself broken: FAIL")
    print(f"\n  VERDICT: {'PASS' if all_ok else 'FAIL'}")
    print()
    return all_ok


def main():
    ok = im.self_check()
    if not ok:
        print("\n[instant_minlen_sim self-check] FAILED — numbers below not trustworthy.\n")

    print("=" * 90)
    print("[1] RECALL LOSS ru->en (EN word typed while ru active, top-10000 en_50k, len 4-10)")
    print("=" * 90)
    print_measure("[1]", "en_50k top10000 len4-10", measure_1())

    print("=" * 90)
    print("[2] RECALL LOSS en->ru (RU word typed while en active, top-10000 ru_50k, len 4-10)")
    print("=" * 90)
    print_measure("[2]", "ru_50k top10000 len4-10", measure_2())

    print("=" * 90)
    print("[3] FP PROTECTION ru->en (OOV/typo Russian-ish text, ru active)")
    print("=" * 90)
    for corpus_label, res in measure_3().items():
        print_measure("[3]", corpus_label, res)

    print("=" * 90)
    print("[4] FP PROTECTION en->ru (OOV/typo English-ish text, en active)")
    print("=" * 90)
    for corpus_label, res in measure_4().items():
        print_measure("[4]", corpus_label, res)

    sanity_ok = measure_5()

    print("=" * 90)
    print(f"FINAL SANITY VERDICT: {'PASS' if sanity_ok else 'FAIL'}")
    print("=" * 90)


if __name__ == "__main__":
    main()
