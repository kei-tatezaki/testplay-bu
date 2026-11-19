#!/usr/bin/env python3
"""games.json に新しく作品が増えたら、Discordの「新作とおすすめ」チャンネルに知らせる。

GitHub Actions で games.json が main に push されたときに動く（.github/workflows/notify-new.yml）。
  python3 scripts/notify_new.py <前のコミット>
  前のコミットの games.json と今の games.json を比べて、増えた作品（hidden ではないもの）を投稿する。
  DISCORD_WEBHOOK_URL が無い、または --dry-run のときは投稿せずに中身を表示する。
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import daily_pick as dp  # 見た目（embed）と投稿の処理を共通にする

MAX_PER_PUSH = 5  # 一度にたくさん増えても、通知は5本まで


def old_slugs(before):
    if not before or set(before) == {"0"}:
        return None  # 比べる相手がない（ブランチを作った直後など）
    try:
        raw = subprocess.check_output(["git", "show", f"{before}:games.json"], cwd=dp.ROOT, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return set()  # 前のコミットに games.json が無かった
    return {g["slug"] for g in json.loads(raw)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before", help="比べる前のコミット（GitHub Actions の github.event.before）")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    before = old_slugs(args.before)
    if before is None:
        print("比べる前のコミットがないので通知しません")
        return
    new = [g for g in dp.load_games() if g["slug"] not in before][:MAX_PER_PUSH]
    if not new:
        print("新しい作品はありません")
        return

    total = dp.fetch_stats(3650)
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    for g in new:
        data = {
            "username": "テストプレイ部",
            "avatar_url": f"{dp.BASE}/assets/icon-192.png",
            "content": f"## 🆕 新作が届きました\n**{g['title']}**（by {g.get('author', '')}）\nいちばん最初に遊んで、感想を送ってあげよう。話したいときは、この投稿から「スレッド」を作ってどうぞ。",
            "embeds": [dp.embed(g, "🆕 新作", "", total)],
            "allowed_mentions": {"parse": []},
        }
        print(f"新作: {g['title']}")
        if args.dry_run or not url:
            print(json.dumps(data, ensure_ascii=False, indent=1))
            continue
        print("投稿しました" if dp.post(url, data) in (200, 204) else "投稿に失敗しました")


if __name__ == "__main__":
    main()
