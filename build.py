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
DISCORD_INVITE = "https://discord.gg/NXYSmu4rAY"  # 期限なしの招待リンク
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
    # ゲーム画面の画像（shots/<slug>.png）があれば右に置く
    shot = ROOT / f"shots/{game['slug']}.png"
    TW = W - 160
    if shot.exists():
        sh = Image.open(shot).convert("RGB")
        sh.thumbnail((430, 510), Image.LANCZOS)
        sx, sy = W - 60 - sh.width, (H - sh.height) // 2
        mask = Image.new("L", sh.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, sh.width - 1, sh.height - 1], radius=18, fill=255)
        d.rounded_rectangle([sx - 4, sy - 4, sx + sh.width + 3, sy + sh.height + 3], radius=22, fill=hex_rgb(accent))
        im.paste(sh, (sx, sy), mask)
        TW = sx - 80 - 40
    title = game["title"]
    size = 96 if len(title) <= 10 else 72
    while size > 40 and d.textlength(title, font=font(FONT_BOLD, size)) > TW:
        size -= 4
    d.text((80, 150 + (96 - size) // 2), title, font=font(FONT_BOLD, size), fill=ink)
    # 一言を2行まで折り返す
    f = font(FONT_REG, 38)
    line, lines = "", []
    for ch in game.get("oneliner", ""):
        if d.textlength(line + ch, font=f) > TW:
            lines.append(line)
            line = ch
        else:
            line += ch
    if line:
        lines.append(line)
    maxl = 2 if TW > 800 else 3
    if len(lines) > maxl:
        lines = lines[:maxl]
        lines[-1] = lines[-1][:-1] + "…"
    for i, ln in enumerate(lines):
        d.text((80, (300 if TW > 800 else 270) + i * 56), ln, font=f, fill=ink)
    chips = [game.get("stage", ""), "確かめたい：" + game.get("check", ""), game.get("minutes", "")]
    x = 80
    cf = font(FONT_BOLD, 30)
    for c in [c for c in chips if c and c != "確かめたい："]:
        w = d.textlength(c, font=cf) + 48
        if x + w > 80 + TW:
            break
        d.rounded_rectangle([x, 470, x + w, 530], radius=30, outline=hex_rgb(accent), width=3)
        d.text((x + 24, 480), c, font=cf, fill=ink)
        x += w + 16
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, optimize=True)


RATING = {"r15": "R15", "r18": "R18"}


def is_r18(g):
    return g.get("rating") == "r18"


def make_r18_og(game, out):
    """R18作品の共通の表紙。作品の画像や動画はサイトに置かない（GitHub Pagesの決まり）。"""
    W, H = 1200, 630
    im = Image.new("RGB", (W, H), (24, 18, 22))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 24, H], fill=(230, 80, 100))
    d.text((80, 70), "テストプレイ部", font=font(FONT_BOLD, 34), fill=(170, 150, 160))
    d.rounded_rectangle([80, 160, 330, 290], radius=24, outline=(230, 80, 100), width=6)
    d.text((112, 172), "R18", font=font(FONT_BOLD, 96), fill=(240, 120, 140))
    d.text((80, 340), "18歳以上向けの作品です", font=font(FONT_BOLD, 56), fill=(240, 236, 238))
    d.text((80, 430), "作品ページで年齢を確認してから表示します", font=font(FONT_REG, 34), fill=(190, 175, 182))
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
    if is_r18(g):
        return f'<img class="media" src="{prefix}og/{e(g["slug"])}.png" alt="18歳以上向けの作品" loading="lazy">'
    yt = youtube_id(g.get("youtube"))
    if g.get("clip"):
        return f'<video class="media" src="{prefix}{e(g["clip"])}" autoplay muted loop playsinline poster="{cover_src(g, prefix)}"></video>'
    if yt:
        return (f'<div class="media yt"><iframe src="https://www.youtube-nocookie.com/embed/{yt}" '
                f'title="{e(g["title"])} のPV" loading="lazy" allow="encrypted-media; picture-in-picture" allowfullscreen></iframe></div>')
    return f'<img class="media" src="{cover_src(g, prefix)}" alt="{e(g["title"])}" loading="lazy">'


PLATFORM = {"pc": "PCのみ", "sp": "スマホのみ", "both": "PC・スマホ"}
CREATORS = json.loads((ROOT / "creators.json").read_text(encoding="utf-8")) if (ROOT / "creators.json").exists() else {}


def cover_src(g, prefix):
    """カードやポスターに使う画像。ゲーム画面の画像（cover）があればそれ、なければ文字だけのカード。R18は共通の表紙。"""
    if g.get("cover") and not is_r18(g):
        return f'{prefix}{e(g["cover"])}'
    return f'{prefix}og/{e(g["slug"])}.png'


