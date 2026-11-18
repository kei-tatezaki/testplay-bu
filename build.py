#!/usr/bin/env python3
"""テストプレイ部のサイトを games.json から生成する。

使い方:
    BASE_URL=https://ユーザー名.github.io/リポジトリ名 python3 build.py

作品を追加するときは games.json に1件足して、もう一度実行するだけ。
- index.html          作品が縦に並ぶ一覧（スクロールで見る）
- games/<slug>/       作品ごとのページ（Discordに貼るとこのページの画像とタイトルが出る）
- og/<slug>.png       Discordのプレビュー用の画像（自動で作る）
"""
import html
import json
import os
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
BASE = os.environ.get("BASE_URL", "").rstrip("/")
DISCORD_INVITE = os.environ.get("DISCORD_INVITE", "")
FONT_BOLD = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
FONT_REG = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"

e = html.escape


def youtube_id(url):
    m = re.search(r"(?:v=|youtu\.be/|shorts/|embed/)([\w-]{11})", url or "")
    return m.group(1) if m else ""


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def is_dark(h):
    r, g, b = hex_rgb(h)
    return (0.299 * r + 0.587 * g + 0.114 * b) < 128


def font(path, size):
    try:
        return ImageFont.truetype(path, size, index=0)
    except OSError:
        return ImageFont.load_default()


def make_og(game, out):
    """1200x630のプレビュー画像。タイトル・一言・タグだけのシンプルなカード。"""
    W, H = 1200, 630
    bg = game.get("bg") or "#14181f"
    accent = game.get("color") or "#7fe0c9"
    ink = (240, 243, 247) if is_dark(bg) else (30, 28, 25)
    muted = (150, 160, 175) if is_dark(bg) else (110, 104, 95)
    im = Image.new("RGB", (W, H), hex_rgb(bg))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 24, H], fill=hex_rgb(accent))
    d.text((80, 70), "テストプレイ部", font=font(FONT_BOLD, 34), fill=muted)
    title = game["title"]
    size = 96 if len(title) <= 10 else 72
    d.text((80, 150), title, font=font(FONT_BOLD, size), fill=ink)
    # 一言を2行まで折り返す
    f = font(FONT_REG, 38)
    line, lines = "", []
    for ch in game.get("oneliner", ""):
        if d.textlength(line + ch, font=f) > W - 160:
            lines.append(line)
            line = ch
        else:
            line += ch
    if line:
        lines.append(line)
    for i, ln in enumerate(lines[:2]):
        d.text((80, 300 + i * 56), ln, font=f, fill=ink)
    chips = [game.get("stage", ""), "確かめたい：" + game.get("check", ""), game.get("minutes", "")]
    x = 80
    cf = font(FONT_BOLD, 30)
    for c in [c for c in chips if c and c != "確かめたい："]:
        w = d.textlength(c, font=cf) + 48
        d.rounded_rectangle([x, 470, x + w, 530], radius=30, outline=hex_rgb(accent), width=3)
        d.text((x + 24, 480), c, font=cf, fill=ink)
        x += w + 16
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, optimize=True)


def make_site_og(out):
    W, H = 1200, 630
    im = Image.new("RGB", (W, H), (16, 20, 28))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 24, H], fill=(127, 224, 201))
    d.text((80, 180), "テストプレイ部", font=font(FONT_BOLD, 110), fill=(240, 243, 247))
    d.text((80, 340), "学生のゲームを、5分でつまみ食い。", font=font(FONT_REG, 48), fill=(200, 208, 220))
    d.text((80, 420), "遊んで、一言感想を送り合う場所", font=font(FONT_REG, 36), fill=(150, 160, 175))
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, optimize=True)


def media_html(g, prefix):
    yt = youtube_id(g.get("youtube"))
    if g.get("clip"):
        return f'<video class="media" src="{prefix}{e(g["clip"])}" autoplay muted loop playsinline poster="{prefix}og/{e(g["slug"])}.png"></video>'
    if yt:
        return (f'<div class="media yt"><iframe src="https://www.youtube-nocookie.com/embed/{yt}" '
                f'title="{e(g["title"])} のPV" loading="lazy" allow="encrypted-media; picture-in-picture" allowfullscreen></iframe></div>')
    return f'<img class="media" src="{prefix}og/{e(g["slug"])}.png" alt="{e(g["title"])}" loading="lazy">'


