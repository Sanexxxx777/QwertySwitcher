#!/usr/bin/env python3
"""Сборка промо-ролика Qwerty Switcher под HyperFrames.

Стиль: brutalist frame.md (Oswald/JetBrains Mono локально, cream/red на угольном,
резкое движение, один акцент в кадре).
Главный приём: посимвольное «перещёлкивание» раскладки — два слоя на символ,
латиница уходит вверх, кириллица приходит снизу. Полностью декларативно → seek-safe.
"""
import html, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qsw-promo", "index.html")

# (латиница, кириллица) — то, что реально набирается в неправильной раскладке
PAIR_1 = ("gj afcn ,jne", "по фаст боту")
PAIR_2 = ("ghbdtn, rfr ltkf?", "привет, как дела?")


def flip_markup(before: str, after: str, cls: str) -> str:
    """Символы в двух слоях: .a — как набралось, .b — как должно быть."""
    cells = []
    for i, (a, b) in enumerate(zip(before.ljust(len(after)), after.ljust(len(before)))):
        a_disp = "&nbsp;" if a == " " else html.escape(a)
        b_disp = "&nbsp;" if b == " " else html.escape(b)
        # два слоя на символ лежат друг на друге намеренно — это и есть приём
        # перещёлкивания; помечаем, чтобы линтер не считал это дефектом вёрстки
        cells.append(
            f'<span class="cell" data-layout-allow-overlap><span class="a">{a_disp}</span>'
            f'<span class="b" data-layout-allow-overlap>{b_disp}</span></span>'
        )
    return f'<div class="{cls} flip">' + "".join(cells) + "</div>"


FACTS = ["В ЛЮБОМ ПРИЛОЖЕНИИ", "ОДНА КЛАВИША", "НИЧЕГО НЕ УХОДИТ В СЕТЬ"]

