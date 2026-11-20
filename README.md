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

`clips/<slug>.mp4` と `shots/<slug>.png` は、Playwrightでじっさいに遊んで録画したもの（8〜9秒・無音・幅776〜840px・1本1MB以下。画面の2倍の細かさで撮るため、Chromeを `--force-device-scale-factor=2` で起動し、CDPのスクリーンキャストでコマを集めてffmpegでH.264にしている）。
ゲームのページの上の部分（運営サンプルの印・題名・説明・操作の説明）は、撮るときだけCSSで隠して、遊んでいる画面だけを撮る。
録画用のスクリプトは `scripts/record_clips.py`（`python3 scripts/record_clips.py jump` のように作品を選べる）。

## 応募で届いた動画・画像を取りこむ（運営用）

作者は応募のとき、ショートに出す動画（mp4/webm・15秒・2MB）か画像（jpg/png/webp・2MB）を選べます（Supabase の非公開バケット `submission-media`）。載せると決めたら：

1. 管理ページ「応募」タブの「ダウンロード（10分だけ有効）」のリンクをコピーする
2. `python3 scripts/fetch_submission_media.py '<コピーしたURL>' <slug> [見どころの始まりの秒]`（動画は `clips/<slug>.mp4`、画像は `og/<slug>.<拡張子>` に保存。動画は無音・長辺960px以下・15秒以内・2MB以下に直す。ffmpeg が要る）
3. 表示された1行（`"clip": …` か `"cover": …`）を games.json の該当作品に足し、`python3 build.py` → commit / push（games.json は自動では書き換えません）
4. 管理ページの「ファイルを消す」（二度押し）で、バケットのファイルを消す

## 遊び方（ダウンロード・埋め込み）とミッション

- games.json に `"play_kind":"download"`, `"size":"約2GB"`, `"os":["windows"]` を書くとダウンロード型の表示になる（遊ぶURLは公開ページ）。`"embed":"https://itch.io/embed-upload/数字"` か作者の *.github.io のURLは枠内で遊べる。admin の「games.json用」にそのまま出る。
- 今日のミッションは `supabase/016_missions_playkind.sql` を適用してから有効になる（未適用でも他は動く）。`016_check.sql` は一時DBで流す検査用（最後にわざと例外で巻き戻す）。

## 感想のAIコーチ（任意）

感想シートのAIコーチは、自分で20字以上打って2.5秒止まると自動で読む（本文が15字以上かわったとき。1回シートを開く間に最大5回）。［もう一度見てもらう］ボタンは同じ上限を使う。呼び先は、Supabase Edge Function `feedback-coach` を呼ぶ（ルールのコーチ `assets/coach.js` は端末の中だけで動き、AIなしでも使える。関数が無くても、シートは普通に動く）。

1. `supabase/017_ai_coach.sql` を SQL Editor で実行（検査は `017_check.sql`。1人1日30回が初期値（settings の `ai_coach_daily_limit`）。人ごとの上書き（0で停止）・利用の一覧は admin.html の「AIコーチ」タブ。同じ人が60秒に6回を超えると 'too_fast'。サイト全体の上限は作っていない）
2. 秘密を設定：`supabase secrets set ANTHROPIC_API_KEY=sk-ant-...`（任意：`CLAUDE_MODEL=...`、既定は `claude-haiku-5-5`）。Gemini に切りかえるなら `AI_PROVIDER=gemini` と `GEMINI_API_KEY`（任意 `GEMINI_MODEL`）
3. デプロイ：`supabase functions deploy feedback-coach --project-ref jwrzqaxuvmdbroemenng`（関数の中で JWT を自分で検証するので、`--no-verify-jwt` は不要）
4. 感想の文と作品の説明は Claude API に送られる（privacy.html に書いてある）。使わなければ送られない

## データベース（Supabase）

`supabase/001`〜`013` を番号順に SQL Editor で実行する。009 がプロフィール・アイコン画像・報告・応募。010 は `admin_exists()`（管理者がいるかだけを返す。admin.html で、管理者でない人に「管理者にする」を出さないため。未適用でも、管理者がいるものとして動く）。
011 は管理ページの「概要」タブ用（`site_visits`＝サイトを開いた記録、`admin_overview`＝運営だけが呼べる集計）。未適用でも他のタブは動き、概要タブだけ「読み込めませんでした」と出る。
012 はポイント制（`settings`＝決まりの数字、`points_ledger`＝記録）。感想（一言40字以上）でたまり、新しい応募で30pt つかう。計算と残高のチェックは全部DBの中（トリガーと関数）。数字は管理ページの「ポイント」タブで変える。**012 を適用するまで**、画面のポイント表示は出ず（`TPB.ptOk()` が false）、応募は今までどおり無料で送れる。
013 は「最初の1本は投稿無料」。見送りになっていない新しい応募が1本もない人は、ポイントなしで応募できる（`first_free_available()`・`submissions.free_launch`）。2本目からは30pt。見送りになると、無料がもう一度使える。**013 を適用するまで**、画面の「最初の1本は投稿無料」の文は静的な案内として出るが、応募はポイントがいる（012 適用後）。サイトに出す前に 013 を適用すること。
ローカルで確かめるとき：`bash supabase/tests/run_local.sh supabase/tests/012_check.sql`（013 は `013_check.sql`。使い捨てのPostgresに stub を入れて 001〜013 を通し、最後に「ALL OK」が出る。本番には触れない）。

## assets/notes.json（部長のひとこと・手書き画像）

作品一覧の「部長のひとこと」と、見出し・ロゴの手書き画像は `assets/notes.json` で差し替えます。コードは触りません。

```json
{"bucho": {"text": "", "date": ""}, "headline_img": "", "logo_img": ""}
```

- `bucho.text`：ここに文章を入れると、作品一覧の上のほうに「部長のひとこと」の掲示が出ます。**空のままなら掲示ごと出ません。** 改行はそのまま出ます。`date` は「11月21日」のように好きな書き方で（空なら出ません）。
- `headline_img`：ページの主見出し（`data-headline` を付けた見出し。いまは作る人ページ）を、この画像に差し替えます。文字は画像の alt に残ります。`assets/art/headline.webp` のようにサイトの中の相対パス（または `/` か `https://` で始まる URL）。
- `logo_img`：サイドバーと上の帯の「テストプレイ部」の文字を、この画像に差し替えます（高さ 28〜32px で表示）。
- どれも空文字なら今までどおり。JSON を直したら、そのままコミットするだけで反映されます（build.py は不要）。
- 「きょうのおすすめ」のラベルは、手書き画像が届くまで Klee One の文字です。

## 見た目のルール（作り直し後）

CSS の本体は `build.py` の `CSS` と `src/style_v2.css`（assets/style.css の末尾に足されます）。飾りは「おすすめ」と「新作」（公開から14日以内）だけ。朱は「遊ぶ・送る・応募する」の主ボタンと押した状態、からしはおすすめ・新作・ミッションの目印、青はリンク。絵文字は使わず、必要なら線画 SVG。
