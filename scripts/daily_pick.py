#!/usr/bin/env python3
"""今日のおすすめ3本を選んで、Discordの「今日のおすすめ」チャンネルに投稿する。

GitHub Actions から毎日1回動かす想定（.github/workflows/daily-pick.yml）。
  DISCORD_WEBHOOK_URL が無い、または --dry-run のときは投稿せずに中身を表示する。

3つの枠で1本ずつ選ぶ（同じ作品は2つの枠に出さない）
  ⭐ 評価が高い      … 感想の「また遊びたい」と 👍/🤔 から出す遊びたい度
  ▶ よく遊ばれている … 「遊ぶ」を押した人の数
  💬 感想が多い      … 届いた感想の数
数字は直近7日で比べる。7日間に動きがない枠は累計で比べ、それでも0なら新作・感想が少ない作品から選ぶ。
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://kei-tatezaki.github.io/testplay-bu"
SB_URL = "https://jwrzqaxuvmdbroemenng.supabase.co"
SB_KEY = "sb_publishable_eEHa90AqCPKyQuo7jjMasA_sGbpPh2u"  # 公開用キー
JST = dt.timezone(dt.timedelta(hours=9))
PLATFORM = {"pc": "PCのみ", "sp": "スマホのみ", "both": "PC・スマホ"}
WEEKDAY = "月火水木金土日"
PRIOR_N, PRIOR_MEAN = 3, 0.5  # 評価の数が少ない作品が1件だけで1位にならないようにする


def load_games():
    games = json.loads((ROOT / "games.json").read_text(encoding="utf-8"))
    return [g for g in games if not g.get("hidden")]


def fetch_stats(days):
    req = urllib.request.Request(
        f"{SB_URL}/rest/v1/rpc/game_stats",
        data=json.dumps({"since_days": days}).encode(),
        headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return {row["game_slug"]: row for row in json.load(r)}
    except Exception as e:  # 取れなくても投稿は止めない
        print(f"数字を取得できませんでした（{days}日）: {e}", file=sys.stderr)
        return {}


def zero(slug):
    return {"game_slug": slug, "plays": 0, "likes": 0, "hmms": 0, "feedbacks": 0, "again_much": 0, "again_some": 0}


def rating(s):
    """遊びたい度（0〜1）。すごく遊びたい=1、ちょっと=0.5、もういいかな=0、👍=1、🤔=0。"""
    n = s["feedbacks"] + s["likes"] + s["hmms"]
    if n == 0:
        return None, 0
    points = s["again_much"] + 0.5 * s["again_some"] + s["likes"]
    return (points + PRIOR_N * PRIOR_MEAN) / (n + PRIOR_N), n


def rand01(day, slug):
    h = hashlib.sha256(f"{day.isoformat()}:{slug}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64


SLOTS = [
    ("⭐ 評価が高い", lambda s: rating(s)[0] or 0),
    ("▶ よく遊ばれている", lambda s: s["plays"]),
    ("💬 感想が多い", lambda s: s["feedbacks"]),
]


def choose(day):
    games = load_games()
    weekly, total = fetch_stats(7), fetch_stats(3650)
    picks, used = [], set()
    for label, metric in SLOTS:
        pool = [g for g in games if g["slug"] not in used]
        if not pool:
            break
        best = None
        for stats, period in ((weekly, "直近7日"), (total, "累計")):
            val = lambda g: metric(stats.get(g["slug"], zero(g["slug"])))
            top = max(pool, key=lambda g: (val(g), rand01(day, g["slug"])))
            if val(top) > 0:
                best = (top, label, period, stats)
                break
        if best is None:  # まだ数字がない枠は、新作・感想の少ない作品から
            def fresh(g):
                age = (day - dt.date.fromisoformat(g.get("added", day.isoformat()))).days
                n = total.get(g["slug"], zero(g["slug"]))["feedbacks"]
                return (1.0 if 0 <= age < 7 else 0) + 0.8 / (1 + n) + rand01(day, g["slug"])
            best = (max(pool, key=fresh), "🆕 注目", "", total)
        picks.append(best)
        used.add(best[0]["slug"])
    return picks, total


def embed(g, label, period, total):
    page = f"{BASE}/games/{g['slug']}/"
    t = total.get(g["slug"], zero(g["slug"]))
    r, n = rating(t)
    lines = [f"**{label}**" + (f"（{period}）" if period else ""), g["oneliner"]]
    if g.get("question"):
        lines.append(f"\n**作者が確かめたいこと**\n{g['question']}")
    lines.append(f"\n[▶ 遊ぶ]({page}) ・ [💬 感想を送る]({BASE}/#fb-{g['slug']})")
    fields = [
        {"name": "遊んだ人", "value": f"{t['plays']}人", "inline": True},
        {"name": "感想", "value": f"{t['feedbacks']}件" if t["feedbacks"] else "まだ0件", "inline": True},
        {"name": "遊びたい度", "value": f"{round(r * 100)}%（{n}人）" if r is not None else "—", "inline": True},
        {"name": "時間", "value": g.get("minutes") or "—", "inline": True},
        {"name": "端末", "value": PLATFORM.get(g.get("platform"), "—"), "inline": True},
    ]
    return {
        "title": g["title"],
        "url": page,
        "description": "\n".join(lines),
        "color": int(g.get("color", "#5865f2").lstrip("#"), 16),
        "fields": fields,
        "image": {"url": f"{BASE}/og/{g['slug']}.png"},
        "footer": {"text": "・".join(x for x in (g.get("stage"), g.get("genre"), f"by {g.get('author', '')}") if x)},
    }


def payload(day, picks, total):
    head = f"## 🎮 今日のおすすめ（{day.month}/{day.day} {WEEKDAY[day.weekday()]}）"
    body = ("サイトで評価が高い・よく遊ばれている・感想が多い作品から1本ずつ。\n"
            "遊んだら、ひとことでいいので感想を送ってね。話したいときは、この投稿から「スレッド」を作ってどうぞ。")
    return {
        "username": "テストプレイ部",
        "avatar_url": f"{BASE}/assets/icon-192.png",
        "content": f"{head}\n{body}",
        "embeds": [embed(g, label, period, total) for g, label, period, _ in picks],
        "allowed_mentions": {"parse": []},
    }


def post(url, data):
    req = urllib.request.Request(
        url + ("&" if "?" in url else "?") + "wait=true",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "testplay-bu-daily-pick"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", help="YYYY-MM-DD（日本時間）。省略すると今日")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    day = dt.date.fromisoformat(args.date) if args.date else dt.datetime.now(JST).date()

    picks, total = choose(day)
    if not picks:
        print("作品がないので投稿しません")
        return
    data = payload(day, picks, total)
    print(f"{day}: " + " / ".join(f"{label}={g['title']}" for g, label, _, _ in picks))
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if args.dry_run or not url:
        print(json.dumps(data, ensure_ascii=False, indent=1))
        if not url and not args.dry_run:
            print("DISCORD_WEBHOOK_URL が未設定なので投稿していません", file=sys.stderr)
        return
    print("投稿しました" if post(url, data) in (200, 204) else "投稿に失敗しました")


if __name__ == "__main__":
    main()
