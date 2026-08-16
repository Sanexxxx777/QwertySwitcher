#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Honest Python port of the BOUNDARY correction path in
Core/LanguageDetector.swift `detect(keystrokes:)` (the space/punctuation-driven
autocorrection, NOT InstantCorrectionAnalyzer's mid-word path).

Три замера (все читают ТОЛЬКО bundled-словари и корпуса рядом с этим файлом):

1. FALSE SWITCHES (исходный, 15.08): честное родное слово (топ-10000 своего
   частотного корпуса), контекст родной — сколько слов детектор ЛОЖНО флипает
   в другую раскладку. База 0.6.14: ru->en = 8, en->ru = 5.

2. OOV RECALL (новый, 16.08): слово из топ-10000, ОТСУТСТВУЮЩЕЕ в bundled-
   словаре (класс «баги»/«последний»), набрано в ЧУЖОЙ раскладке — сколько
   таких детектор чинит. До junk-override — структурный 0% («победитель обязан
   быть в словаре»).

3. NONLING FP (новый, 16.08, из адверсариального ревью): нелингвистические
   токены (CLI, расширения, аббревиатуры, ru-сокращения) из nonling_corpus.txt —
   junk-override не имеет права их трогать. Частотный топ-10000 к этому классу
   слеп, поэтому отдельный корпус.

Запуск:  python3 false_switch_sim.py            — все замеры при текущей конфигурации
         python3 false_switch_sim.py --grid     — сетка порогов junk-override
         python3 false_switch_sim.py --no-override — отключить override (базовые числа 0.6.14)

------------------------------------------------------------------------------
Ported faithfully from (read 2026-08-15, re-checked 2026-08-16):
  Core/LanguageDetector.swift  — detect(): projections/core split, scoreWord,
                                   candidate scoring loop, collisionGap(10),
                                   incumbentGap(25), contextBias(5), the +5
                                   current-layout tie-breaker, the
                                   ">1 core -> reject" rule, the
                                   "winner must be in dictionary" rule,
                                   twoLetterWords, conflictPairs, native-context
                                   incumbent lock, one-letter context gate.
  Core/NGramAnalyzer.swift     — forbidden/common bigram tables, score().
  Core/WordFrequency.swift     — top ~145 ru / ~148 en word bonus sets.
  Dictionary/WordDictionary.swift — parseWordList (lowercased, len>=2 only) —
                                   this is what mightContain's bloom filter was
                                   actually built from.

Approximations (unchanged from 15.08): Bloom -> exact set membership
(conservative for this study); UCKeyTranslate -> the KEY2RU table transcribed
from InputBuffer.swift (33/33 bijection, asserted).
"""
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.normpath(os.path.join(BASE, "..", "..", "Resources", "Dictionaries"))

# ============================================================================
# Keyboard map — macOS Russian (ЙЦУКЕН) over US QWERTY, physical key -> letter.
# Transcribed from InputBuffer.swift's `isLetterKey` keycode table (see the
# 15.08 note about the broken zip() table in instant_corr_research.py).
# ============================================================================
KEY2RU = {
    "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
    "[": "х", "]": "ъ",
    "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д",
    ";": "ж", "'": "э",
    "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
    ",": "б", ".": "ю",
    "`": "ё",
}
RU2KEY = {v: k for k, v in KEY2RU.items()}
assert len(KEY2RU) == 33 and len(RU2KEY) == 33, "keyboard map must be a clean 33/33 bijection"

RU_AL = set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
EN_AL = set("abcdefghijklmnopqrstuvwxyz")
assert RU_AL == set(RU2KEY.keys())
assert EN_AL == set(KEY2RU.keys()) - set("[]';,.`")

RU_VOWELS = set("аеёиоуыэюя")
EN_VOWELS = set("aeiouy")


def translit(word, table):
    try:
        return "".join(table[ch] for ch in word)
    except KeyError:
        return None


def core_of(rendered):
    """LanguageDetector.core(of:) — [leading][core][trailing]; None если буквы
    прерваны не-буквой (>1 ядра)."""
    n = len(rendered)
    i = 0
    while i < n and not rendered[i].isalpha():
        i += 1
    j = i
    while j < n and rendered[j].isalpha():
        j += 1
    core = rendered[i:j]
    if not core:
        return None
    if any(ch.isalpha() for ch in rendered[j:]):
        return None
    return core


def is_mixed_script(s):
    has_cyr = any(0x0400 <= ord(ch) <= 0x04FF for ch in s)
    has_lat = any((0x0041 <= ord(ch) <= 0x005A) or (0x0061 <= ord(ch) <= 0x007A) for ch in s)
    return has_cyr and has_lat


# ============================================================================
# NGramAnalyzer.swift — verbatim.
# ============================================================================
FORBIDDEN_RU = {
    "ьъ", "ъь", "ъъ", "ыъ", "ъы", "эъ", "ъэ", "юъ", "ъю", "яъ", "ъя",
    "ьь", "ыь", "ъё", "ёъ", "жщ", "щж", "шщ", "щш", "цщ", "щц",
    "гщ", "щг", "фщ", "щф", "ыы", "ыэ", "эы", "ьы", "ыь", "ъй",
    "йъ", "ьй", "щы", "ыщ", "щэ", "эщ", "шы", "ышь", "чщ", "щч",
}
FORBIDDEN_EN = {
    "qx", "xq", "qz", "zq", "jx", "xj", "jq", "qj", "vq", "qv",
    "zx", "xz", "bx", "xb", "kx", "xk", "wx", "xw", "vx", "xv",
    "jz", "zj", "fq", "qf", "gx", "xg", "hx", "xh", "mx", "xm",
    "px", "xp", "bq", "qb", "wq", "qw", "vj", "jv", "zg", "gz",
}
COMMON_RU = {
    "ст": 9, "но": 9, "то": 9, "на": 8, "ен": 8, "ни": 8, "ов": 8, "ко": 8,
    "ро": 8, "ра": 8, "по": 8, "ал": 8, "ор": 8, "пр": 8, "ер": 8, "ре": 8,
    "не": 8, "об": 7, "ос": 7, "ол": 7, "от": 7, "ли": 7, "ка": 7, "ом": 7,
    "ел": 7, "ан": 7, "ти": 7, "ри": 7, "ве": 7, "ой": 7, "да": 7, "ат": 7,
    "ит": 7, "ло": 7, "го": 7, "ва": 6, "ле": 6, "та": 6, "ет": 6, "ки": 6,
}
COMMON_EN = {
    "th": 9, "he": 9, "in": 8, "er": 8, "an": 8, "re": 8, "on": 8, "at": 8,
    "en": 8, "nd": 8, "ti": 7, "es": 7, "or": 7, "te": 7, "of": 7, "ed": 7,
    "is": 7, "it": 7, "al": 7, "ar": 7, "st": 7, "to": 7, "nt": 7, "ng": 7,
    "se": 7, "ha": 6, "as": 6, "ou": 6, "io": 6, "le": 6, "ve": 6, "co": 6,
    "me": 6, "de": 6, "hi": 6, "ri": 6, "ro": 6, "ic": 6, "ne": 6, "ea": 6,
}


def ngram(word, lang):
    w = word.lower()
    if len(w) < 2:
        return 0
    bigrams = [w[i:i + 2] for i in range(len(w) - 1)]
    forbidden = FORBIDDEN_RU if lang == "ru" else FORBIDDEN_EN
    common = COMMON_RU if lang == "ru" else COMMON_EN
    for bg in bigrams:
        if bg in forbidden:
            return -50
    total = sum(common.get(bg, 0) for bg in bigrams)
    matches = sum(1 for bg in bigrams if bg in common)
    ratio = matches / len(bigrams)
    return int(ratio * min(total, 40))


# ============================================================================
# WordFrequency.swift — transcribed verbatim.
# ============================================================================
TOP_RU = set("""
и в не на я что он с это а как но все она так
его только мне было еще бы мы вот за то по от вы
же ты да ее уже к ну тут мой из тебя когда нет
них нас сейчас для если может есть чтобы себя при этом
надо тебе тоже потом где ни время очень после будет они
был даже ему здесь нет раз один там два знаю люди
этот ничего лет теперь хотя более день первый мир между
какой место жизнь через должен другой каждый стал чем дело
большой год новый свой работа конечно дом слово вопрос много
город ответ наш хорошо деньги число иметь дать хотеть нужно
сказать думать знать говорить видеть стоять идти делать мочь
быть стать начать понять работать любить жить ходить взять
привет спасибо пожалуйста здравствуйте пока сегодня завтра вчера
утро вечер ночь день неделя месяц книга школа дорога рука
глаз голова ребенок друг женщина мужчина земля вода страна
""".split())

TOP_EN = set("""
the be to of and a in that have i it for not on
with he as you do at this but his by from they we
say her she or an will my one all would there their
what so up out if about who get which go me when
make can like time no just him know take people into
year your good some could them see other than then now
look only come its over think also back after use two
how our work first well way even new want because any
these give day most us great between need each much right
here still own find long very after thing many world before
should may through while where more around never small last
hand high keep every same begin might show always next early
move live start since help open close run real help home
best both side part point end head turn old again under
let call few big must off line house number place water
hello please thank thanks yes sorry okay welcome today tomorrow
""".split())


def freq_bonus(word, lang):
    table = TOP_RU if lang == "ru" else TOP_EN
    return 25 if word.lower() in table else 0


# ============================================================================
# Closed short-word lists — LanguageDetector.swift oneLetterWords /
# twoLetterWords / conflictPairs (0.6.13-0.6.14).
# ============================================================================
ONE_LETTER = {
    "ru": {"а", "и", "в", "к", "о", "с", "у", "я"},
    "en": {"a", "i"},
}
TWO_LETTER = {
    "ru": {"на", "не", "но", "он", "мы", "за", "по", "от", "до", "из", "их", "им", "ей", "ты", "вы",
           "да", "же", "ли", "бы", "то", "ни", "ну", "со", "во", "ко", "об", "ой", "ах", "ох", "эй"},
    "en": {"am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "id", "if", "in", "is", "it",
           "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we", "ex", "re"},
}
CONFLICT_PAIRS = {"мы": "vs", "ли": "kb", "во": "dj"}


# ============================================================================
# Bundled dictionaries — parseWordList (lowercased, len>=2).
# ============================================================================
def load_dict_set(path):
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.strip().lower()
            if len(w) >= 2:
                out.add(w)
    return out


DICT = {
    "ru": load_dict_set(f"{DICT_DIR}/ru_RU.txt"),
    "en": load_dict_set(f"{DICT_DIR}/en_US.txt"),
}


def score_word(word, lang):
    lowered = word.lower()
    if len(lowered) == 1:
        return 70 if lowered in ONE_LETTER.get(lang, set()) else 0
    if len(lowered) == 2:
        return 84 if lowered in TWO_LETTER.get(lang, set()) else 0
    if lowered in DICT[lang]:
        return 80 + min(20, len(lowered) * 2)
    return 0


# ============================================================================
# Junk-метрика (16.08, принцип «мусорность прочтения = самостоятельный сигнал»).
# POSSIBLE[lang] = все биграммы, встречающиеся хоть в одном словарном слове
# длины >=3 (len-2 мусор словаря базу не расширяет). Swift-зеркало живёт в
# Dictionary/WordDictionary.swift (possibleBigrams) — менять СИНХРОННО.
# ============================================================================
POSSIBLE = {}
for _lang in ("ru", "en"):
    _p = set()
    for _w in DICT[_lang]:
        if len(_w) >= 3:
            for _i in range(len(_w) - 1):
                _p.add(_w[_i:_i + 2])
    POSSIBLE[_lang] = _p


def junk(word, lang):
    """Мусорность прочтения: нет ни одной гласной ИЛИ есть биграмма, не
    встречающаяся ни в одном словарном слове языка."""
    w = word.lower()
    if len(w) < 2:
        return False
    vowels = RU_VOWELS if lang == "ru" else EN_VOWELS
    if not any(c in vowels for c in w):
        return True
    return any(w[i:i + 2] not in POSSIBLE[lang] for i in range(len(w) - 1))


def clean(word, lang):
    """Правдоподобие цели: есть гласная И все биграммы possible."""
    w = word.lower()
    vowels = RU_VOWELS if lang == "ru" else EN_VOWELS
    if not any(c in vowels for c in w):
        return False
    return all(w[i:i + 2] in POSSIBLE[lang] for i in range(len(w) - 1))


# ============================================================================
# Junk-override configuration (single source of truth for the sweep AND the
# documented final thresholds; Swift mirror in LanguageDetector.swift).
# ============================================================================
OVERRIDE = {
    "enabled": True,
    # Пороги раздельные: own-core может быть короче цели (ведущий апостроф
    # «'llb»→«эдди» не входит в core). Цель несёт главный риск-гейт.
    "own_min_len": 3,
    "target_min_len": 4,
}


def override_fires(own_core, target_core, own_lang, other_lang, context):
    """Все условия junk-override (порядок = Swift-реализация):
    own core существует и внесловарный, junk(own), пороги длины,
    контекст НЕ свой язык явно, цель одно ядро и clean."""
    if not OVERRIDE["enabled"]:
        return False
    if own_core is None or target_core is None:
        return False
    if len(own_core) < OVERRIDE["own_min_len"] or len(target_core) < OVERRIDE["target_min_len"]:
        return False
    if context == own_lang:          # явный контекст своего языка -> отказ
        return False
    if score_word(own_core, own_lang) != 0:   # своё словарное -> отказ
        return False
    if not junk(own_core, own_lang):
        return False
    if not clean(target_core, other_lang):
        return False
    return True


# ============================================================================
# LanguageDetector.detect() — boundary path, ported. context:
#   "same"   — previousWordLanguage == own layout language (родной поток)
#   "none"   — nil (начало ввода)
#   "target" — язык другой раскладки (поток чинившихся слов)
# ============================================================================
CONTEXT_BIAS = 5
COLLISION_GAP = 10
INCUMBENT_GAP = 25
CURRENT_LAYOUT_TIEBREAK = 5


def detect_boundary(own_word, own_lang, context="same"):
    """Returns (result, winner_lang, winner_core, other_reading_full)."""
    other_lang = "en" if own_lang == "ru" else "ru"
    other_table = RU2KEY if own_lang == "ru" else KEY2RU
    own_reading = own_word
    other_reading = translit(own_word, other_table)

    own_core = core_of(own_reading)
    if own_core and is_mixed_script(own_core):
        own_core = None
    other_core = core_of(other_reading) if other_reading is not None else None
    if other_core and is_mixed_script(other_core):
        other_core = None

    previous_lang = {"same": own_lang, "none": None, "target": other_lang}[context]

    candidates = []
    for lang, core in ((own_lang, own_core), (other_lang, other_core)):
        if not core:
            continue
        dscore = score_word(core, lang)
        in_dict = dscore > 0
        score = dscore
        score += ngram(core, lang)
        score += freq_bonus(core, lang)
        if score > 0 and lang == previous_lang:
            score += CONTEXT_BIAS
        if score > 0 and lang == own_lang:
            score += CURRENT_LAYOUT_TIEBREAK
        if score > 0:
            candidates.append({"lang": lang, "core": core, "score": score, "in_dict": in_dict})

    if not candidates:
        # Точка A junk-override: целевое прочтение не набрало ни балла, но
        # экран может быть очевидной кракозяброй. previousWordLanguage при
        # срабатывании = язык ЦЕЛИ (находка ревью #6).
        if override_fires(own_core, other_core, own_lang, other_lang, previous_lang):
            return ("switchTo", other_lang, other_core, other_reading)
        return ("noSwitch", None, None, other_reading)

    candidates.sort(key=lambda c: -c["score"])
    best = candidates[0]

    if best["lang"] == own_lang:
        # «Своё выиграло по очкам» — override стоит ПОСЛЕ (ревью #12).
        return ("noSwitch", None, None, other_reading)

    if not best["in_dict"]:
        # Точка C junk-override: ровно место бывшего words-only guard.
        if override_fires(own_core, best["core"], own_lang, other_lang, previous_lang):
            return ("switchTo", other_lang, best["core"], other_reading)
        return ("noSwitch", None, None, other_reading)

    # conflictPairs (0.6.14)
    if best["lang"] == "ru" and best["core"] in CONFLICT_PAIRS \
            and own_reading.lower() == CONFLICT_PAIRS[best["core"]]:
        if previous_lang == "en":
            return ("noSwitch", None, None, other_reading)
        elif previous_lang == "ru":
            pass
        else:
            return ("noSwitch", None, None, other_reading)  # lowercase default

    # native-context incumbent lock (0.6.13)
    _inc = next((c for c in candidates if c["lang"] == own_lang), None)
    if _inc and _inc["in_dict"] and previous_lang == own_lang:
        return ("noSwitch", None, None, other_reading)

    # one-letter context gate (0.6.13)
    if len(best["core"]) == 1 and previous_lang is not None and previous_lang != best["lang"]:
        return ("noSwitch", None, None, other_reading)

    if len(candidates) >= 2 and (candidates[0]["score"] - candidates[1]["score"]) < COLLISION_GAP:
        return ("noSwitch", None, None, other_reading)

    incumbent = next((c for c in candidates if c["lang"] == own_lang), None)
    if incumbent and incumbent["in_dict"] and (best["score"] - incumbent["score"]) < INCUMBENT_GAP:
        return ("noSwitch", None, None, other_reading)

    return ("switchTo", best["lang"], best["core"], other_reading)


# ============================================================================
# Corpora
# ============================================================================
def load_freq(path, alphabet):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            w = parts[0].lower()
            if w and all(ch in alphabet for ch in w):
                out.append((w, int(parts[1])))
    return out


FREQ_RU = load_freq(f"{BASE}/ru_50k.txt", RU_AL)
FREQ_EN = load_freq(f"{BASE}/en_50k.txt", EN_AL)


def load_nonling(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) == 2:
                out.append((parts[0].lower(), parts[1]))
    return out


NONLING = load_nonling(f"{BASE}/nonling_corpus.txt")


# ============================================================================
# Self-check: reproduce documented behaviors before trusting the sweep.
# ============================================================================
def self_check():
    r1, _, _, _ = detect_boundary("баги", "ru", context="same")
    assert r1 == "noSwitch", "0.6.13 native lock: 'баги' must not flip"
    # эдди в EN-раскладке = 'llb — own core None (апостроф ведёт, буквы не
    # прерваны -> core есть на самом деле: 'llb -> core=llb). Проверяем через
    # правильную семантику: юзер хочет 'эдди', раскладка EN, экран = 'llb.
    if OVERRIDE["enabled"]:
        gib = translit("эдди", RU2KEY)          # "'llb"
        r2, wl, wc, _ = detect_boundary_screen(gib, "en", context="none")
        assert (r2, wl) == ("switchTo", "ru") and wc == "эдди", \
            f"junk-override must fix 'эдди' (got {r2},{wl},{wc})"
        r3, _, _, _ = detect_boundary_screen("tmp", "en", context="same")
        assert r3 == "noSwitch", "context gate must protect 'tmp' in en flow"
    print("[self-check] OK (баги locked; эдди fixed via override; tmp guarded)")


def detect_boundary_screen(screen_text, layout_lang, context):
    """Как detect_boundary, но вход — то, что ВИДНО на экране в раскладке
    layout_lang (для OOV-recall и nonling-замеров). Для letters-only токенов
    это одно и то же; отдельное имя — для читаемости замеров."""
    return detect_boundary(screen_text, layout_lang, context=context)


# ============================================================================
# Sweeps
# ============================================================================
def sweep_false(freq, own_lang, topn=10000, context="same"):
    """Замер 1: ложные смены на честных родных словах."""
    rows = []
    checked = 0
    for rank, (w, _cnt) in enumerate(freq[:topn], start=1):
        checked += 1
        result, wlang, wcore, reading = detect_boundary(w, own_lang, context=context)
        if result != "switchTo":
            continue
        cat = "A" if w in DICT[own_lang] else "B"
        rows.append({"rank": rank, "word": w, "category": cat,
                     "reading": reading, "winner": wcore, "winner_lang": wlang})
    return rows, checked


def sweep_oov_recall(freq, target_lang, topn=10000, context="none"):
    """Замер 2: OOV-слово target_lang набрано в чужой раскладке — чинится ли."""
    other = "en" if target_lang == "ru" else "ru"
    fwd = RU2KEY if target_lang == "ru" else KEY2RU
    fixed, missed = 0, 0
    miss_rows = []
    for w, _cnt in freq[:topn]:
        if len(w) < 3 or w in DICT[target_lang]:
            continue
        gib = translit(w, fwd)
        if gib is None:
            continue
        result, wlang, wcore, _ = detect_boundary_screen(gib, other, context=context)
        if result == "switchTo" and wlang == target_lang and wcore == w:
            fixed += 1
        else:
            missed += 1
            if len(miss_rows) < 12:
                miss_rows.append((w, gib))
    return fixed, missed, miss_rows


def sweep_dict_recall(freq, target_lang, topn=10000, context="none"):
    """Замер 2б: СЛОВАРНЫЕ частотные слова в чужой раскладке (главный путь) —
    контроль, что ремонт словаря поднимает именно это."""
    other = "en" if target_lang == "ru" else "ru"
    fwd = RU2KEY if target_lang == "ru" else KEY2RU
    fixed, missed = 0, 0
    for w, _cnt in freq[:topn]:
        if len(w) < 3:
            continue
        gib = translit(w, fwd)
        if gib is None:
            continue
        result, wlang, wcore, _ = detect_boundary_screen(gib, other, context=context)
        if result == "switchTo" and wlang == target_lang and wcore == w:
            fixed += 1
        else:
            missed += 1
    return fixed, missed


def sweep_nonling(context_modes=("same", "none")):
    """Замер 3: нелингвистические токены не должны конвертироваться."""
    fired = []
    checked = 0
    for tok, layout in NONLING:
        alphabet = EN_AL if layout == "en" else RU_AL
        if not all(c in alphabet for c in tok):
            continue
        for ctx in context_modes:
            checked += 1
            result, wlang, wcore, reading = detect_boundary(tok, layout, context=ctx)
            if result == "switchTo":
                fired.append((tok, layout, ctx, wcore, reading))
    return fired, checked


def run_all(tag=""):
    print("=" * 90)
    print(f"CONFIG: override={'ON' if OVERRIDE['enabled'] else 'OFF'} "
          f"own_min={OVERRIDE['own_min_len']} target_min={OVERRIDE['target_min_len']}  {tag}")
    print("=" * 90)

    fr, nr = sweep_false(FREQ_RU, "ru")
    fe, ne = sweep_false(FREQ_EN, "en")
    print(f"[1] false switches (context=same): ru->en {len(fr)}/{nr}   en->ru {len(fe)}/{ne}"
          f"   (база 0.6.14: 8 и 5)")
    for r in fr:
        print(f"      ru FP: {r['word']} -> {r['reading']} (win={r['winner']}, cat={r['category']})")
    for r in fe:
        print(f"      en FP: {r['word']} -> {r['reading']} (win={r['winner']}, cat={r['category']})")

    for ctx in ("none", "target"):
        fx_r, ms_r, miss_r = sweep_oov_recall(FREQ_RU, "ru", context=ctx)
        fx_e, ms_e, _ = sweep_oov_recall(FREQ_EN, "en", context=ctx)
        print(f"[2] OOV recall (context={ctx}): ru {fx_r}/{fx_r+ms_r} "
              f"({100.0*fx_r/max(fx_r+ms_r,1):.0f}%)   en {fx_e}/{fx_e+ms_e} "
              f"({100.0*fx_e/max(fx_e+ms_e,1):.0f}%)")

    dr_f, dr_m = sweep_dict_recall(FREQ_RU, "ru")
    de_f, de_m = sweep_dict_recall(FREQ_EN, "en")
    print(f"[2b] dict-path recall (context=none, top-10000, len>=3): "
          f"ru {dr_f}/{dr_f+dr_m} ({100.0*dr_f/max(dr_f+dr_m,1):.0f}%)   "
          f"en {de_f}/{de_f+de_m} ({100.0*de_f/max(de_f+de_m,1):.0f}%)")

    fired, checked = sweep_nonling()
    print(f"[3] nonling FP: {len(fired)}/{checked} (каждый — глазами)")
    for tok, layout, ctx, wcore, reading in fired:
        print(f"      NONLING FIRE: {tok} [{layout}, ctx={ctx}] -> {wcore} (full: {reading})")
    return {"false_ru": len(fr), "false_en": len(fe), "nonling": len(fired)}


def grid():
    # База для сравнения nonling: сколько стреляет БЕЗ override (словарный путь).
    OVERRIDE["enabled"] = False
    base_fired, checked = sweep_nonling()
    base_set = {(t, l, c) for t, l, c, _, _ in base_fired}
    print(f"base (no override): nonling {len(base_fired)}/{checked}")
    OVERRIDE["enabled"] = True
    for own_L, tgt_L in ((3, 3), (3, 4), (4, 4), (3, 5), (4, 5)):
        OVERRIDE["own_min_len"] = own_L
        OVERRIDE["target_min_len"] = tgt_L
        fr, _ = sweep_false(FREQ_RU, "ru")
        fe, _ = sweep_false(FREQ_EN, "en")
        fx_r, ms_r, _ = sweep_oov_recall(FREQ_RU, "ru", context="none")
        fx_e, ms_e, _ = sweep_oov_recall(FREQ_EN, "en", context="none")
        fired, checked = sweep_nonling()
        new = [t for t, l, c, _, _ in fired if (t, l, c) not in base_set]
        print(f"own>={own_L} tgt>={tgt_L}: false={len(fr)}+{len(fe)}  "
              f"OOV recall ru {100.0*fx_r/max(fx_r+ms_r,1):.0f}% en {100.0*fx_e/max(fx_e+ms_e,1):.0f}%  "
              f"nonling +{len(new)} новых сверх базы: {sorted(set(new))}")


if __name__ == "__main__":
    if "--no-override" in sys.argv:
        OVERRIDE["enabled"] = False
    self_check() if OVERRIDE["enabled"] else print("[self-check] skipped (override off)")
    if "--grid" in sys.argv:
        grid()
    else:
        run_all()
