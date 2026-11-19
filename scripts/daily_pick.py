#!/usr/bin/env python3
"""今日のおすすめ3本を選んで、Discordの「今日のおすすめ」チャンネルに投稿する。

GitHub Actions から毎日1回動かす想定（.github/workflows/daily-pick.yml）。
  DISCORD_WEBHOOK_URL が無い、または --dry-run のときは投稿せずに中身を表示する。
  --date 2026-11-20 のように日付を指定すると、その日の選び方を確認できる。

選び方（同じ日付なら何度動かしても同じ3本になる）
  - 追加から7日以内の新作を優先
  - 感想がまだ少ない作品を優先（感想が集まっていない作品に人を回す）
  - 前日に出た作品は出にくくする
  - 3本のうち1本以上はスマホで遊べる作品にする（作品が4本以上あるとき）
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
SB_KEY = "sb_publishable_eEHa90AqCPKyQuo7jjMasA_sGbpPh2u"  # 公開用キー（読み取りのみ）
JST = dt.timezone(dt.timedelta(hours=9))
PICKS = 3
PLATFORM = {"pc": "PCのみ", "sp": "スマホのみ", "both": "PC・スマホ"}
WEEKDAY = "月火水木金土日"


def load_games():
    games = json.loads((ROOT / "games.json").read_text(encoding="utf-8"))
    return [g for g in games if not g.get("hidden")]


def feedback_counts():
    req = urllib.request.Request(
        f"{SB_URL}/rest/v1/feedback_stats?select=game_slug,total",
        headers={"apikey": SB_KEY, "Authorization": f"Bearer {SB_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return {row["game_slug"]: int(row["total"]) for row in json.load(r)}
    except Exception as e:  # 取れなくても投稿は止めない
        print(f"感想数を取得できませんでした（全部0として扱います）: {e}", file=sys.stderr)
        return {}


def rand01(day, slug):
    h = hashlib.sha256(f"{day.isoformat()}:{slug}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64


def score(g, day, counts, avoid, last_shown):
    s = rand01(day, g["slug"])
    seen = last_shown.get(g["slug"])
    s += 0.15 * (7 if seen is None else min((day - seen).days, 7))  # しばらく出ていない作品ほど出やすく
    added = g.get("added")
    if added:
        age = (day - dt.date.fromisoformat(added)).days
        if 0 <= age < 7:
            s += 1.0
    s += 0.8 / (1 + counts.get(g["slug"], 0))
    if g["slug"] in avoid:
        s -= 1.5
    return s


def pick(games, day, counts, avoid, last_shown):
    ranked = sorted(games, key=lambda g: score(g, day, counts, avoid, last_shown), reverse=True)
    chosen = ranked[:PICKS]
    if len(games) > PICKS and not any(g.get("platform") in ("sp", "both") for g in chosen):
        mobile = next((g for g in ranked[PICKS:] if g.get("platform") in ("sp", "both")), None)
        if mobile:
            chosen[-1] = mobile
    return chosen


START = dt.date(2026, 11, 19)  # この日から毎日の選び方を積み上げる


def todays_picks(day):
    """開始日から1日ずつ選び直して、前日の結果と「最後に出た日」を引き継ぐ。
    保存しておく場所がいらず、同じ日付なら必ず同じ結果になる。"""
    games = load_games()
    counts = feedback_counts()
    prev, last_shown, picks = set(), {}, []
    d = min(START, day)
    while d <= day:
        pool = [g for g in games if dt.date.fromisoformat(g.get("added", START.isoformat())) <= d]
        avoid = prev if len(pool) >= PICKS * 2 else set()
        picks = pick(pool, d, counts, avoid, last_shown)
        prev = {g["slug"] for g in picks}
        for slug in prev:
            last_shown[slug] = d
        d += dt.timedelta(days=1)
    return picks, counts


def embed(g, counts):
    page = f"{BASE}/games/{g['slug']}/"
    n = counts.get(g["slug"], 0)
    lines = [g["oneliner"]]
    if g.get("question"):
        lines.append(f"\n**作者が確かめたいこと**\n{g['question']}")
    lines.append(f"\n[▶ 遊ぶ]({page}) ・ [💬 感想を送る]({BASE}/#fb-{g['slug']})")
    fields = [
        {"name": "時間", "value": g.get("minutes") or "—", "inline": True},
        {"name": "端末", "value": PLATFORM.get(g.get("platform"), "—"), "inline": True},
        {"name": "届いた感想", "value": f"{n}件" if n else "まだ0件。最初の1人になろう", "inline": True},
    ]
    color = g.get("color", "#5865f2").lstrip("#")
    return {
        "title": g["title"],
        "url": page,
        "description": "\n".join(lines),
        "color": int(color, 16),
        "fields": fields,
        "image": {"url": f"{BASE}/og/{g['slug']}.png"},
        "footer": {"text": f"{g.get('stage', '')}・{g.get('genre', '')}・by {g.get('author', '')}".strip("・")},
    }


def payload(day, picks, counts):
    head = f"## 🎮 今日のおすすめ（{day.month}/{day.day} {WEEKDAY[day.weekday()]}）"
    body = "どれも数分で遊べるよ。遊んだら、ひとことでいいので感想を送ってね。\nこのゲームの話は、この投稿から「スレッド」を作ってどうぞ。"
    return {
        "username": "テストプレイ部",
        "avatar_url": f"{BASE}/assets/icon-192.png",
        "content": f"{head}\n{body}",
        "embeds": [embed(g, counts) for g in picks],
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

    picks, counts = todays_picks(day)
    if not picks:
        print("作品がないので投稿しません")
        return
    data = payload(day, picks, counts)
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    print(f"{day}: " + " / ".join(g["title"] for g in picks))
    if args.dry_run or not url:
        print(json.dumps(data, ensure_ascii=False, indent=1))
        if not url and not args.dry_run:
            print("DISCORD_WEBHOOK_URL が未設定なので投稿していません", file=sys.stderr)
        return
    print("投稿しました" if post(url, data) in (200, 204) else "投稿に失敗しました")


if __name__ == "__main__":
    main()