def by_html(g, prefix, size=0, cls="by-link", noname=False):
    """作った人（アイコンと名前）。プロフィールがあればリンクにする。data-by は tpb.js が管理ページで決めた作者に差し替える印。"""
    c = CREATORS.get(g.get("creator") or "")
    name = e(c["name"] if c else g.get("author") or "ななし")
    av = ""
    if size:
        if c and c.get("avatar"):
            av = f'<img class="tpb-av" src="{prefix}{e(c["avatar"])}" alt="" width="{size}" height="{size}" style="width:{size}px;height:{size}px" loading="lazy">'
        else:
            av = f'<span class="tpb-av" style="width:{size}px;height:{size}px;font-size:{int(size*.42)}px" aria-hidden="true">{name[:1]}</span>'
    attrs = f'class="{cls}" data-by="{e(g["slug"])}"' + (f' data-size="{size}"' if size else "") + (" data-noname" if noname else "")
    inner = av + ("" if noname else name)
    if c:
        label = f' aria-label="{name} のプロフィール"' if noname else ""
        return f'<a {attrs} href="{prefix}profile.html?u={e(g["creator"])}"{label}>{inner}</a>'
    return f'<span {attrs}>{inner}</span>'


def chips_html(g):
    out = []
    if g.get("rating") in RATING:
        out.append(f'<span class="chip rate-{e(g["rating"])}">{RATING[g["rating"]]}</span>')
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
.wide .filters{flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none;margin:0 -16px;padding:0 16px}
.wide .filters::-webkit-scrollbar{display:none}
.wide .filters button{white-space:nowrap;flex:none}
.bar{display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{min-height:40px;display:flex;align-items:center;gap:8px;font-weight:800;font-size:19px;color:var(--ink);text-decoration:none;letter-spacing:.04em}
.brand img{border-radius:50%}
.bar .btn{padding:7px 14px;font-size:14px}
.bar-r{display:flex;gap:8px;align-items:center;flex:none}
.brand,.ghost-link,.bar .btn{white-space:nowrap}
@media (max-width:420px){.bar,.bar-r{gap:6px}.brand{font-size:14px;gap:6px;letter-spacing:0}.brand img{width:28px;height:28px}.ghost-link,.bar .btn{padding:6px 8px;font-size:12px}.tabs{gap:0}.tabs button{flex:1;padding:10px 4px;font-size:13px}}
.ghost-link{color:var(--ink);font-size:14px;text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:6px 12px}
.lead{margin:-8px 0 0;color:var(--muted);font-size:13px}
.filters button{font:inherit;font-size:13px;border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:999px;padding:4px 14px;cursor:pointer}
.filters button[aria-pressed="true"]{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:grid}
.media{display:block;width:100%;aspect-ratio:1200/630;object-fit:cover;background:#000;border:0}
.thumb{position:relative;display:block}
.rate{position:absolute;left:6px;top:6px;font-size:11px;font-weight:800;line-height:1.6;padding:0 7px;border-radius:4px;color:#fff;background:#b8860b}
.rate.rate-r18{background:#d6405e}
.chip.rate-r15{border-color:#d4a017;color:#d4a017}
.chip.rate-r18{border-color:#e05a74;color:#e05a74;font-weight:700}
video.media{object-fit:contain;background:#0b0e13;aspect-ratio:4/3;max-height:440px}
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
.btn.big{padding:12px 26px;font-size:17px}
.btn.ghost{background:transparent;color:var(--ink);border:1px solid var(--line);font-weight:500}
.by{font-size:13px;color:var(--muted)}
ul.hl{margin:0;padding-left:1.2em}
footer{color:var(--muted);font-size:13px;text-align:center}
.empty{color:var(--muted);text-align:center;padding:24px}
.wrap.wide{max-width:1280px;gap:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:22px 14px;align-items:start}
@media (max-width:560px){.grid{grid-template-columns:1fr 1fr;gap:16px 10px}}
.tile{display:grid;gap:8px;min-width:0}
.tile[hidden]{display:none}
.tile .media{border-radius:12px}
.dur{position:absolute;right:6px;bottom:6px;background:#000c;color:#fff;font-size:11px;font-weight:700;line-height:1.6;padding:0 6px;border-radius:4px}
.meta{display:grid;gap:0;min-width:0}
.meta .t{color:var(--ink);font-weight:700;font-size:15px;line-height:1.4;text-decoration:none;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;margin-bottom:2px}
.meta .by{font-size:12px;line-height:1.55;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meta .by:empty{display:none}
.grid .card .body{gap:8px;padding:14px}
.grid .card h2{font-size:17px}
.grid .q{font-size:13px}
.grid .btn{padding:8px 14px;font-size:14px}
.fblist{display:grid;gap:10px}
.upd{border:1px solid var(--accent);border-radius:10px;padding:10px 12px;font-size:14px}
.upd b{display:block;font-size:12px;color:var(--accent)}
.fbitem{border-top:1px solid var(--line);padding-top:10px;font-size:14px;display:grid;gap:2px}
.fbitem p{margin:4px 0 0;white-space:pre-wrap}
.tpb-av{display:inline-grid;place-items:center;border-radius:50%;object-fit:cover;color:#fff;font-weight:800;flex:none;line-height:1;background:var(--accent)}
.av-link{flex:none;display:block;line-height:0;border-radius:50%}
.by-link{color:inherit;text-decoration:none}
a.by-link:hover{text-decoration:underline}
.byrow{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.by-chip{display:inline-flex;align-items:center;gap:8px;color:var(--ink);text-decoration:none;font-weight:700;font-size:14px;min-height:40px}
a.by-chip:hover{text-decoration:underline}
.meta2{display:flex;gap:10px;align-items:flex-start;min-width:0}
.meta2 .meta{flex:1}
.meta2 h2{min-width:0}
.tabs{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;border-bottom:1px solid var(--line)}
.tabs::-webkit-scrollbar{display:none}
.tabs button{font:inherit;font-size:14px;white-space:nowrap;border:0;background:none;color:var(--muted);padding:10px 12px;cursor:pointer;border-bottom:3px solid transparent;min-height:44px}
.tabs button[aria-selected="true"]{color:var(--ink);font-weight:700;border-bottom-color:var(--accent)}
.phead{display:grid;justify-items:center;text-align:center;gap:8px;padding:8px 0 0}
.phead h1{margin:0;font-size:22px;line-height:1.3}
.phead .handle{color:var(--muted);font-size:13px;margin-top:-6px}
.phead .bio{margin:0;max-width:520px;white-space:pre-wrap;font-size:14px}
.badge{display:inline-block;font-size:11px;font-weight:700;border-radius:999px;padding:1px 9px;background:var(--soft);color:var(--accent);vertical-align:middle}
.pstats{display:flex;gap:18px;justify-content:center;font-size:13px;color:var(--muted)}
.pstats b{display:block;color:var(--ink);font-size:17px;line-height:1.3}
.links{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}
.links a{font-size:13px;text-decoration:none;color:var(--ink);border:1px solid var(--line);border-radius:999px;padding:6px 14px;background:var(--card);min-height:36px;display:inline-flex;align-items:center;gap:6px}
.form{display:grid;gap:14px}
.form label{display:grid;gap:4px;font-size:14px;font-weight:700}
.form label small,.form .hint{font-weight:400;color:var(--muted);font-size:12px}
.form input[type=text],.form input[type=url],.form input[type=email],.form textarea,.form select{font:inherit;font-size:16px;font-weight:400;width:100%;border:1px solid var(--line);border-radius:10px;padding:10px 12px;background:var(--bg);color:var(--ink)}
.form textarea{min-height:84px;resize:vertical}
button.btn{border:0;font:inherit;font-weight:700;cursor:pointer;justify-content:center}
button.btn.ghost{border:1px solid var(--line);font-weight:500}
button.btn:disabled{opacity:.6}
.msg{font-size:13px;color:var(--muted);min-height:1.2em;margin:0}
.msg.err{color:#d2553f}
.muted{color:var(--muted)}
.steps{counter-reset:s;list-style:none;padding:0;margin:0;display:grid;gap:10px}
.steps li{counter-increment:s;padding-left:38px;position:relative}
.steps li::before{content:counter(s);position:absolute;left:0;top:1px;width:26px;height:26px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font-weight:800;font-size:14px;display:grid;place-items:center}
.ways{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
.way{border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:grid;gap:6px;align-content:start;font-size:14px}
.way b{font-size:15px}
.way ol{margin:0;padding-left:1.3em}
[hidden]{display:none!important}
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


# R18作品のページは、年齢を確認するまで中身を隠す（確認は端末に保存して、次からは聞かない）
AGE_GATE = """<div id="ageGate" style="position:fixed;inset:0;z-index:100;background:#120d10;display:grid;place-items:center;padding:20px">
<div style="max-width:420px;width:100%;background:#1f171b;border:1px solid #3a2a31;border-radius:16px;padding:22px;display:grid;gap:12px;color:#f3eef0;text-align:center">
<b style="font-size:40px;color:#f07890;line-height:1">R18</b>
<b style="font-size:18px">18歳以上向けの作品です</b>
<p style="margin:0;color:#c9b8c0;font-size:14px">あなたは18歳以上ですか？</p>
<button type="button" id="ageYes" style="border:0;border-radius:12px;padding:12px;font-weight:700;background:#f07890;color:#2a0d15;cursor:pointer;font-size:15px">はい（表示する）</button>
<a href="../../list.html" style="color:#c9b8c0;font-size:14px">いいえ（まとめに戻る）</a>
</div></div>
<script>
(function(){try{if(JSON.parse(localStorage.getItem('tpb:age18')||'false')){document.getElementById('ageGate').remove();return}}catch(e){}
document.getElementById('ageYes').onclick=function(){try{localStorage.setItem('tpb:age18','true')}catch(e){};document.getElementById('ageGate').remove()};})();
</script>
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
<meta name="twitter:card" content="summary_large_image">{'<meta name="robots" content="noindex">' if 'id="ageGate"' in body else ''}
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
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js" defer></script>
<script src="{prefix}assets/data.js" defer></script>
<script src="{prefix}assets/tpb.js" defer></script>
</body>
</html>
"""


def discord_link(g, prefix=""):
    # 感想はサイトの感想シートで送る（フィードの該当作品を開いてシートを出す）
    return f'<a class="btn ghost" href="{prefix}./#fb-{e(g["slug"])}">💬 感想を送る</a>'



def card(g, prefix):
    """まとめ用の小さいカード（YouTubeのホームのように、画像・タイトル・作者・数字だけ）"""
    slug = e(g["slug"])
    sub = " ・ ".join(x for x in (PLATFORM.get(g.get("platform"), ""), f"確かめたい：{g['check']}" if g.get("check") else "") if x)
    return f"""<article class="tile" data-check="{e(g.get('check',''))}" data-plat="{e(g.get('platform','both'))}">
<a class="thumb" href="{prefix}./?g={slug}" aria-label="{e(g['title'])}をショートで見る"{f' data-clip="{prefix}{e(g["clip"])}"' if g.get('clip') and not is_r18(g) else ''}><img class="media" src="{cover_src(g, prefix)}" alt="" loading="lazy">{f'<span class="rate rate-{e(g["rating"])}">{RATING[g["rating"]]}</span>' if g.get("rating") in RATING else ''}{f'<span class="dur">{e(g["minutes"])}</span>' if g.get('minutes') else ''}</a>
<div class="meta2">
{by_html(g, prefix, 36, "av-link", True)}
<div class="meta">
<a class="t" href="{prefix}games/{slug}/">{e(g['title'])}</a>
<div class="by">{by_html(g, prefix)}</div>
<div class="by">{e(sub)}</div>
<div class="by" data-stats="{slug}"></div>
</div>
<button class="tpb-kebab" type="button" data-menu="{slug}" aria-label="{e(g['title'])} のメニュー" aria-haspopup="menu">⋮</button>
</div>
</article>"""


def build():
    games = json.loads((ROOT / "games.json").read_text(encoding="utf-8"))
    (ROOT / "assets").mkdir(exist_ok=True)
    (ROOT / "assets/style.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    make_site_og(ROOT / "og/site.png")
    checks = sorted({g.get("check") for g in games if g.get("check")})

    for g in games:
        (make_r18_og if is_r18(g) else make_og)(g, ROOT / f"og/{g['slug']}.png")
        hl = "".join(f"<li>{e(h)}</li>" for h in g.get("highlights", []))
        body = (AGE_GATE if is_r18(g) else "") + f"""<div class="wrap">
<header class="bar"><a class="ghost-link" href="../../list.html">← まとめ</a><span class="bar-r"><span data-me></span></span></header>
<article class="card">
{media_html(g, '../../')}
<div class="body">
<div class="meta2"><h2 style="flex:1">{e(g['title'])}</h2><button class="tpb-kebab" type="button" data-menu="{e(g['slug'])}" data-in-page aria-label="{e(g['title'])} のメニュー" aria-haspopup="menu">⋮</button></div>
<div class="byrow">{by_html(g, '../../', 32, "by-chip")}{f' <a class="by" href="https://x.com/{e(g["x"].lstrip("@"))}">@{e(g["x"].lstrip("@"))}</a>' if g.get('x') else ''}</div>
<p class="one">{e(g['oneliner'])}</p>
<div class="row"><a class="btn big" data-play="{e(g['slug'])}" href="../../{e(g['play'])}">▶ 遊ぶ{f"（{e(g['minutes'])}）" if g.get('minutes') else ''}</a>{discord_link(g, '../../')}<a class="btn ghost" href="../../?g={e(g['slug'])}">ショートで見る</a></div>
<div class="chips">{chips_html(g)}</div>
{f'<div><b>見どころ</b><ul class="hl">{hl}</ul></div>' if hl else ''}
{f'<div class="by">操作：{e(g["controls"])}</div>' if g.get('controls') else ''}
{f'<div class="q"><b>作者が確かめたいこと</b>{e(g["question"])}</div>' if g.get('question') else ''}
{''.join(f'<div class="upd"><b>感想でアップデート（{e(u["date"])}）</b>{e(u["text"])}</div>' for u in g.get('updates', []))}
</div>
</article>
<section class="card"><div class="body"><h2>みんなの感想</h2><div id="fbsum" class="by"></div><div id="react" class="by"></div><div id="fb" class="fblist">読み込み中…</div></div></section>
<footer>感想はトップのフィードの「💬感想」から送れます</footer>
</div>
<script>
(async function(){{
 const box=document.getElementById('fb'), sum=document.getElementById('fbsum');
 // 👍と🤔の理由（だれが押したかは出さない。「好みのジャンルじゃない」は作品の評価ではないので出さない）
 fetch('{SB_URL}/rest/v1/rpc/game_stats',{{method:'POST',headers:{{apikey:'{SB_KEY}','Content-Type':'application/json'}},body:'{{"since_days":3650}}'}})
  .then(r=>r.ok?r.json():[]).then(rows=>{{const x=(rows||[]).find(r=>r.game_slug==='{g['slug']}'); if(!x) return;
   const t=[]; if(x.plays) t.push('遊んだ人 '+x.plays+'人'); if(x.likes) t.push('👍 '+x.likes);
   const why=[['操作がわかりにくい',x.hmm_controls],['重い・うまく動かない',x.hmm_heavy],['おもしろさがわからなかった',x.hmm_fun]].filter(a=>a[1]>0).map(a=>a[0]+' '+a[1]+'人');
   if(why.length) t.push('🤔 '+why.join('、'));
   document.getElementById('react').textContent=t.join(' ・ ');}}).catch(()=>{{}});
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
<header class="bar"><a class="brand" href="./list.html"><img src="assets/icon-192.png" alt="" width="32" height="32">テストプレイ部</a><span class="bar-r"><a class="ghost-link" href="./creators.html">作る人へ</a><a class="btn" href="./">▶ ショート</a><span data-me></span></span></header>
<p class="lead">学生のゲームを、5分でつまみ食い。画像をタップするとショートで見られます。</p>
<nav class="filters" aria-label="絞り込み">{filters}</nav>
<nav class="filters" aria-label="端末で絞り込み"><button type="button" aria-pressed="true" data-p="">どの端末でも</button><button type="button" aria-pressed="false" data-p="pc">PCで遊べる</button><button type="button" aria-pressed="false" data-p="sp">スマホで遊べる</button></nav>
<main id="list" class="grid">
{cards}
</main>
<p class="empty" id="empty" hidden>この条件の作品はまだありません。</p>
<footer>登録なしで遊べます ・ 感想は任意 ・ {len(games)}作品 ・ <a href="./creators.html">作品を載せたい人へ</a> ・ <a href="./me.html">マイページ</a> ・ <a href="./privacy.html">集める情報と使い道</a> ・ <a href="./dev.html">開発者ページ</a></footer>
</div>
<script>
let F='',P='';
// 遊んだ人・感想の数（YouTubeの再生回数のように表示）
fetch('{SB_URL}/rest/v1/rpc/game_stats',{{method:'POST',headers:{{apikey:'{SB_KEY}','Content-Type':'application/json'}},body:'{{"since_days":3650}}'}})
 .then(r=>r.ok?r.json():[]).then(rows=>{{(rows||[]).forEach(x=>{{const el=document.querySelector('[data-stats="'+x.game_slug+'"]');if(!el)return;const t=[];if(x.plays)t.push('遊んだ人 '+x.plays+'人');if(x.feedbacks)t.push('感想 '+x.feedbacks+'件');el.textContent=t.join(' ・ ')}})}}).catch(()=>{{}});
function apply(){{let n=0;document.querySelectorAll('#list .tile').forEach(c=>{{const pl=c.dataset.plat;const okP=!P||pl==='both'||pl===P;const show=(!F||c.dataset.check===F)&&okP;c.hidden=!show;if(show)n++;}});document.getElementById('empty').hidden=n>0;}}
document.querySelectorAll('.filters button').forEach(b=>b.addEventListener('click',()=>{{
 const nav=b.parentElement; nav.querySelectorAll('button').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));
 if('f' in b.dataset)F=b.dataset.f; else P=b.dataset.p; apply();
}}));
</script>"""
    (ROOT / "list.html").write_text(page("作品一覧｜テストプレイ部",
                                         "学生のゲームを、5分でつまみ食い。遊んで、一言感想を送り合う場所。",
                                         f"{BASE}/list.html", f"{BASE}/og/site.png", body, ""), encoding="utf-8")

    # 作る人へ（作品を載せたい人向けの案内ページ）
    sample = next((g for g in games if g.get("updates")), games[0] if games else None)
    sample_link = f'<a href="./games/{e(sample["slug"])}/">{e(sample["title"])}の作品ページ</a>' if sample else "作品ページ"
    creators = f"""<div class="wrap">
<header class="bar"><a class="brand" href="./list.html"><img src="assets/icon-192.png" alt="" width="32" height="32">テストプレイ部</a><span class="bar-r"><a class="btn" href="./">▶ ショート</a><span data-me></span></span></header>
<section class="card hero-c"><div class="body">
<p class="eyebrow">作品を載せたい人へ</p>
<h1>説明するより、<br>遊んでもらおう。</h1>
<p>小さく遊べる版を出すだけで、作品ページができます。遊んだ人の数も、もらった感想も、それを受けて直した記録も、ぜんぶ1ページに残ります。</p>
<div class="row"><a class="btn" href="./submit.html">作品を応募する</a><a class="btn ghost" href="#url">遊べるURLの作り方</a></div>
</div></section>

<section class="card"><div class="body">
<h2>載せるまでの流れ</h2>
<ol class="steps">
<li><b>遊べるURLを作る</b><br>ブラウザで開いてすぐ遊べるURLを用意します。作り方は<a href="#url">下の「遊べるURLの作り方」</a>へ。</li>
<li><b>URLを運営にわたす</b><br><a href="./submit.html">応募フォーム</a>に、作品名・URL・一言の3つを書いて送るだけ。Discordで運営に声をかけてもOK。</li>
<li><b>運営が遊んで、作品ページを作る</b><br>運営がかならず遊んでから載せます。載ったらDiscordの「新作とおすすめ」に流れます。</li>
<li><b>数字と感想を見る</b><br>ログインすると、<a href="./dev.html">開発者ページ</a>で遊んだ人の数・遊んだ時間・感想が見られます。<a href="./me.html">マイページ</a>でプロフィールも作れます。</li>
</ol>
</div></section>

<section class="card"><div class="body">
<h2>こんな人に使ってほしい</h2>
<ul class="checks">
<li>ゲームは作ったけど、ポートフォリオに載せるにはちょっと薄いと感じている人</li>
<li>機能をひとつずつ文章で説明するのがダルい人</li>
<li>作ったゲームが、誰にも遊ばれないまま眠っている人</li>
<li>面接で「ユーザーの声を聞いて改善した経験」を話せるようにしたい人</li>
</ul>
</div></section>

<section class="card"><div class="body">
<h2>載せるとできること</h2>
<ul class="checks">
<li><b>遊べる作品ページ</b>：遊ぶボタン、動画、あなたが確かめたいことが1ページにまとまる。URLを1本貼るだけでポートフォリオになる</li>
<li><b>数字が自動で並ぶ</b>：遊んだ人の数、「また遊びたい」の割合、感想の数</li>
<li><b>直した記録が残る</b>：感想を読んで直したら「感想でアップデート」に、いつ・どんな声で・何を直したかが残る</li>
<li><b>説明は全部書かなくていい</b>：遊んでもらえば伝わる</li>
</ul>
<p class="muted">例：{sample_link}（もらった感想で直した記録つき）</p>
<div class="shots">
<figure><a href="./games/{e(sample["slug"]) if sample else ""}/"><img src="assets/guide/game.jpg" alt="作品ページの例。動画、作った人、確かめたいこと、遊ぶボタンが並んでいる" loading="lazy" width="600" height="1140"></a><figcaption>作品ページ（じっさいの画面）</figcaption></figure>
<figure><a href="./profile.html?u=unei"><img src="assets/guide/profile.jpg" alt="プロフィールの例。アイコン、名前、ひとこと、リンク、作品の一覧" loading="lazy" width="600" height="1140"></a><figcaption>プロフィール（じっさいの画面）</figcaption></figure>
<figure class="widefig"><img src="assets/guide/dev.jpg" alt="開発者ページの見本。遊んだ人、遊んだ時間、どこで離れたか、感想の内わけがグラフで並ぶ" loading="lazy" width="1000" height="760"><figcaption>開発者ページ（見本。数字は例です）— 遊んだ人の数、どこで離れたか、感想が見られる</figcaption></figure>
</div>
</div></section>

<section class="card"><div class="body">
<h2>完成していなくても大丈夫</h2>
<p>テスト部屋だけ、最初の1面だけ、チュートリアルだけでも、立派な作品ページになります。重いゲームは、遊ぶ部分だけを切り出した「小さい版」にしてください。</p>
<h3>載せるのに必要なもの</h3>
<ul>
<li>ブラウザで遊べるURL（容量は200MB以下がおすすめ）</li>
<li>一言（何をするゲームか）</li>
<li>画像1枚（あれば5〜10秒の動画も）</li>
<li>対応端末（PCのみ／スマホのみ／PC・スマホ）</li>
<li>あなたが確かめたいこと（操作感・楽しさ・チュートリアルなど）</li>
</ul>
<div class="row"><a class="btn" href="./submit.html">作品を応募する</a><a class="btn ghost" href="{e(DISCORD_INVITE)}" target="_blank" rel="noopener">Discordで運営に声をかける</a></div>
</div></section>

<section class="card" id="url"><div class="body">
<h2>遊べるURLの作り方</h2>
<p>「ダウンロードして遊ぶ」ではなく、<b>ブラウザで開いてすぐ遊べるURL</b>がおすすめです。遊ぶ人の数がまるで変わります。どれも無料です。</p>
<div class="ways">
<div class="way"><b>unityroom</b><span class="muted">Unityで作った人に。日本語でかんたん</span>
<ol><li>Unityで「WebGL」向けにビルドする（圧縮は Gzip にする）</li><li><a href="https://unityroom.com/" target="_blank" rel="noopener">unityroom</a>に登録して「ゲームを登録」</li><li>ビルドでできた4つのファイルをアップロード</li><li>公開して、ゲームのページのURLをコピー</li></ol></div>
<div class="way"><b>itch.io</b><span class="muted">Unity・Godot・GameMaker・ティラノなど何でも</span>
<ol><li>Web（HTML5）向けに書き出す</li><li>書き出したフォルダをZIPにする（index.html がいちばん上に来るように）</li><li><a href="https://itch.io/" target="_blank" rel="noopener">itch.io</a>で「Upload new project」→ 種類を「HTML」にしてZIPをアップロード</li><li>「This file will be played in the browser」にチェック</li><li>公開（Public）にして、ページのURLをコピー</li></ol></div>
<div class="way"><b>GitHub Pages</b><span class="muted">JavaScriptで作った人、GitHubを使っている人に</span>
<ol><li>index.html が入ったフォルダを、公開リポジトリにプッシュ</li><li>リポジトリの Settings → Pages を開く</li><li>「Deploy from a branch」で main を選んで保存</li><li>1〜2分待つと https://ユーザー名.github.io/リポジトリ名/ で遊べる</li></ol></div>
<div class="way"><b>そのほか</b><span class="muted">すでに置いてある人はそのURLでOK</span>
<ol><li>ふりーむ！・PLiCy・ゲームアツマール系・自分のサイトなど、ブラウザで遊べればどこでもOK</li><li>RPGツクールやティラノは「ブラウザ向け」に書き出す</li><li>Scratchは作品ページのURLをそのまま</li></ol></div>
</div>
<h3>うまくいかないとき</h3>
<ul>
<li><b>開いても真っ白</b>：ZIPのいちばん上に index.html があるか確かめる（フォルダの中にフォルダが入っていないか）</li>
<li><b>Unityで読み込みが止まる</b>：Player Settings の「Compression Format」を Gzip か Disabled にしてビルドし直す</li>
<li><b>重い・長い</b>：最初の1面だけ、テスト部屋だけの「小さい版」にする。200MB以下、読み込み30秒以内がめやす</li>
<li><b>スマホで動くかわからない</b>：わからなければ「PCのみ」で出してOK。あとから変えられます</li>
<li><b>URLがまだない</b>：Discordで聞いてくれれば、運営がいっしょに見ます</li>
</ul>
<h3>URLの渡し方</h3>
<p>URLができたら、<a href="./submit.html">応募フォーム</a>に貼って送ってください。Discordの人は、運営にURLを送るだけでも大丈夫です。</p>
<div class="row"><a class="btn" href="./submit.html">作品を応募する</a></div>
</div></section>

<section class="card"><div class="body">
<h2>よくある質問</h2>
<h3>お金はかかる？</h3><p>かかりません。載せるのも、遊ぶのも無料です。</p>
<h3>作品はだれのもの？</h3><p>作った人のものです。テストプレイ部は、遊べるURLへの入口と感想を集める場所を用意するだけです。</p>
<h3>あとで直したり、消したりできる？</h3><p>できます。ログインして、自分の作品の「⋮」→「直したいところを運営に送る」から送るか、Discordで運営に言ってください。</p>
<h3>どんな感想が届く？</h3><p>「もう一回遊びたい？」「どこまで遊んだ？」などの選ぶ質問と、一言です。だれが書いたかは作った人には見えません。<a href="./games/{e(sample["slug"]) if sample else ""}/">作品ページの例</a>で、じっさいの見え方を確かめられます。</p>
<h3>プロフィールは作れる？</h3><p><a href="./me.html">マイページ</a>で、名前・アイコン・ひとこと・X や itch.io などのリンクを書けます。作品のとなりのアイコンから、あなたのプロフィールと作品の一覧に飛べるようになります。例：<a href="./profile.html?u=unei">運営のプロフィール</a></p>
</div></section>

<section class="card"><div class="body">
<h2>年齢制限のある作品について</h2>
<p>ホラーや暴力表現のある作品（R15）、18歳以上向けの作品（R18）も載せられます。載せるときに、どちらにあたるかを教えてください。</p>
<ul>
<li><b>R15</b>：作品に「R15」の印がつきます</li>
<li><b>R18</b>：見る人が18歳以上だと確認するまで、作品は表紙で隠れます。作品の画像や動画はこのサイトには置かず、共通の表紙を使います。ゲーム本体は、年齢制限のある作品を置けるサイトに置いてください</li>
<li>R18の作品は、Discordの新作通知と毎日のおすすめには流れません</li>
<li>未成年を性的に描いたもの、実在の人物を性的に描いたものは載せられません</li>
</ul>
</div></section>

<section class="card"><div class="body">
<h2>運営の約束</h2>
<p>載せた作品は、運営が必ず全部遊んで感想を書きます。感想は、遊んだ人がログインして送るものだけが届きます。作品をけなすだけの感想や、遊ばずに書いた感想は運営が消します。</p>
</div></section>
<footer><a href="./list.html">← まとめに戻る</a> ・ <a href="./submit.html">作品を応募する</a> ・ <a href="./me.html">マイページ</a> ・ <a href="./privacy.html">集める情報と使い道</a> ・ <a href="./dev.html">開発者ページ</a></footer>
</div>
<style>
.hero-c h1{{font-size:clamp(28px,6vw,40px);line-height:1.25;margin:4px 0 12px}}
.eyebrow{{color:var(--accent);font-weight:700;font-size:13px;margin:0;letter-spacing:.06em}}
.checks{{list-style:none;padding:0;margin:0;display:grid;gap:10px}}
.checks li{{padding-left:26px;position:relative}}
.checks li::before{{content:"✓";position:absolute;left:0;color:var(--accent);font-weight:800}}
.wrap h3{{font-size:15px;margin:16px 0 6px}}
.shots{{display:grid;grid-template-columns:1fr 1fr;gap:12px}}
.shots figure{{margin:0;display:grid;gap:4px}}
.shots img{{width:100%;height:auto;border-radius:10px;border:1px solid var(--line);display:block}}
.shots figcaption{{font-size:12px;color:var(--muted)}}
.shots .widefig{{grid-column:1/-1}}
</style>"""
    (ROOT / "creators.html").write_text(page("作品を載せたい人へ｜テストプレイ部",
                                             "説明するより、遊んでもらおう。小さく遊べる版を出すだけで、遊んだ人の数・感想・直した記録が残る作品ページができます。",
                                             f"{BASE}/creators.html", f"{BASE}/og/site.png", creators, ""), encoding="utf-8")

    # プライバシーの説明
    privacy = f"""<div class="wrap">
<header class="bar"><a class="brand" href="./list.html"><img src="assets/icon-192.png" alt="" width="32" height="32">テストプレイ部</a><a class="btn" href="./">▶ ショート</a></header>
<section class="card"><div class="body">
<h1 style="font-size:24px;margin:0 0 8px">集める情報と使い道</h1>
<p>テストプレイ部では、作品をよくするための数字と、荒らし対策のために、次の情報を集めています。広告のための追跡はしていません。</p>
<h2>集めるもの</h2>
<ul>
<li><b>端末ごとのID</b>：ブラウザに保存するランダムな文字列です。名前やメールアドレスとはつながっていません</li>
<li><b>遊んだ記録</b>：「遊ぶ」「👍」「🤔」を押したこと（🤔は選んだ理由も）、遊んだ時間、PCかスマホか、時間帯</li>
<li><b>感想</b>：送った内容と、送ったアカウント（ログインした人のみ）</li>
<li><b>ログインの情報</b>：メールアドレス、またはDiscord・Googleのアカウントの名前とメールアドレス</li>
<li><b>プロフィール</b>：自分で書いた名前・ID・ひとこと・リンク・アイコンの画像（作った人だけ。だれでも見られます）</li>
<li><b>作品の応募</b>：応募フォームに書いた内容と、送ったアカウント</li>
<li><b>報告</b>：「報告する」で送った内容と、端末ごとのID（ログインしていればアカウントも）</li>
</ul>
<h2>使い道</h2>
<ul>
<li>ショートの並び順（あなたに合いそうな作品を先に出すため）</li>
<li>作った人に、作品の数字（遊んだ人の数・遊んだ時間・離れたところなど）と感想を届けるため</li>
<li>荒らしや、ふざけた感想への対策（感想の非表示・送れなくする措置）のため</li>
</ul>
<h2>だれに見えるか</h2>
<ul>
<li><b>作った人</b>：自分の作品の合計の数字と、感想の本文。だれが書いたかは見えません</li>
<li><b>運営</b>：上のすべて。感想を書いたアカウントの名前は、荒らし対策のためにだけ使います</li>
<li><b>みんな</b>：作品ページの感想の本文と、遊んだ人の数などの合計。プロフィールに自分で書いたもの</li>
<li>感想を書いた人のプロフィールが、感想の横に出ることはありません。報告は運営だけが見ます</li>
</ul>
<h2>保存する場所</h2>
<p>Supabase（東京のサーバー）に保存しています。サイトはGitHub Pagesで公開しています。</p>
<h2>消してほしいとき</h2>
<p>自分の感想やアカウントの情報を消してほしいときは、<a href="{e(DISCORD_INVITE)}" target="_blank" rel="noopener">Discord</a>で運営に連絡してください。ブラウザに保存されたIDや記録は、ブラウザのサイトデータを消すと消えます。</p>
<p>プロフィールとアイコンの画像は、<a href="./me.html">マイページ</a>でいつでも自分で直せます。</p>
<p class="muted">2026年11月19日 作成・プロフィール／応募／報告について追記</p>
</div></section>
<footer><a href="./list.html">← まとめに戻る</a></footer>
</div>"""
    (ROOT / "privacy.html").write_text(page("集める情報と使い道｜テストプレイ部",
                                            "テストプレイ部が集める情報と、その使い道。",
                                            f"{BASE}/privacy.html", f"{BASE}/og/site.png", privacy, ""), encoding="utf-8")

    # トップはショート風のフィード
    feed_games = [{k: v for k, v in g.items() if not (is_r18(g) and k in ("clip", "youtube", "cover"))} for g in games]
    # どのページでも使うデータ（プロフィール・マイページ・メニュー用）
    shared = json.dumps({"base": BASE, "sbUrl": SB_URL, "sbKey": SB_KEY, "discord": DISCORD_INVITE, "games": feed_games, "creators": CREATORS},
                        ensure_ascii=False).replace("</", "<\\/")
    (ROOT / "assets/data.js").write_text("window.TPB_DATA=" + shared + ";\n", encoding="utf-8")
    data = json.dumps(feed_games, ensure_ascii=False).replace("</", "<\\/")
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
    # 検索エンジン向けの一覧（R18の作品ページは入れない）
    urls = ["", "list.html", "creators.html", "privacy.html"] + [f"profile.html?u={h}" for h in CREATORS] + [f"games/{g['slug']}/" for g in games if not is_r18(g)]
    (ROOT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                      + "".join(f"<url><loc>{e(BASE)}/{e(u)}</loc></url>\n" for u in urls) + "</urlset>\n", encoding="utf-8")
    (ROOT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {BASE}/sitemap.xml\n", encoding="utf-8")
    print(f"built {len(games)} games -> {ROOT}")


if __name__ == "__main__":
    build()
