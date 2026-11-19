#!/usr/bin/env python3
"""テストプレイ部のサイトを games.json から生成する。

使い方:
    BASE_URL=https://ユーザー名.github.io/リポジトリ名 python3 build.py

作品を追加するときは games.json に1件足して、もう一度実行するだけ。
- index.html          ショート風のフィード（上下スワイプで1作品ずつ）
- list.html           作品が縦に並ぶ一覧
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
# 公開してよいキー（publishable）。データベース側のルールで守っている
SB_URL = os.environ.get("SB_URL", "https://jwrzqaxuvmdbroemenng.supabase.co")
SB_KEY = os.environ.get("SB_KEY", "sb_publishable_eEHa90AqCPKyQuo7jjMasA_sGbpPh2u")
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
    d.text((80, 180), "テストプレイ部", font=font(FONT_BOLD, 96), fill=(240, 243, 247))
    d.text((80, 330), "学生のゲームを、", font=font(FONT_REG, 44), fill=(200, 208, 220))
    d.text((80, 385), "5分でつまみ食い。", font=font(FONT_REG, 44), fill=(200, 208, 220))
    d.text((80, 470), "遊んで、一言感想を送り合う場所", font=font(FONT_REG, 32), fill=(150, 160, 175))
    icon = ROOT / "assets/icon-512.png"
    if icon.exists():
        ic = Image.open(icon).convert("RGB").resize((360, 360))
        mask = Image.new("L", (360, 360), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, 359, 359), fill=255)
        im.paste(ic, (W - 360 - 70, (H - 360) // 2), mask)
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


PLATFORM = {"pc": "PCのみ", "sp": "スマホのみ", "both": "PC・スマホ"}


def chips_html(g):
    out = []
    if g.get("platform") in PLATFORM:
        out.append(f'<span class="chip plat">{PLATFORM[g["platform"]]}</span>')
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
.thumb{position:relative;display:block}
.thumb-play{position:absolute;right:10px;bottom:10px;background:#000b;color:#fff;font-size:13px;font-weight:700;padding:5px 11px;border-radius:999px}
.yt{position:relative}.yt iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
.body{padding:16px;display:grid;gap:10px}
.body h2{margin:0;font-size:21px;line-height:1.4}
.one{margin:0}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{font-size:12px;border:1px solid var(--line);border-radius:999px;padding:1px 10px;color:var(--muted)}
.chip.check{border-color:var(--accent);color:var(--accent)}
.chip.plat{border-color:var(--ink);color:var(--ink)}
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
.wrap.wide{max-width:1180px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:16px;align-items:start}
.grid .card .body{gap:8px;padding:14px}
.grid .card h2{font-size:17px}
.grid .q{font-size:13px}
.grid .btn{padding:8px 14px;font-size:14px}
.fblist{display:grid;gap:10px}
.upd{border:1px solid var(--accent);border-radius:10px;padding:10px 12px;font-size:14px}
.upd b{display:block;font-size:12px;color:var(--accent)}
.fbitem{border-top:1px solid var(--line);padding-top:10px;font-size:14px;display:grid;gap:2px}
.fbitem p{margin:4px 0 0;white-space:pre-wrap}
"""


# 「▶ 遊ぶ」を押したらデータベースに記録する（フィードと同じ client_id を使う）
TRACK_JS = """<script>
document.addEventListener('click',function(ev){
 var a=ev.target.closest&&ev.target.closest('a[data-play]'); if(!a) return;
 try{
  var cid=JSON.parse(localStorage.getItem('tpb:cid')||'""');
  if(!cid){cid=(crypto.randomUUID?crypto.randomUUID():String(Math.random()).slice(2)+Date.now());localStorage.setItem('tpb:cid',JSON.stringify(cid))}
  var played=JSON.parse(localStorage.getItem('tpb:played')||'[]'); if(played.indexOf(a.dataset.play)<0){played.push(a.dataset.play);localStorage.setItem('tpb:played',JSON.stringify(played))}
  fetch('""" + SB_URL + """/rest/v1/game_events',{method:'POST',keepalive:true,headers:{apikey:'""" + SB_KEY + """','Content-Type':'application/json',Prefer:'return=minimal'},body:JSON.stringify({game_slug:a.dataset.play,kind:'play',client_id:cid})}).catch(function(){});
 }catch(e){}
});
</script>"""


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
<link rel="icon" type="image/png" sizes="32x32" href="{prefix}assets/icon-32.png">
<link rel="icon" type="image/png" sizes="192x192" href="{prefix}assets/icon-192.png">
<link rel="apple-touch-icon" href="{prefix}assets/icon-180.png">
<link rel="manifest" href="{prefix}manifest.webmanifest">
<link rel="stylesheet" href="{prefix}assets/style.css">
</head>
<body>
{body}
{TRACK_JS}
</body>
</html>
"""


def discord_link(g, prefix=""):
    # 感想はサイトの感想シートで送る（フィードの該当作品を開いてシートを出す）
    return f'<a class="btn ghost" href="{prefix}./#fb-{e(g["slug"])}">💬 感想を送る</a>'



def card(g, prefix):
    return f"""<article class="card" data-check="{e(g.get('check',''))}" data-plat="{e(g.get('platform','both'))}">
