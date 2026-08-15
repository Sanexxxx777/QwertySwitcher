#!/usr/bin/env python3
"""Промо-ролик Qwerty Switcher v2 — сценарий «через объём боли».

Отличия от v1 (правки Саши):
  · нет «14 дней бесплатно» — про цену не говорим вообще; сначала ценность
  · нет списка фич — то, что видно глазами, словами не дублируем
  · оформление под саму программу: окно macOS, клавиши Shift, иконка приложения,
    акцент #0272ed взят пипеткой из иконки (вместо портфолийного красного)
  · счётчик считает РЕАЛЬНУЮ длину строки (12 символов = 12 backspace) —
    честный факт из кадра, а не выдуманная статистика

Стиль кадра — frame.md brutalist с подменой акцента на цвет продукта.
"""
import html, os

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "qsw-promo2", "index.html")

PAIR_1 = ("gj afcn ,jne", "по фаст боту")
PAIR_2 = ("ghbdtn, rfr ltkf?", "привет, как дела?")

BG = "#0d0d0f"
INK = "#f0f0f0"
DIM = "#9a9aa2"
MUTE = "#6f6f78"
ACCENT = "#0272ed"
PANE = "#1a1a1e"
LINE = "#2a2a30"


def flip(before: str, after: str, el_id: str, cls: str, attrs: str) -> str:
    """Символы в двух слоях: .a — как набралось, .b — как должно быть."""
    cells = []
    for a, b in zip(before.ljust(len(after)), after.ljust(len(before))):
        a_d = "&nbsp;" if a == " " else html.escape(a)
        b_d = "&nbsp;" if b == " " else html.escape(b)
        cells.append(
            f'<span class="cell" data-layout-allow-overlap>'
            f'<span class="a">{a_d}</span>'
            f'<span class="b" data-layout-allow-overlap>{b_d}</span></span>'
        )
    return f'<div id="{el_id}" class="{cls} flip" {attrs}>' + "".join(cells) + "</div>"


N_BS = len(PAIR_1[0])  # 12 — столько backspace приходится жать руками

# Ширину строки считаем ЗДЕСЬ, а не в браузере: рендер идёт параллельными
# воркерами, каждый инициализирует твины сам, и функция-значение дала бы
# разную позицию каретки в разных кусках видео (линтер это и ловит).
# JetBrains Mono — моноширинный, advance = 0.6em, плюс letter-spacing -2px.
CARET_TRAVEL = round(N_BS * (104 * 0.6 - 2), 1)

