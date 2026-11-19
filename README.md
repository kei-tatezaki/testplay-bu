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
| creator |  | 作った人のID。`creators.json`（運営・公式）か、その人が自分で作ったプロフィールのID。プロフィールへのリンクになる |
| platform / controls / genre / added / rating |  | 対応端末（pc/sp/both）・操作・ジャンル・載せた日・年齢制限（r15/r18） |

プレビュー画像（`og/xxx.png`）は自動で作られる。

`shots/<slug>.png`（ゲーム画面の画像）があれば、プレビュー画像の右に入る。

## プロフィール・マイページ・応募

- `profile.html?u=ID` … 作った人のプロフィール（アイコン・ひとこと・リンク・作品の一覧）
- `me.html` … マイページ（自分の作品・遊んだ作品・送った感想・プロフィール編集）
- `submit.html` … 作品の応募フォーム（ログインした人だけ）。届いた応募は `admin.html` の「応募」タブ
- 「報告する」で届いたものは `admin.html` の「報告」タブ
- どのページでも使う部品（⋮メニュー・報告・右上のアイコン）は `assets/tpb.js`、データは `assets/data.js`（build.py が作る）

### 応募を載せる手順（運営）

1. `admin.html` →「応募」→ URLを開いて遊ぶ
2. 「games.json用をコピー」→ `games.json` に貼る（slug・色を直す）
3. ビルドしてプッシュ
4. 「作者」タブで、応募した人をその作品の作者にする（その人のプロフィールと開発者ページにつながる）
5. 「応募」タブで「載せた」を押す

## サンプル作品の動画を撮り直す

`clips/<slug>.mp4` と `shots/<slug>.png` は、Playwrightでじっさいに遊んで録画したもの（8〜9秒・無音）。
録画用のスクリプトは `scripts/record_clips.py`（`python3 scripts/record_clips.py jump` のように作品を選べる）。

## データベース（Supabase）

`supabase/001`〜`010` を番号順に SQL Editor で実行する。009 がプロフィール・アイコン画像・報告・応募。010 は `admin_exists()`（管理者がいるかだけを返す。admin.html で、管理者でない人に「管理者にする」を出さないため。未適用でも、管理者がいるものとして動く）。
