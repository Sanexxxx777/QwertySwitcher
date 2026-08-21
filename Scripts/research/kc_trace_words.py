#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Reconstructs real field words from the owner's per-key verbose trace
(21.08.2026 diagnostic: "instant fires rarely" — 26h field log, 19.08 08:09
-> 21.08 09:30, debug.1.log + debug.log concatenated in file order, which
IS chronological order since rotation only ever appends) and runs them
through the SHIPPED 0.6.17 instant-correction gate (the same port
instant_junk_gate_sim.py already validated) to answer: for words that were
typed in the WRONG layout and got fixed at the boundary/Double Shift
instead of instantly, exactly which gate silenced instant, and how close it
got. This is the honest-corpus counterpart to the frequency-list measures
in instant_junk_gate_sim.py / instant_minlen_sim.py — same ported scoring,
real typing instead of a word list.

Why this exists: before Core/KeyboardMonitor.swift's `instant silent:`
logging (added same day, commit "Instant-коррекция: причина отказа в
verbose-лог"), the field log carried zero information about instant's
REFUSALS — only its successes. This script answers the same question
retroactively, off the trace that predates that fix.

MEASUREMENT SCRIPT ONLY — no source under Sources/ is touched.

Privacy (rules/security.md — внешний контент = данные, этот же принцип
здесь в обратную сторону): the ORIGINAL log carries only keycodes/lengths,
never characters. This script is what turns keycodes back into the
owner's actual typed text. Run it only against a scratchpad copy of the
log, and do NOT commit its output (word-level) anywhere under this repo —
only the aggregate counts belong in a report.

Reconstruction method:
  - keycode -> physical-key roman letter: transcribed from
    Core/InputBuffer.swift's `isLetterKey` 33-entry table (same source
    false_switch_sim.py's KEY2RU/RU2KEY are keyed by).
  - active layout at the moment a word was typed: read directly off the
    `X→Y` in the `correction:`/`instant correction:` line itself (`X` is
    `currentLayout.languageCode`, captured in Swift BEFORE the self-switch)
    — NOT tracked from `[IS] layout changed` lines, which for a correction
    always fire the (self) switch to the NEW layout first, so by the time
    the correction line is written the active layout has already flipped
    (confirmed against the raw log: the `(self)` line always precedes its
    `correction:`/`instant correction:` line).
  - word-in-progress: `[KM] key kc=N run=N buf=N lead=N` lines, using
    `buf` (buffer.currentWord().count BEFORE this key) as ground truth —
    trims on backspace (buf < len(word_keys)), resets on a genuine
    desync (buf jumps past len(word_keys), meaning an event was missed).
  - only BOUNDARY corrections (`[KM] correction: X->Y len=N ...`) are
    reconstructed with confidence — Double-Shift-via-history acts on a
    PREVIOUS word and Double-Shift-via-run mixes in non-letter keys typed
    after the ambiguous-punctuation deferral (0.6.0 design: `,.;[]'` `
    always join the buffer, the letter/punctuation split happens at the
    boundary, not at keystroke time) — both out of scope here. See
    "Граница покрытия" printed at the end.
  - INSTANT corrections (`instant correction: X->Y len=N`) are
    reconstructed the same way and used ONLY as a self-check: the ported
    gated evaluator must reproduce the SAME fire length the real Swift
    code logged, or the reconstruction is not trustworthy and the numbers
    below it should not be believed.

Run:  python3 kc_trace_words.py <path-to-concatenated-log>
"""
import os
import re
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import instant_minlen_sim as im   # noqa: E402  (convert, combined_score, should_skip, is_mixed_script, ambiguous_recent, thresholds)
import false_switch_sim as fs     # noqa: E402  (clean — the boundary junk-override's port, same metric the shipped instant junk-gate uses)

MIN_LENGTH = 4  # InstantCorrectionAnalyzer.minLength — unchanged, per the plan.

# Transcribed from Core/InputBuffer.swift's isLetterKey 33-entry table.
KEYCODE_TO_CHAR = {
    0: 'a', 1: 's', 2: 'd', 3: 'f', 4: 'h', 5: 'g', 6: 'z', 7: 'x', 8: 'c', 9: 'v',
    11: 'b', 12: 'q', 13: 'w', 14: 'e', 15: 'r', 16: 'y', 17: 't',
    30: ']', 31: 'o', 32: 'u', 33: '[', 34: 'i', 35: 'p', 37: 'l', 38: 'j',
    39: "'", 40: 'k', 41: ';', 43: ',', 45: 'n', 46: 'm', 47: '.', 50: '`',
}
assert len(KEYCODE_TO_CHAR) == 33, "must match InputBuffer.isLetterKey's 33-entry table"

KEY_RE = re.compile(r'\[KM\] key kc=(\d+) run=(\d+) buf=(\d+) lead=(\d+)')
BOUNDARY_RE = re.compile(r'\[KM\] correction: (en|ru)→(en|ru) len=(\d+) lead=(\d+) trig=(.*?) net=(-?\d+)')
INSTANT_RE = re.compile(r'\[KM\] instant correction: (en|ru)→(en|ru) len=(\d+) lead=(\d+) net=(-?\d+)')


def reconstruct(lines):
    """Walk the log once, yielding one record per boundary/instant
    correction, with the reconstructed word_keys and whether the
    reconstruction is internally consistent (`ok`). Active layout is read
    off each correction line itself (see module docstring) — `[IS] layout
    changed` lines are not used as a cross-check."""
    word_keys = []
    desyncs = 0
    events = []
    for line in lines:
        m = KEY_RE.search(line)
        if m:
            kc, _run, buf, _lead = (int(x) for x in m.groups())
            ch = KEYCODE_TO_CHAR.get(kc)
            if ch is None:
                continue  # number/special key — never touches `buffer`
            if buf < len(word_keys):
                word_keys = word_keys[:buf]  # backspace(s) since the last line
            if buf == len(word_keys):
                word_keys.append(ch)
            else:
                desyncs += 1
                word_keys = [ch]  # missed an event — can't recover the prefix
            continue

        m = BOUNDARY_RE.search(line)
        if m:
            src, _dst, logged_len, _lead, _trig, _net = m.groups()
            logged_len = int(logged_len)
            ok = logged_len == len(word_keys)
            events.append(("boundary", src, list(word_keys), logged_len, ok))
            continue

        m = INSTANT_RE.search(line)
        if m:
            src, _dst, logged_len, lead, _net = m.groups()
            logged_len, lead = int(logged_len), int(lead)
            # KeyboardMonitor.swift:762 — length = leadingSymbols.count +
            # keystrokes.count - 1 (the triggering key is suppressed before
            # delivery, but IS already in word_keys — its own `key kc=` line
            # was logged just before this one).
            expected = len(word_keys) - 1 - lead
            ok = logged_len == expected
            events.append(("instant", src, list(word_keys), logged_len, ok))
            continue
    return events, desyncs


# ============================================================================
# Reasoned port of InstantCorrectionAnalyzer.evaluate — mirrors the SilenceReason
# enum added to Core/InstantCorrectionAnalyzer.swift the same day. Reuses
# im.convert/combined_score/should_skip/is_mixed_script/thresholds verbatim —
# only the bookkeeping of WHY a candidate was rejected is new.
# ============================================================================
def evaluate_instant_reasoned(keys_prefix, current_lang, other_langs):
    current_text = im.convert(keys_prefix, current_lang)
    if not current_text or im.should_skip(current_text):
        return None, "shouldSkip"
    cur_total, cur_wl = im.combined_score(current_text, current_lang)
    if cur_wl != 0 or cur_total > im.CURRENT_CEILING:
        return None, "ownIsWord"

    best = None
    best_silence = None  # (reason, score) — furthest near-miss wins, mirrors the Swift port

    def record(reason, score):
        nonlocal best_silence
        if best_silence is None or score > best_silence[1]:
            best_silence = (reason, score)

    for lang in other_langs:
        cand_text = im.convert(keys_prefix, lang)
        if not cand_text or im.is_mixed_script(cand_text):
            record("mixedScript", 0)
            continue
        cand_total, cand_wl = im.combined_score(cand_text, lang)
        if cand_wl <= 0:
            record("candidateNotValidated", cand_total)
            continue
        if cand_total < im.CANDIDATE_FLOOR:
            record("belowFloor", cand_total)
            continue
        if cand_total - cur_total < im.MARGIN:
            record("belowMargin", cand_total)
            continue
        if best is None or cand_total > best[1]:
            best = (lang, cand_total, cand_text)

    if best is None:
        return None, (best_silence[0] if best_silence else "candidateNotValidated")
    return (best[0], best[2]), None


def first_instant_fire_gated_reasoned(keys, current_lang, other_lang, min_length=MIN_LENGTH):
    """Same scan as instant_junk_gate_sim.first_instant_fire_gated, but keeps
    the LAST silence reason seen (the furthest the word ever got) instead of
    only a fired/not-fired verdict."""
    last_reason, last_len = None, None
    for i in range(min_length, len(keys) + 1):
        prefix = keys[:i]
        if im.ambiguous_recent(prefix):
            last_reason, last_len = "ambiguousKeyRecent", i
            continue
        own_text = im.convert(prefix, current_lang)
        if fs.clean(own_text, current_lang):
            last_reason, last_len = "junkGate", i
            continue
        result, reason = evaluate_instant_reasoned(prefix, current_lang, [other_lang])
        if result is not None:
            return {"fired": True, "len": i, "lang": result[0], "word": result[1]}
        last_reason, last_len = reason, i
    return {"fired": False, "reason": last_reason, "at_len": last_len}


def main():
    if len(sys.argv) < 2:
        print("usage: kc_trace_words.py <path-to-concatenated-log>")
        sys.exit(1)
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    events, desyncs = reconstruct(lines)
    instant_events = [e for e in events if e[0] == "instant"]
    boundary_events = [e for e in events if e[0] == "boundary"]
    print(f"reconstructed: {len(instant_events)} instant, {len(boundary_events)} boundary"
          f"  (buffer desyncs recovered: {desyncs})")

    print("\n=== self-check: gated sim must reproduce the REAL fire length ===")
    matched = mismatched = skipped_bad_recon = 0
    for _, src, keys, logged_len, ok in instant_events:
        if not ok:
            skipped_bad_recon += 1
            continue
        other = "en" if src == "ru" else "ru"
        fire_len = logged_len + 1  # undo the "trigger key suppressed" -1
        prefix = keys[:fire_len]
        sim = first_instant_fire_gated_reasoned(prefix, src, other)
        if sim.get("fired") and sim["len"] == fire_len:
            matched += 1
        else:
            mismatched += 1
            print(f"  MISMATCH: real fired at {fire_len} ({src}->{other}), sim says {sim}")
    print(f"matched: {matched}  mismatched: {mismatched}  "
          f"skipped (reconstruction inconsistent with the logged length): {skipped_bad_recon}")
    if matched == 0:
        print("\n⚠️ ZERO matches — reconstruction is NOT trustworthy, the boundary numbers below are not either.")

    print("\n=== why instant stayed silent on words that got fixed at the boundary ===")
    reasons = {}
    used = 0
    for _, src, keys, logged_len, ok in boundary_events:
        if not ok or len(keys) < MIN_LENGTH:
            continue
        used += 1
        other = "en" if src == "ru" else "ru"
        sim = first_instant_fire_gated_reasoned(keys, src, other)
        tag = f"fired_late@{sim['len']}/{len(keys)}" if sim.get("fired") else (sim.get("reason") or "unknown")
        reasons[tag] = reasons.get(tag, 0) + 1
    print(f"boundary events usable: {used}/{len(boundary_events)} "
          f"(excluded: shorter than minLength or reconstruction inconsistent with the logged length)")
    for tag, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print(f"  {tag}: {n}")

    print("\n=== Граница покрытия ===")
    print("Reconstructed only boundary (`correction:`) and instant events — Double-Shift-via-history/via-run")
    print("corrections are NOT in this corpus (see module docstring). Numbers above describe THIS 26h window")
    print("of ONE user's typing, not a general rate.")


if __name__ == "__main__":
    main()