HTML = f"""<!doctype html>
<html lang="ru">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <script src="gsap.min.js"></script>
    <style>
      @font-face {{ font-family: "Oswald"; font-weight: 700; src: url("fonts/Oswald-700-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "Oswald"; font-weight: 700; src: url("fonts/Oswald-700-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "Oswald"; font-weight: 500; src: url("fonts/Oswald-500-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "Oswald"; font-weight: 500; src: url("fonts/Oswald-500-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "JB"; font-weight: 700; src: url("fonts/JetBrainsMono-700-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "JB"; font-weight: 700; src: url("fonts/JetBrainsMono-700-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}
      @font-face {{ font-family: "JB"; font-weight: 400; src: url("fonts/JetBrainsMono-400-cyrillic.woff2") format("woff2"); unicode-range: U+0400-04FF; }}
      @font-face {{ font-family: "JB"; font-weight: 400; src: url("fonts/JetBrainsMono-400-latin.woff2") format("woff2"); unicode-range: U+0000-00FF, U+2000-206F; }}

      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: {BG}; }}
      #root {{ position: relative; width: 1920px; height: 1080px; }}

      /* окно macOS — узнаваемая рамка продукта */
      #win {{
        position: absolute; left: 160px; top: 250px; width: 1600px; height: 430px;
        background: {PANE}; border: 2px solid {LINE}; border-radius: 10px;
      }}
      #bar {{ position: absolute; left: 0; top: 0; width: 100%; height: 60px; border-bottom: 2px solid {LINE}; }}
      .dot {{ position: absolute; top: 22px; width: 16px; height: 16px; border-radius: 50%; background: {LINE}; }}
      #d1 {{ left: 26px; }} #d2 {{ left: 56px; }} #d3 {{ left: 86px; }}
      #wtitle {{
        position: absolute; left: 0; top: 18px; width: 100%; text-align: center;
        font-family: "JB", monospace; font-size: 24px; letter-spacing: 4px; color: {MUTE};
      }}

      .flip {{ position: absolute; left: 70px; white-space: nowrap; font-family: "JB", monospace; font-weight: 700; }}
      .cell {{ position: relative; display: inline-block; }}
      .cell .a, .cell .b {{ display: inline-block; }}
      .cell .b {{ position: absolute; left: 0; top: 0; }}
      #flip1 {{ top: 170px; font-size: 104px; letter-spacing: -2px; color: {INK}; }}
      #flip2 {{ top: 170px; font-size: 84px; letter-spacing: -2px; color: {INK}; }}
      #caret {{
        position: absolute; left: 70px; top: 178px; width: 8px; height: 104px;
        background: {ACCENT};
      }}

      .over {{
        position: absolute; left: 160px;
        font-family: "Oswald", sans-serif; font-weight: 700; text-transform: uppercase;
        color: {INK}; letter-spacing: -1px;
      }}
      #hook {{ top: 130px; font-size: 62px; }}
      #steps {{
        position: absolute; left: 160px; top: 740px;
        font-family: "Oswald", sans-serif; font-weight: 500; font-size: 54px; color: {DIM};
      }}
      #steps b {{ color: {INK}; font-weight: 700; }}
      #bscount {{
        position: absolute; right: 160px; top: 700px; text-align: right;
        font-family: "JB", monospace; font-weight: 700; font-size: 150px;
        color: {ACCENT}; font-variant-numeric: tabular-nums; line-height: 1;
      }}
      #bslabel {{
        position: absolute; right: 160px; top: 870px; text-align: right;
        font-family: "JB", monospace; font-size: 30px; letter-spacing: 6px; color: {MUTE};
        text-transform: uppercase;
      }}

      /* клавиши */
      .key {{
        position: absolute; top: 740px; height: 92px; min-width: 92px;
        border: 3px solid {ACCENT}; border-radius: 8px; color: {ACCENT};
        font-family: "JB", monospace; font-weight: 700; font-size: 40px;
        display: flex; align-items: center; justify-content: center; padding: 0 26px;
      }}
      #k1 {{ left: 160px; }} #k2 {{ left: 286px; }}
      #ktext {{
        position: absolute; left: 430px; top: 758px;
        font-family: "Oswald", sans-serif; font-weight: 500; font-size: 52px; color: {DIM};
      }}

      /* финал */
      #icon {{ position: absolute; left: 160px; top: 330px; width: 200px; height: 200px; }}
      #brand {{
        position: absolute; left: 410px; top: 336px;
        font-family: "Oswald", sans-serif; font-weight: 700; font-size: 104px;
        letter-spacing: -3px; line-height: 0.92; color: {INK}; text-transform: uppercase;
      }}
      #brand em {{ font-style: normal; color: {ACCENT}; }}
      #promise {{
        position: absolute; left: 165px; top: 610px;
        font-family: "Oswald", sans-serif; font-weight: 500; font-size: 58px; color: {DIM};
      }}
      #url {{
        position: absolute; left: 168px; top: 720px;
        font-family: "JB", monospace; font-size: 34px; letter-spacing: 5px; color: {MUTE};
      }}
      #rule {{ position: absolute; left: 160px; top: 270px; width: 1600px; height: 5px; background: {ACCENT}; transform-origin: left center; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="17"
         data-width="1920" data-height="1080">

      <!-- сцены 1-3: окно с набором -->
      <div id="hook" class="over clip" data-start="0" data-duration="6.4" data-track-index="0">ты печатаешь быстро</div>
      <div id="win" class="clip" data-start="0" data-duration="13" data-track-index="1">
        <div id="bar">
          <span class="dot" id="d1"></span><span class="dot" id="d2"></span><span class="dot" id="d3"></span>
          <div id="wtitle">сообщение</div>
        </div>
        {flip(PAIR_1[0], PAIR_1[1], "flip1", "clip", 'data-start="0" data-duration="9.4" data-track-index="2"')}
        {flip(PAIR_2[0], PAIR_2[1], "flip2", "clip", 'data-start="9.6" data-duration="3.4" data-track-index="3"')}
        <div id="caret" class="clip" data-start="0" data-duration="2.6" data-track-index="4"></div>
      </div>

      <!-- сцена 2: цена ручного исправления -->
      <div id="steps" class="clip" data-start="3.4" data-duration="3.0" data-track-index="5">стереть <b>·</b> переключить <b>·</b> набрать заново</div>
      <div id="bscount" class="clip" data-start="3.6" data-duration="2.8" data-track-index="6">0</div>
      <div id="bslabel" class="clip" data-start="3.8" data-duration="2.6" data-track-index="7">раз backspace</div>

      <!-- сцена 3: двойной shift -->
      <div id="k1" class="key clip" data-start="6.6" data-duration="2.8" data-track-index="8">⇧</div>
      <div id="k2" class="key clip" data-start="6.6" data-duration="2.8" data-track-index="9">⇧</div>
      <div id="ktext" class="clip" data-start="6.8" data-duration="2.6" data-track-index="10">двойной shift — и всё</div>

      <!-- финал -->
      <div id="rule" class="clip" data-start="13.2" data-duration="3.8" data-track-index="11"></div>
      <img id="icon" class="clip" data-start="13.3" data-duration="3.7" data-track-index="12" src="icon.png" alt="" />
      <div id="brand" class="clip" data-start="13.4" data-duration="3.6" data-track-index="13">Qwerty<br /><em>Switcher</em></div>
      <div id="promise" class="clip" data-start="14.2" data-duration="2.8" data-track-index="14">раскладка больше не ваша проблема</div>
      <div id="url" class="clip" data-start="14.8" data-duration="2.2" data-track-index="15">shulgin.is-a.dev/store</div>
    </div>

    <script>
      window.__timelines = window.__timelines || {{}};
      const tl = gsap.timeline({{ paused: true }});
      const cells = (id) => gsap.utils.toArray("#" + id + " .cell");
      const c1 = cells("flip1"), c2 = cells("flip2");
      gsap.set("#flip1 .b, #flip2 .b", {{ yPercent: 115, opacity: 0 }});

      /* сцена 1 — окно и набор */
      tl.from("#win", {{ y: 40, opacity: 0, duration: 0.6, ease: "power3.out" }}, 0);
      tl.from("#hook", {{ y: 40, opacity: 0, duration: 0.5, ease: "power3.out" }}, 0.15);
      tl.from(c1.map((c) => c.querySelector(".a")), {{
        opacity: 0, duration: 0.01, stagger: 0.052, ease: "none",
      }}, 0.55);
      // каретка идёт за набором и мигает
      tl.to("#caret", {{ x: {CARET_TRAVEL}, duration: 0.624, ease: "none" }}, 0.55);
      tl.to("#caret", {{ opacity: 0, duration: 0.18, repeat: 5, yoyo: true, ease: "none" }}, 1.3);

      /* сцена 2 — сколько стоит починить руками */
      tl.from("#steps", {{ y: 34, opacity: 0, duration: 0.45, ease: "power3.out" }}, 3.45);
      const bs = {{ n: 0 }};
      tl.to(bs, {{
        n: {N_BS}, duration: 1.1, ease: "power2.out",
        onUpdate: () => {{ document.querySelector("#bscount").textContent = Math.round(bs.n); }},
      }}, 3.65);
      tl.from("#bslabel", {{ opacity: 0, duration: 0.4 }}, 4.0);

      /* сцена 3 — двойной shift, перещёлкивание */
      tl.from("#k1", {{ y: 26, opacity: 0, duration: 0.28, ease: "power3.out" }}, 6.65);
      tl.from("#k2", {{ y: 26, opacity: 0, duration: 0.28, ease: "power3.out" }}, 6.78);
      tl.from("#ktext", {{ x: -24, opacity: 0, duration: 0.4, ease: "power3.out" }}, 6.9);
      tl.to(c1.map((c) => c.querySelector(".a")), {{
        yPercent: -115, opacity: 0, duration: 0.32, stagger: 0.026, ease: "power3.in",
      }}, 7.15);
      tl.to(c1.map((c) => c.querySelector(".b")), {{
        yPercent: 0, opacity: 1, duration: 0.36, stagger: 0.026, ease: "power3.out",
      }}, 7.22);
      tl.to("#wtitle", {{ color: "{ACCENT}", duration: 0.2 }}, 7.3);

      /* сцена 4 — вторая фраза, уже без объяснений */
      tl.from(c2.map((c) => c.querySelector(".a")), {{
        opacity: 0, duration: 0.01, stagger: 0.026, ease: "none",
      }}, 9.65);
      tl.to(c2.map((c) => c.querySelector(".a")), {{
        yPercent: -115, opacity: 0, duration: 0.28, stagger: 0.014, ease: "power3.in",
      }}, 10.85);
      tl.to(c2.map((c) => c.querySelector(".b")), {{
        yPercent: 0, opacity: 1, duration: 0.32, stagger: 0.014, ease: "power3.out",
      }}, 10.9);

      /* финал */
      tl.from("#rule", {{ scaleX: 0, duration: 0.6, ease: "power3.out" }}, 13.25);
      tl.from("#icon", {{ y: 40, opacity: 0, duration: 0.5, ease: "power3.out" }}, 13.35);
      tl.from("#brand", {{ y: 60, opacity: 0, duration: 0.6, ease: "power3.out" }}, 13.45);
      tl.from("#promise", {{ y: 30, opacity: 0, duration: 0.5, ease: "power3.out" }}, 14.25);
      tl.from("#url", {{ opacity: 0, duration: 0.45 }}, 14.85);

      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(HTML)
print(f"написано: {OUT} ({len(HTML)} байт), backspace в кадре: {N_BS}")
