#!/usr/bin/env python3
"""応募で届いた動画・画像を、サイトの clips/ か og/ に取りこむ（運営用・手元で使う）。

  python3 scripts/fetch_submission_media.py '<署名付きURL>' <slug>

署名付きURL：管理ページの「応募」タブの「ダウンロード（10分だけ有効）」のリンクをコピーする。
  動画 → clips/<slug>.mp4 に保存（webm は mp4 に変換。音を消し、長辺960px以下・15秒以内・2MB以下に収める）
  画像 → og/<slug>.<jpg|png|webp> に保存
games.json は自動では書き換えない。終わりに、足す行を表示するだけ。
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAX_BYTES = 2 * 1024 * 1024
MAX_SEC = 15
MAX_SIDE = 960


def die(msg):
    print("エラー：" + msg, file=sys.stderr)
    sys.exit(1)


def sniff(b):
    if b[:4] == b"\x1a\x45\xdf\xa3":
        return "video", "webm"
    if b[4:8] == b"ftyp":
        return "video", "mp4"
    if b[:3] == b"\xff\xd8\xff":
        return "image", "jpg"
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image", "png"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "image", "webp"
    return None, None


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)],
                         capture_output=True, text=True)
    if out.returncode:
        die("ffprobe で読めませんでした：" + out.stderr.strip())
    j = json.loads(out.stdout)
    v = next((s for s in j["streams"] if s["codec_type"] == "video"), None)
    if not v:
        die("映像が見つかりません")
    dur = float(j["format"].get("duration") or v.get("duration") or 0)
    return v["width"], v["height"], dur


def encode(src, dst, w, h, dur):
    t = min(dur, MAX_SEC)
    scale = "scale='if(gte(iw,ih),min(%d,iw),-2)':'if(gte(iw,ih),-2,min(%d,ih))',format=yuv420p" % (MAX_SIDE, MAX_SIDE)
    base = ["ffmpeg", "-y", "-v", "error", "-i", str(src), "-t", str(t), "-an", "-vf", scale, "-c:v", "libx264", "-movflags", "+faststart"]
    # まず画質を決め打ち（crf）。2MBを超えたら、ビットレートを指定して下げながらやりなおす
    subprocess.run(base + ["-crf", "26", "-preset", "slow", str(dst)], check=True)
    kbps = int((MAX_BYTES * 8 * 0.85) / max(t, 1) / 1000)
    while dst.stat().st_size > MAX_BYTES and kbps > 60:
        print("  %.2fMB → 2MBを超えたので、%dkbps で撮りなおします" % (dst.stat().st_size / 1048576, kbps))
        subprocess.run(base + ["-b:v", "%dk" % kbps, "-maxrate", "%dk" % kbps, "-bufsize", "%dk" % (kbps * 2), "-preset", "slow", str(dst)], check=True)
        kbps = int(kbps * 0.8)
    if dst.stat().st_size > MAX_BYTES:
        die("2MB以下にできませんでした。短く切ってから、もう一度試してください")


def main():
    if len(sys.argv) != 3 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if len(sys.argv) == 2 else 2)
    url, slug = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,60}", slug):
        die("slug は半角の英小文字・数字・ハイフンだけにしてください")
    if not url.startswith("https://"):
        die("URLは https:// から始まるものにしてください")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        die("ffmpeg / ffprobe が見つかりません")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "in.bin"
        req = urllib.request.Request(url, headers={"User-Agent": "tpb-fetch-media"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
                n = 0
                while True:
                    c = r.read(65536)
                    if not c:
                        break
                    n += len(c)
                    if n > 8 * 1024 * 1024:
                        die("ファイルが大きすぎます（想定は2MBまで）")
                    f.write(c)
        except Exception as ex:  # 期限切れ（400/403）など
            die("ダウンロードできませんでした（URLの期限は10分です。管理ページで開きなおしてください）：%s" % ex)
        kind, ext = sniff(tmp.read_bytes()[:16])
        if not kind:
            die("動画（mp4/webm）か画像（jpg/png/webp）ではないようです")
        if kind == "image":
            dst = ROOT / "og" / ("%s.%s" % (slug, ext))
            shutil.copyfile(tmp, dst)
            print("保存しました：%s（%.2fMB）" % (dst.relative_to(ROOT), dst.stat().st_size / 1048576))
            field = '"cover": "og/%s.%s"' % (slug, ext)
        else:
            w, h, dur = probe(tmp)
            print("元の動画：%d×%d・%.1f秒・%s" % (w, h, dur, ext))
            dst = ROOT / "clips" / ("%s.mp4" % slug)
            encode(tmp, dst, w, h, dur)
            w2, h2, d2 = probe(dst)
            print("保存しました：%s（%d×%d・%.1f秒・%.2fMB・音なし）" % (dst.relative_to(ROOT), w2, h2, d2, dst.stat().st_size / 1048576))
            field = '"clip": "clips/%s.mp4"' % slug
    print("\ngames.json は書き換えていません。該当の作品（slug が %s のもの）に、次の1行を足してください：\n  %s," % (slug, field))
    print("そのあと python3 build.py を実行して、確かめてから commit / push します。")
    print("載せたら、管理ページの「ファイルを消す」で、Supabase 側のファイルを消してください。")


if __name__ == "__main__":
    main()