def chips_html(g):
    out = []
    if g.get("sample"):
        out.append('<span class="chip sample">運営サンプル</span>')
    for k in ("stage", "genre", "minutes"):
        if g.get(k):
            out.append(f'<span class="chip">{e(g[k])}</span>')
    if g.get("check"):
        out.append(f'<span class="chip check">確かめたい：{e(g["check"])}</span>')
    return "".join(out)


CSS = """
:root{--bg:#f3f4f1;--card:#fff;--ink:#1d2430;--muted:#5d6675;--line:#d9ddd8;--accent:#1f6f6a;--accent-ink:#fff;--soft:#e7efee;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#12161c;--card:#1b2129;--ink:#e7eaee;--muted:#9aa3ae;--line:#2c343e;--accent:#4fb3aa;--accent-ink:#0d1714;--soft:#1f2e2d;color-scheme:dark}}
*{box-sizing:border-box}html,body{margin:0}
body{background:var(--bg);color:var(--ink);font-family:"Hiragino Sans","Yu Gothic","Noto Sans JP",system-ui,sans-serif;line-height:1.7}
a{color:var(--accent)}
.wrap{max-width:640px;margin:0 auto;padding:20px 16px 64px;display:grid;gap:20px}
header h1{margin:0;font-size:30px;letter-spacing:.04em}
header p{margin:4px 0 0;color:var(--muted)}
.filters{display:flex;flex-wrap:wrap;gap:8px}
.filters button{font:inherit;font-size:13px;border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:999px;padding:4px 14px;cursor:pointer}
.filters button[aria-pressed="true"]{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:grid}
.media{display:block;width:100%;aspect-ratio:1200/630;object-fit:cover;background:#000;border:0}
.yt{position:relative}.yt iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
.body{padding:16px;display:grid;gap:10px}
.body h2{margin:0;font-size:21px;line-height:1.4}
.one{margin:0}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:1px 10px;color:var(--muted)}
.chip.check{border-color:var(--accent);color:var(--accent)}
.chip.sample{background:var(--soft);border-color:transparent;color:var(--accent)}
.q{background:var(--soft);border-radius:10px;padding:10px 12px;font-size:14px}
.q b{display:block;font-size:12px;color:var(--accent)}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.btn{display:inline-flex;align-items:center;gap:6px;border-radius:10px;padding:10px 18px;background:var(--accent);color:var(--accent-ink);font-weight:700;text-decoration:none}
.btn.ghost{background:transparent;color:var(--ink);border:1px solid var(--line);font-weight:500}
.by{font-size:13px;color:var(--muted)}
ul.hl{margin:0;padding-left:1.2em}
footer{color:var(--muted);font-size:13px;text-align:center}
.empty{color:var(--muted);text-align:center;padding:24px}
"""


