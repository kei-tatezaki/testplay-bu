# テストプレイ部

学生のゲームを、5分でつまみ食いできる場所。作品を縦に並べた一覧と、作品ごとのページ（Discordに貼るとプレビューが出る）を GitHub Pages で公開する。

## 作品を追加する

1. `games.json` に1件足す（下の項目）
2. `BASE_URL=https://kei-tatezaki.github.io/testplay-bu python3 build.py` を実行
3. コミットしてプッシュ

| 項目 | 必須 | 内容 |
| --- | --- | --- |
| slug | ○ | URLに使う英数字（例: `jump`） |
| title | ○ | 作品名 |
| oneliner | ○ | 何をするゲームか、一言 |
| play | ○ | 遊べるURL（itch.io / unityroom など）。このリポジトリ内なら `play/xxx/` |
| author |  | 作者名 |
| x |  | Xのアカウント（@なし可） |
| stage |  | プロトタイプ／体験版／リリース済み／企画書 |
| check |  | 確かめたいこと：楽しさ／チュートリアル／操作感 |
| question |  | 作者が確かめたいことを一文で |
| highlights |  | 見どころ（配列） |
| minutes |  | 遊ぶ時間の目安 |
| youtube |  | PVのYouTube URL（あれば埋め込む） |
| clip |  | 5〜10秒の動画ファイル（`clips/xxx.mp4` など。あれば一覧で自動再生） |
| discord |  | Discordの作品スレッドのURL |
| color / bg |  | プレビュー画像の色 |

プレビュー画像（`og/xxx.png`）は自動で作られる。
