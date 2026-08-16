#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Ремонт bundled-словарей Resources/Dictionaries/{ru_RU.txt,en_US.txt}.

1. Чистка: len<=2 — удалить целиком; len 3-5 — удалить, если ОДНОВРЕМЕННО
   (i) отсутствует в полном частотном списке своего языка (ru_50k.txt/
   en_50k.txt) И (ii) отвергнута NSSpellChecker; len>=6 — не трогать.
2. Пополнение (ТОЛЬКО ru_RU.txt): слова из топ-30000 строк ru_50k.txt,
   которых нет в словаре, len>=3, состоят только из букв русского алфавита.
3. Атомарная запись (tmp+rename), отсортировано, \n-терминировано.
   Бэкап оригиналов в dict_backup_20260816/ до записи.
4. Отчётные артефакты removed_ru.txt / removed_en.txt.
"""
import os
import shutil
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.normpath(os.path.join(BASE, "..", "..", "Resources", "Dictionaries"))
BACKUP_DIR = os.path.join(BASE, "dict_backup_20260816")

RU_ALPHABET = set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")

CONTROL_CASES = [
    ("оце", "ru", False),
    ("зек", "ru", True),
    ("llb", "en", False),
    ("hello", "en", True),
]


def spell_checker():
    from AppKit import NSSpellChecker
    import Foundation

    sc = NSSpellChecker.sharedSpellChecker()

    def spell_ok(word, lang):
        r = sc.checkSpellingOfString_startingAt_language_wrap_inSpellDocumentWithTag_wordCount_(
            word, 0, lang, False, 0, None
        )
        return r[0].location == Foundation.NSNotFound

    return spell_ok


def load_dict(path):
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def load_freq_full(path):
    """Полный частотный список -> set слов (lowercase), для условия (i)."""
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            out.add(parts[0].lower())
    return out


def load_freq_ordered(path):
    """Частотный список в порядке файла (rank 1..N) -> список слов, для пополнения."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            out.append(parts[0].lower())
    return out


def atomic_write_sorted(path, words):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for w in sorted(words):
            f.write(w + "\n")
    os.replace(tmp, path)


def main():
    spell_ok = spell_checker()

    # --- control values gate ---
    print("Контрольные значения спеллчекера:")
    all_ok = True
    for word, lang, expected in CONTROL_CASES:
        got = spell_ok(word, lang)
        status = "OK" if got == expected else "MISMATCH"
        if got != expected:
            all_ok = False
        print(f"  spell_ok({word!r},{lang!r}) = {got}  (expected {expected})  {status}")
    if not all_ok:
        print("СТОП: контрольные значения не сходятся. Ничего не записано.")
        sys.exit(1)

    ru_path = os.path.join(DICT_DIR, "ru_RU.txt")
    en_path = os.path.join(DICT_DIR, "en_US.txt")

    ru_words = load_dict(ru_path)
    en_words = load_dict(en_path)

    freq_ru_full = load_freq_full(os.path.join(BASE, "ru_50k.txt"))
    freq_en_full = load_freq_full(os.path.join(BASE, "en_50k.txt"))
    freq_ru_ordered = load_freq_ordered(os.path.join(BASE, "ru_50k.txt"))

    stats = {}

    def classify_and_clean(words, lang, freq_full):
        removed_le2 = []
        removed_35 = []
        kept = []
        for w in words:
            n = len(w)
            if n <= 2:
                removed_le2.append(w)
                continue
            if 3 <= n <= 5:
                if w not in freq_full and not spell_ok(w, lang):
                    removed_35.append(w)
                    continue
            kept.append(w)
        return kept, removed_le2, removed_35

    ru_kept, ru_removed_le2, ru_removed_35 = classify_and_clean(ru_words, "ru", freq_ru_full)
    en_kept, en_removed_le2, en_removed_35 = classify_and_clean(en_words, "en", freq_en_full)

    # --- пополнение ТОЛЬКО ru ---
    ru_kept_set = set(ru_kept)
    added_ru = []
    for w in freq_ru_ordered[:30000]:
        if len(w) >= 3 and all(ch in RU_ALPHABET for ch in w) and w not in ru_kept_set:
            added_ru.append(w)
            ru_kept_set.add(w)
    ru_final = sorted(ru_kept_set)
    en_final = sorted(set(en_kept))

    stats["ru"] = {
        "removed_le2": len(ru_removed_le2),
        "removed_35": len(ru_removed_35),
        "added": len(added_ru),
        "final_size": len(ru_final),
        "orig_size": len(ru_words),
    }
    stats["en"] = {
        "removed_le2": len(en_removed_le2),
        "removed_35": len(en_removed_35),
        "added": 0,
        "final_size": len(en_final),
        "orig_size": len(en_words),
    }

    # --- бэкап оригиналов ---
    os.makedirs(BACKUP_DIR, exist_ok=True)
    shutil.copy2(ru_path, os.path.join(BACKUP_DIR, "ru_RU.txt"))
    shutil.copy2(en_path, os.path.join(BACKUP_DIR, "en_US.txt"))

    # --- запись ---
    atomic_write_sorted(ru_path, ru_final)
    atomic_write_sorted(en_path, en_final)

    # --- отчётные артефакты ---
    with open(os.path.join(BASE, "removed_ru.txt"), "w", encoding="utf-8") as f:
        for w in sorted(ru_removed_35):
            f.write(w + "\n")
    with open(os.path.join(BASE, "removed_en.txt"), "w", encoding="utf-8") as f:
        for w in sorted(en_removed_35):
            f.write(w + "\n")

    # --- статистика в stdout ---
    print()
    print("=" * 78)
    print("СТАТИСТИКА РЕМОНТА")
    print("=" * 78)
    for lang in ("ru", "en"):
        s = stats[lang]
        print(f"[{lang}] orig={s['orig_size']}  removed_len<=2={s['removed_le2']}  "
              f"removed_len3-5={s['removed_35']}  added={s['added']}  final={s['final_size']}")

    print()
    print(f"Бэкап оригиналов: {BACKUP_DIR}")
    print(f"Артефакты удалённых len3-5: {os.path.join(BASE, 'removed_ru.txt')}, "
          f"{os.path.join(BASE, 'removed_en.txt')}")


if __name__ == "__main__":
    main()