def page(title, desc, url, image, body, prefix):
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="テストプレイ部">
<meta property="og:title" content="{e(title)}">
<meta property="og:description" content="{e(desc)}">
<meta property="og:url" content="{e(url)}">
<meta property="og:image" content="{e(image)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#1f6f6a">
<link rel="stylesheet" href="{prefix}assets/style.css">
</head>
<body>
{body}
</body>
</html>
"""


def discord_link(g):
    link = g.get("discord") or DISCORD_INVITE
    return f'<a class="btn ghost" href="{e(link)}">Discordで感想を送る</a>' if link else ""


def card(g, prefix):
    return f"""<article class="card" data-check="{e(g.get('check',''))}">
{media_html(g, prefix)}
<div class="body">
<h2>{e(g['title'])}</h2>
<div class="chips">{chips_html(g)}</div>
<p class="one">{e(g['oneliner'])}</p>
{f'<div class="q"><b>作者が確かめたいこと</b>{e(g["question"])}</div>' if g.get('question') else ''}
<div class="row"><a class="btn" href="{prefix}{e(g['play'])}">▶ 遊ぶ</a><a class="btn ghost" href="{prefix}games/{e(g['slug'])}/">くわしく見る</a>{discord_link(g)}</div>
<div class="by">by {e(g['author'])}{f' ・ <a href="https://x.com/{e(g["x"].lstrip("@"))}">@{e(g["x"].lstrip("@"))}</a>' if g.get('x') else ''}</div>
</div>
</article>"""


def build():
    games = json.loads((ROOT / "games.json").read_text(encoding="utf-8"))
    (ROOT / "assets").mkdir(exist_ok=True)
    (ROOT / "assets/style.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    make_site_og(ROOT / "og/site.png")
    checks = sorted({g.get("check") for g in games if g.get("check")})

    for g in games:
        make_og(g, ROOT / f"og/{g['slug']}.png")
        hl = "".join(f"<li>{e(h)}</li>" for h in g.get("highlights", []))
        body = f"""<div class="wrap">
<a href="../../">← テストプレイ部の作品一覧</a>
<article class="card">
{media_html(g, '../../')}
<div class="body">
<h2>{e(g['title'])}</h2>
<div class="chips">{chips_html(g)}</div>
<p class="one">{e(g['oneliner'])}</p>
{f'<div><b>見どころ</b><ul class="hl">{hl}</ul></div>' if hl else ''}
{f'<div class="q"><b>作者が確かめたいこと</b>{e(g["question"])}</div>' if g.get('question') else ''}
<div class="row"><a class="btn" href="../../{e(g['play'])}">▶ 遊ぶ</a>{discord_link(g)}</div>
<div class="by">by {e(g['author'])}{f' ・ <a href="https://x.com/{e(g["x"].lstrip("@"))}">@{e(g["x"].lstrip("@"))}</a>' if g.get('x') else ''}</div>
</div>
</article>
<footer>感想は一言でOK：🐛バグ／🤔違和感／😆楽しかった／😴やめたくなった</footer>
</div>"""
        out = ROOT / f"games/{g['slug']}/index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page(f"{g['title']}｜テストプレイ部", g["oneliner"], f"{BASE}/games/{g['slug']}/",
                            f"{BASE}/og/{g['slug']}.png", body, "../../"), encoding="utf-8")

    filters = '<button type="button" aria-pressed="true" data-f="">すべて</button>' + "".join(
        f'<button type="button" aria-pressed="false" data-f="{e(c)}">確かめたい：{e(c)}</button>' for c in checks)
    cards = "\n".join(card(g, "") for g in reversed(games))
    body = f"""<div class="wrap">
<header><h1>テストプレイ部</h1><p>学生のゲームを、5分でつまみ食い。気になったら遊んで、一言感想を送ろう。</p></header>
<nav class="filters" aria-label="絞り込み">{filters}</nav>
<main id="list" style="display:grid;gap:20px">
{cards}
</main>
<p class="empty" id="empty" hidden>この条件の作品はまだありません。</p>
<footer>登録なしで遊べます ・ 感想は任意 ・ {len(games)}作品</footer>
</div>
<script>
document.querySelectorAll('.filters button').forEach(b=>b.addEventListener('click',()=>{{
 document.querySelectorAll('.filters button').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));
 const f=b.dataset.f;let n=0;
 document.querySelectorAll('#list .card').forEach(c=>{{const show=!f||c.dataset.check===f;c.hidden=!show;if(show)n++;}});
 document.getElementById('empty').hidden=n>0;
}}));
</script>"""
    (ROOT / "index.html").write_text(page("テストプレイ部｜学生のゲームを5分でつまみ食い",
                                          "学生のゲームを、5分でつまみ食い。遊んで、一言感想を送り合う場所。",
                                          f"{BASE}/", f"{BASE}/og/site.png", body, ""), encoding="utf-8")
    (ROOT / ".nojekyll").write_text("", encoding="utf-8")
    print(f"built {len(games)} games -> {ROOT}")


if __name__ == "__main__":
    build()