HTML = f"""<!doctype html>
<html lang="ru">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <script src="gsap.min.js"></script>
    <style>
      /* Локальные шрифты: без сети, детерминированный рендер (frame.md) */
      @font-face {{ font-family: "Oswald"; font-weight: 700; src: url("fonts/Oswald-700-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "Oswald"; font-weight: 700; src: url("fonts/Oswald-700-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "Oswald"; font-weight: 500; src: url("fonts/Oswald-500-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "Oswald"; font-weight: 500; src: url("fonts/Oswald-500-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "JB"; font-weight: 700; src: url("fonts/JetBrainsMono-700-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "JB"; font-weight: 700; src: url("fonts/JetBrainsMono-700-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "JB"; font-weight: 400; src: url("fonts/JetBrainsMono-400-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "JB"; font-weight: 400; src: url("fonts/JetBrainsMono-400-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}

      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #0a0a0c; }}
      #root {{ position: relative; width: 1920px; height: 1080px; }}

      .label {{
        position: absolute; left: 120px; top: 150px;
        font-family: "JB", monospace; font-weight: 400; font-size: 30px;
        letter-spacing: 8px; color: #8c867c; text-transform: uppercase;
      }}
      .rule {{ position: absolute; left: 120px; width: 1680px; height: 6px; background: #25252b; transform-origin: left center; }}

      /* строка перещёлкивания */
      .flip {{ position: absolute; left: 120px; white-space: nowrap; font-family: "JB", monospace; font-weight: 700; }}
      .cell {{ position: relative; display: inline-block; }}
      .cell .a, .cell .b {{ display: inline-block; }}
      .cell .b {{ position: absolute; left: 0; top: 0; }}
      .line1 {{ top: 430px; font-size: 118px; letter-spacing: -2px; color: #ede4d3; }}
      .line1 .b {{ color: #ede4d3; }}
      .line2 {{ top: 430px; font-size: 96px; letter-spacing: -2px; color: #ede4d3; }}
      .line2 .b {{ color: #ede4d3; }}

      .caption {{
        position: absolute; left: 120px; top: 640px;
        font-family: "Oswald", sans-serif; font-weight: 500; font-size: 46px; color: #b8b1a3;
      }}
      .keys {{
        position: absolute; left: 120px; top: 640px;
        font-family: "JB", monospace; font-weight: 700; font-size: 44px;
        letter-spacing: 4px; color: #ee4e4e;
      }}

      .fact {{
        position: absolute; left: 120px;
        font-family: "Oswald", sans-serif; font-weight: 700; font-size: 104px;
        letter-spacing: -2px; color: #ede4d3; text-transform: uppercase; line-height: 1;
      }}
      .fact .n {{ color: #ee4e4e; font-family: "JB", monospace; font-size: 44px; vertical-align: super; margin-right: 28px; }}

      #brand {{
        position: absolute; left: 120px; top: 380px;
        font-family: "Oswald", sans-serif; font-weight: 700; font-size: 150px;
        letter-spacing: -6px; line-height: 0.9; color: #ede4d3; text-transform: uppercase;
      }}
      #brand em {{ font-style: normal; color: #ee4e4e; }}
      #trial {{
        position: absolute; left: 126px; top: 706px;
        font-family: "Oswald", sans-serif; font-weight: 500; font-size: 52px; color: #b8b1a3;
      }}
      #url {{
        position: absolute; left: 126px; top: 800px;
        font-family: "JB", monospace; font-weight: 400; font-size: 36px;
        letter-spacing: 4px; color: #8c867c;
      }}
      #mac {{
        position: absolute; right: 120px; top: 150px;
        font-family: "JB", monospace; font-weight: 400; font-size: 28px;
        letter-spacing: 6px; color: #8c867c; text-transform: uppercase;
      }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="18"
         data-width="1920" data-height="1080">

      <!-- Сцена 1-2: набралось не то → двойной Shift → починилось -->
      <div id="lbl1" class="label clip" data-start="0" data-duration="8.6" data-track-index="0">знакомо?</div>
      <div id="rule1" class="rule clip" data-start="0" data-duration="8.6" data-track-index="1" style="top: 300px"></div>
      {flip_markup(PAIR_1[0], PAIR_1[1], "line1 clip").replace('class="line1 clip flip"', 'id="flip1" class="line1 clip flip" data-start="0" data-duration="4.6" data-track-index="2"')}
      <div id="cap1" class="caption clip" data-start="0.9" data-duration="2.3" data-track-index="3">снова не та раскладка</div>
      <div id="keys1" class="keys clip" data-start="3.3" data-duration="1.3" data-track-index="4">⇧ ⇧ &nbsp;двойной shift</div>

      <!-- Сцена 3: второй пример, быстрее -->
      {flip_markup(PAIR_2[0], PAIR_2[1], "line2 clip").replace('class="line2 clip flip"', 'id="flip2" class="line2 clip flip" data-start="4.8" data-duration="3.8" data-track-index="5"')}
      <div id="cap2" class="caption clip" data-start="7.0" data-duration="1.6" data-track-index="6">и целая фраза — тоже</div>

      <!-- Сцена 4: три факта -->
      <div id="rule2" class="rule clip" data-start="8.8" data-duration="4.4" data-track-index="7" style="top: 300px"></div>
      <div id="f0" class="fact clip" data-start="8.9" data-duration="4.3" data-track-index="8" style="top: 400px"><span class="n">01</span>{FACTS[0]}</div>
      <div id="f1" class="fact clip" data-start="9.5" data-duration="3.7" data-track-index="9" style="top: 550px"><span class="n">02</span>{FACTS[1]}</div>
      <div id="f2" class="fact clip" data-start="10.1" data-duration="3.1" data-track-index="10" style="top: 700px"><span class="n">03</span>{FACTS[2]}</div>

      <!-- Сцена 5: CTA -->
      <div id="mac" class="clip" data-start="13.4" data-duration="4.6" data-track-index="11">для macos</div>
      <div id="rule3" class="rule clip" data-start="13.4" data-duration="4.6" data-track-index="12" style="top: 300px; background: #ee4e4e"></div>
      <div id="brand" class="clip" data-start="13.5" data-duration="4.5" data-track-index="13">Qwerty<br /><em>Switcher</em></div>
      <div id="trial" class="clip" data-start="14.4" data-duration="3.6" data-track-index="14">исправляет раскладку одной клавишей</div>
      <div id="url" class="clip" data-start="14.9" data-duration="3.1" data-track-index="15">shulgin.is-a.dev/store</div>

      <!-- Звук. Музыка: TunnelWave — Time (CC0, archive.org/details/GT410_613).
           Эффекты: библиотека Pixabay из media-use (Pixabay Content License,
           коммерческое использование без обязательной атрибуции).
           Плеером управляет движок — play/pause/seek из кода не звать. -->
      <audio id="bgm" src="audio/bgm18.mp3" data-start="0" data-duration="18" data-track-index="20" data-volume="0.55"></audio>

      <audio id="sfx-type1" src="audio/typing.mp3"       data-start="0.45"  data-duration="1.3"  data-track-index="21" data-volume="0.5"></audio>
      <audio id="sfx-click1" src="audio/click.mp3"        data-start="3.3"   data-duration="0.37" data-track-index="22" data-volume="0.45"></audio>
      <audio id="sfx-whoosh1" src="audio/whoosh-short.mp3" data-start="3.5"   data-duration="0.57" data-track-index="23" data-volume="0.3"></audio>
      <audio id="sfx-impact1" src="audio/impact-bass-1.mp3" data-start="3.6"  data-duration="2.1"  data-track-index="24" data-volume="0.26"></audio>
      <audio id="sfx-type2" src="audio/typing.mp3"       data-start="4.85"  data-duration="0.9"  data-track-index="25" data-volume="0.4"></audio>
      <audio id="sfx-whoosh2" src="audio/whoosh-short.mp3" data-start="6.1"   data-duration="0.57" data-track-index="26" data-volume="0.28"></audio>
      <audio id="sfx-clicksoft" src="audio/click-soft.mp3"   data-start="8.85"  data-duration="0.37" data-track-index="27" data-volume="0.35"></audio>
      <audio id="sfx-key1" src="audio/key-press.mp3"    data-start="8.95"  data-duration="0.4"  data-track-index="28" data-volume="0.35"></audio>
      <audio id="sfx-key2" src="audio/key-press.mp3"    data-start="9.55"  data-duration="0.4"  data-track-index="29" data-volume="0.35"></audio>
      <audio id="sfx-key3" src="audio/key-press.mp3"    data-start="10.15" data-duration="0.4"  data-track-index="30" data-volume="0.35"></audio>
      <audio id="sfx-impact2" src="audio/impact-bass-2.mp3" data-start="13.3" data-duration="2.6"  data-track-index="31" data-volume="0.3"></audio>
    </div>

    <script>
      window.__timelines = window.__timelines || {{}};
      const tl = gsap.timeline({{ paused: true }});
      const cells = (id) => gsap.utils.toArray("#" + id + " .cell");

      /* ---- сцена 1: набор латиницей, посимвольно ---- */
      const c1 = cells("flip1");
      gsap.set("#flip1 .b", {{ yPercent: 110, opacity: 0 }});
      tl.from("#lbl1", {{ opacity: 0, duration: 0.4 }}, 0);
      tl.from("#rule1", {{ scaleX: 0, duration: 0.7, ease: "power3.out" }}, 0.1);
      tl.from(c1.map((c) => c.querySelector(".a")), {{
        opacity: 0, duration: 0.01, stagger: 0.055, ease: "none",
      }}, 0.45);
      tl.from("#cap1", {{ y: 40, opacity: 0, duration: 0.5, ease: "power3.out" }}, 1.0);

      /* ---- сцена 2: перещёлкивание раскладки ---- */
      tl.to("#keys1", {{ duration: 0.01 }}, 3.3);          // якорь появления подсказки
      tl.from("#keys1", {{ x: -30, opacity: 0, duration: 0.35, ease: "power3.out" }}, 3.3);
      tl.to(c1.map((c) => c.querySelector(".a")), {{
        yPercent: -110, opacity: 0, duration: 0.34, stagger: 0.028, ease: "power3.in",
      }}, 3.55);
      tl.to(c1.map((c) => c.querySelector(".b")), {{
        yPercent: 0, opacity: 1, duration: 0.38, stagger: 0.028, ease: "power3.out",
      }}, 3.62);
      tl.to("#rule1", {{ backgroundColor: "#ee4e4e", duration: 0.2 }}, 3.62);

      /* ---- сцена 3: вторая фраза, быстрее ---- */
      const c2 = cells("flip2");
      gsap.set("#flip2 .b", {{ yPercent: 110, opacity: 0 }});
      tl.from(c2.map((c) => c.querySelector(".a")), {{
        opacity: 0, duration: 0.01, stagger: 0.028, ease: "none",
      }}, 4.85);
      tl.to(c2.map((c) => c.querySelector(".a")), {{
        yPercent: -110, opacity: 0, duration: 0.3, stagger: 0.016, ease: "power3.in",
      }}, 6.15);
      tl.to(c2.map((c) => c.querySelector(".b")), {{
        yPercent: 0, opacity: 1, duration: 0.34, stagger: 0.016, ease: "power3.out",
      }}, 6.2);
      tl.from("#cap2", {{ y: 40, opacity: 0, duration: 0.45, ease: "power3.out" }}, 7.05);

      /* ---- сцена 4: факты ---- */
      tl.from("#rule2", {{ scaleX: 0, duration: 0.6, ease: "power3.out" }}, 8.85);
      tl.from("#f0", {{ y: 70, opacity: 0, duration: 0.55, ease: "power3.out" }}, 8.95);
      tl.from("#f1", {{ y: 70, opacity: 0, duration: 0.55, ease: "power3.out" }}, 9.55);
      tl.from("#f2", {{ y: 70, opacity: 0, duration: 0.55, ease: "power3.out" }}, 10.15);

      /* ---- сцена 5: бренд ---- */
      tl.from("#mac", {{ opacity: 0, duration: 0.4 }}, 13.45);
      tl.from("#rule3", {{ scaleX: 0, duration: 0.7, ease: "power3.out" }}, 13.45);
      tl.from("#brand", {{ y: 90, opacity: 0, duration: 0.75, ease: "power3.out" }}, 13.55);
      tl.from("#trial", {{ y: 40, opacity: 0, duration: 0.5, ease: "power3.out" }}, 14.45);
      tl.from("#url", {{ opacity: 0, duration: 0.5 }}, 14.95);

      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(HTML)
print(f"написано: {OUT} ({len(HTML)} байт)")