<a class="thumb" href="{prefix}./?g={e(g['slug'])}" aria-label="{e(g['title'])}をショートで見る">{media_html(g, prefix)}<span class="thumb-play">▶ ショートで見る</span></a>
<div class="body">
<h2>{e(g['title'])}</h2>
<div class="chips">{chips_html(g)}</div>
<p class="one">{e(g['oneliner'])}</p>
{f'<div class="q"><b>作者が確かめたいこと</b>{e(g["question"])}</div>' if g.get('question') else ''}
<div class="row"><a class="btn" data-play="{e(g['slug'])}" href="{prefix}{e(g['play'])}">▶ 遊ぶ</a><a class="btn ghost" href="{prefix}games/{e(g['slug'])}/">くわしく見る</a>{discord_link(g)}</div>
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
<a href="../../list.html">← まとめに戻る</a>
<article class="card">
{media_html(g, '../../')}
<div class="body">
<h2>{e(g['title'])}</h2>
<div class="chips">{chips_html(g)}</div>
<p class="one">{e(g['oneliner'])}</p>
{f'<div><b>見どころ</b><ul class="hl">{hl}</ul></div>' if hl else ''}
{f'<div class="by">操作：{e(g["controls"])}</div>' if g.get('controls') else ''}
{f'<div class="q"><b>作者が確かめたいこと</b>{e(g["question"])}</div>' if g.get('question') else ''}
{''.join(f'<div class="upd"><b>感想でアップデート（{e(u["date"])}）</b>{e(u["text"])}</div>' for u in g.get('updates', []))}
<div class="row"><a class="btn" data-play="{e(g['slug'])}" href="../../{e(g['play'])}">▶ 遊ぶ</a>{discord_link(g, '../../')}</div>
<div class="by">by {e(g['author'])}{f' ・ <a href="https://x.com/{e(g["x"].lstrip("@"))}">@{e(g["x"].lstrip("@"))}</a>' if g.get('x') else ''}</div>
</div>
</article>
<section class="card"><div class="body"><h2>みんなの感想</h2><div id="fbsum" class="by"></div><div id="fb" class="fblist">読み込み中…</div></div></section>
<footer>感想はトップのフィードの「💬感想」から送れます</footer>
</div>
<script>
(async function(){{
 const box=document.getElementById('fb'), sum=document.getElementById('fbsum');
 const esc=t=>String(t??'').replace(/[&<>"]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}})[c]);
 try{{
  const r=await fetch('{SB_URL}/rest/v1/feedback?select=again,reach,stop_at,good,bad,answer,free,is_dev,liked_by_dev,created_at&game_slug=eq.{g['slug']}&order=created_at.desc&limit=100',{{headers:{{apikey:'{SB_KEY}'}}}});
  const rows=await r.json();
  if(!Array.isArray(rows)||!rows.length){{box.textContent='まだ感想はありません。最初の感想を送ってみよう！';return}}
  const much=rows.filter(x=>x.again==='すごく遊びたい').length, end=rows.filter(x=>x.reach==='最後まで').length;
  sum.textContent=rows.length+'件 ・ 「すごく遊びたい」'+Math.round(much/rows.length*100)+'% ・ 最後まで遊んだ '+Math.round(end/rows.length*100)+'%';
  box.innerHTML=rows.map(x=>'<div class="fbitem">'+(x.liked_by_dev?'<span class="chip check">作者のいいね</span> ':'')+(x.is_dev?'<span class="chip">開発者</span> ':'')+'<b>'+esc(x.again)+'</b> ・ '+esc(x.reach)+(x.stop_at?'（'+esc(x.stop_at)+'）':'')+(x.good.length?'<div>よかった：'+x.good.map(esc).join('、')+'</div>':'')+(x.bad.length?'<div>気になった：'+x.bad.map(esc).join('、')+'</div>':'')+(x.answer?'<div>作者の質問：'+esc(x.answer)+'</div>':'')+(x.free?'<p>'+esc(x.free)+'</p>':'')+'<div class="by">'+new Date(x.created_at).toLocaleDateString('ja-JP')+'</div></div>').join('');
 }}catch(e){{box.textContent='感想を読み込めませんでした'}}
}})();
</script>"""
        out = ROOT / f"games/{g['slug']}/index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page(f"{g['title']}｜テストプレイ部", g["oneliner"], f"{BASE}/games/{g['slug']}/",
                            f"{BASE}/og/{g['slug']}.png", body, "../../"), encoding="utf-8")

    filters = '<button type="button" aria-pressed="true" data-f="">すべて</button>' + "".join(
        f'<button type="button" aria-pressed="false" data-f="{e(c)}">確かめたい：{e(c)}</button>' for c in checks)
    cards = "\n".join(card(g, "") for g in reversed(games))
    body = f"""<div class="wrap wide">
<header><h1>テストプレイ部 まとめ</h1><p>学生のゲームを、5分でつまみ食い。気になったら遊んで、一言感想を送ろう。</p><p><a class="btn" href="./">▶ ショートで見る</a></p></header>
<nav class="filters" aria-label="絞り込み">{filters}</nav>
<nav class="filters" aria-label="端末で絞り込み"><button type="button" aria-pressed="true" data-p="">どの端末でも</button><button type="button" aria-pressed="false" data-p="pc">PCで遊べる</button><button type="button" aria-pressed="false" data-p="sp">スマホで遊べる</button></nav>
<main id="list" class="grid">
{cards}
</main>
<p class="empty" id="empty" hidden>この条件の作品はまだありません。</p>
<footer>登録なしで遊べます ・ 感想は任意 ・ {len(games)}作品</footer>
</div>
<script>
let F='',P='';
function apply(){{let n=0;document.querySelectorAll('#list .card').forEach(c=>{{const pl=c.dataset.plat;const okP=!P||pl==='both'||pl===P;const show=(!F||c.dataset.check===F)&&okP;c.hidden=!show;if(show)n++;}});document.getElementById('empty').hidden=n>0;}}
document.querySelectorAll('.filters button').forEach(b=>b.addEventListener('click',()=>{{
 const nav=b.parentElement; nav.querySelectorAll('button').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));
 if('f' in b.dataset)F=b.dataset.f; else P=b.dataset.p; apply();
}}));
</script>"""
    (ROOT / "list.html").write_text(page("作品一覧｜テストプレイ部",
                                         "学生のゲームを、5分でつまみ食い。遊んで、一言感想を送り合う場所。",
                                         f"{BASE}/list.html", f"{BASE}/og/site.png", body, ""), encoding="utf-8")

    # トップはショート風のフィード
    data = json.dumps(games, ensure_ascii=False).replace("</", "<\\/")
    feed = (ROOT / "feed_template.html").read_text(encoding="utf-8")
    feed = feed.replace("__GAMES__", data).replace("__BASE__", BASE).replace("__SB_URL__", SB_URL).replace("__SB_KEY__", SB_KEY).replace(
        "__DISCORD__", DISCORD_INVITE or "https://discord.com/channels/1572684471348498582/1572684778858348624")
    (ROOT / "index.html").write_text(feed, encoding="utf-8")
    (ROOT / ".nojekyll").write_text("", encoding="utf-8")
    (ROOT / "manifest.webmanifest").write_text(json.dumps({
        "name": "テストプレイ部", "short_name": "テストプレイ部", "start_url": "./", "display": "standalone",
        "background_color": "#0b0e13", "theme_color": "#1f6f6a",
        "icons": [{"src": "assets/icon-192.png", "sizes": "192x192", "type": "image/png"},
                  {"src": "assets/icon-512.png", "sizes": "512x512", "type": "image/png"}]}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"built {len(games)} games -> {ROOT}")


if __name__ == "__main__":
    build()
