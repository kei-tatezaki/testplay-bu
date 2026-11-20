-- 016 の確認（016_missions_playkind.sql を流したあとに流す）
--   テスト用のユーザー・感想・遊んだ記録をつくって、ミッションのポイントと、応募の検証を確かめる。
--   ぜんぶ1つの DO ブロックの中でやり、最後にわざとエラーを出して取り消す（本番のデータは1件も残らない）
--   結果は、エラーの文のいちばん上に出る：
--     CHECK_OK 016: N件ぜんぶ合格   … 合格（「エラー」と出るのは、後始末のためにわざとです）
--     CHECK_FAILED 016: …           … 合格しなかった項目が並ぶ
-- Supabase の SQL Editor でも、ふつうの Postgres（auth・storage のスタブつき）でも流せる

do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid();
  u5 uuid := gen_random_uuid(); u6 uuid := gen_random_uuid(); u7 uuid := gen_random_uuid(); u8 uuid := gen_random_uuid();
  u9 uuid := gen_random_uuid(); u10 uuid := gen_random_uuid(); ux uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  good text := '最初のステージの操作が気持ちよくて、ジャンプの高さも調整しやすく、何度でも挑戦したくなりました。';
  st jsonb; st2 jsonb; i int; r text; cases jsonb; c jsonb; d jsonb; fid uuid; cap0 int;
  rnd text := substr(md5(random()::text), 1, 6);
begin
  -- ---- 準備 ----
  n := n + 1; if char_length(good) < 40 then bad := bad || E'\n  x 準備：テスト用の感想が40字にとどいていない'; end if;
  insert into auth.users (id, email) select x, 'chk-' || rnd || '-' || x || '@example.com' from unnest(array[u1,u2,u3,u4,u5,u6,u7,u8,u9,u10]||ux) as x;
  perform set_config('request.jwt.claim.sub', u1::text, true);

  -- ---- 1. 「今日」の切りかわり（日本時間の朝5時） ----
  n := n + 1; if mission_day('2026-11-20 04:59:59+09') <> date '2026-11-19' then bad := bad || E'\n  x mission_day：4:59 は前の日'; end if;
  n := n + 1; if mission_day('2026-11-20 05:00:00+09') <> date '2026-11-20' then bad := bad || E'\n  x mission_day：5:00 から新しい日'; end if;
  n := n + 1; if mission_start(date '2026-11-20') <> timestamptz '2026-11-20 05:00:00+09' then bad := bad || E'\n  x mission_start：その日の5:00（日本時間）'; end if;

  -- ---- 2. 全部そろう：感想が0件の作品（遊んだ記録つき）に40字以上 ----
  insert into game_events (game_slug, kind, client_id) values ('chk-low', 'play', 'client-u1-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-low', 'すごく遊びたい', '最後まで', good, 'client-u1-' || rnd, u1);
  st := daily_missions_status();
  n := n + 1; if not ((st #>> '{b,done}')::boolean and (st #>> '{c,done}')::boolean and (st #>> '{all,done}')::boolean) then bad := bad || E'\n  x 全部そろうと b・c・all が done'; end if;
  n := n + 1; if (st #>> '{b,granted}')::int <> 3 or (st #>> '{c,granted}')::int <> 5 or (st #>> '{all,granted}')::int <> 5 then bad := bad || E'\n  x ポイントは b+3・c+5・all+5（いま ' || (st #>> '{b,granted}') || '/' || (st #>> '{c,granted}') || '/' || (st #>> '{all,granted}') || '）'; end if;
  n := n + 1; if (st ->> 'points_today')::int <> 23 then bad := bad || E'\n  x 今日の合計は感想10＋ミッション13＝23（いま ' || (st ->> 'points_today') || '）'; end if;
  st2 := daily_missions_status();
  n := n + 1; if st2 is distinct from st then bad := bad || E'\n  x status を2回呼んでも同じ（二重に付かない）'; end if;
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-low2', 'ちょっと遊びたい', '最後まで', good, 'client-u1-' || rnd, u1);   -- 2本目の感想
  st2 := daily_missions_status();
  n := n + 1; if (st2 #>> '{b,granted}')::int <> 3 or (st2 #>> '{c,granted}')::int <> 5 or (st2 #>> '{all,granted}')::int <> 5 then bad := bad || E'\n  x 2件目の感想でミッションのポイントは増えない'; end if;
  n := n + 1; if (select count(*) from points_ledger where user_id = u1 and reason like 'mission%') <> 3 then bad := bad || E'\n  x ミッションの記録は3行だけ'; end if;
  n := n + 1; if (st2 ->> 'points_today')::int > setting_int('daily_cap', 50) then bad := bad || E'\n  x 1日の上限をこえない'; end if;

  -- ---- 3. 短い感想・遊んでいない・くり返し・自分の作品・きのうの感想は、ミッションに数えない ----
  insert into game_events (game_slug, kind, client_id) values ('chk-s', 'play', 'client-u2-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-s', 'ちょっと遊びたい', '最後まで', 'おもしろかった', 'client-u2-' || rnd, u2);
  perform set_config('request.jwt.claim.sub', u2::text, true); st := daily_missions_status();
  n := n + 1; if (st #>> '{b,done}')::boolean or (st #>> '{c,done}')::boolean or (select count(*) from points_ledger where user_id = u2 and reason like 'mission%') > 0 then bad := bad || E'\n  x 短い感想（40字未満）は数えない'; end if;

  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-np', 'ちょっと遊びたい', '最後まで', good, 'client-u3-' || rnd, u3);
  perform set_config('request.jwt.claim.sub', u3::text, true); st := daily_missions_status();
  n := n + 1; if (st #>> '{b,done}')::boolean or (select count(*) from points_ledger where user_id = u3 and reason like 'mission%') > 0 then bad := bad || E'\n  x 遊んでいない作品の感想は数えない'; end if;

  insert into game_events (game_slug, kind, client_id) values ('chk-lz', 'play', 'client-u3-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-lz', 'ちょっと遊びたい', '最後まで', repeat('あ', 45), 'client-u3-' || rnd, u3);
  st := daily_missions_status();
  n := n + 1; if (st #>> '{b,done}')::boolean then bad := bad || E'\n  x 同じ文字のくり返しは数えない'; end if;

  insert into game_owners (game_slug, user_id) values ('chk-own', u9);
  insert into game_events (game_slug, kind, client_id) values ('chk-own', 'play', 'client-u9-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-own', 'ちょっと遊びたい', '最後まで', good, 'client-u9-' || rnd, u9);
  perform set_config('request.jwt.claim.sub', u9::text, true); st := daily_missions_status();
  n := n + 1; if (st #>> '{b,done}')::boolean then bad := bad || E'\n  x 自分の作品の感想は数えない'; end if;

  insert into game_events (game_slug, kind, client_id, created_at) values ('chk-old', 'play', 'client-u8-' || rnd, now() - interval '30 hours');
  insert into feedback (game_slug, again, reach, free, client_id, user_id, created_at) values ('chk-old', 'ちょっと遊びたい', '最後まで', good, 'client-u8-' || rnd, u8, now() - interval '30 hours');
  perform set_config('request.jwt.claim.sub', u8::text, true); st := daily_missions_status();
  n := n + 1; if (st #>> '{b,done}')::boolean or (select count(*) from points_ledger where user_id = u8 and reason like 'mission%') > 0 then bad := bad || E'\n  x きのう（今日より前）の感想は数えない'; end if;

  -- ---- 4. 感想がもう多い作品：b だけ（+3）。c と all は付かない ----
  for i in 1..3 loop
    insert into feedback (game_slug, again, reach, free, client_id, user_id, created_at) values ('chk-busy', 'ちょっと遊びたい', '最後まで', 'x' || i, 'client-ux' || i || '-' || rnd, ux[i], now() - interval '1 hour');   -- 先に書かれた3件（同じ時刻だと「前に書かれた」にならないので、少しさかのぼらせる）
  end loop;
  insert into game_events (game_slug, kind, client_id) values ('chk-busy', 'play', 'client-u4-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-busy', 'ちょっと遊びたい', '最後まで', good, 'client-u4-' || rnd, u4);
  perform set_config('request.jwt.claim.sub', u4::text, true); st := daily_missions_status();
  n := n + 1; if not (st #>> '{b,done}')::boolean or (st #>> '{c,done}')::boolean or (st #>> '{all,done}')::boolean then bad := bad || E'\n  x 感想が多い作品は b だけ'; end if;
  n := n + 1; if (st #>> '{b,granted}')::int <> 3 or (st #>> '{c,granted}')::int <> 0 or (st #>> '{all,granted}')::int <> 0 then bad := bad || E'\n  x 感想が多い作品のポイントは +3 だけ'; end if;

  -- ---- 5. BANされた人は対象外 ----
  alter table feedback disable trigger feedback_reject_banned_users;     -- BANの人の感想をむりやり入れて、ミッションが付かないことを見る
  insert into banned_users (user_id, reason) values (u5, 'chk');
  insert into game_events (game_slug, kind, client_id) values ('chk-ban', 'play', 'client-u5-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-ban', 'ちょっと遊びたい', '最後まで', good, 'client-u5-' || rnd, u5);
  alter table feedback enable trigger feedback_reject_banned_users;
  perform set_config('request.jwt.claim.sub', u5::text, true); st := daily_missions_status();
  n := n + 1; if (st ->> 'banned')::boolean is not true or (st #>> '{b,done}')::boolean or (select count(*) from points_ledger where user_id = u5 and reason like 'mission%') > 0 then bad := bad || E'\n  x BANされた人はミッションの対象外'; end if;

  -- ---- 6. 1日の上限にミッションも含める。上限がゆるんだら、残りが付く ----
  select value into cap0 from settings where key = 'daily_cap';
  update settings set value = 12 where key = 'daily_cap';
  insert into game_events (game_slug, kind, client_id) values ('chk-cap', 'play', 'client-u6-' || rnd);
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-cap', 'ちょっと遊びたい', '最後まで', good, 'client-u6-' || rnd, u6);
  perform set_config('request.jwt.claim.sub', u6::text, true); st := daily_missions_status();
  n := n + 1; if (st ->> 'points_today')::int <> 12 then bad := bad || E'\n  x 上限12のとき、今日の合計は12まで（いま ' || (st ->> 'points_today') || '）'; end if;
  n := n + 1; if (st #>> '{b,granted}')::int <> 2 or (st #>> '{c,granted}')::int <> 0 then bad := bad || E'\n  x 上限にかかった分は減らして（b=2）、付けない（c=0）'; end if;
  update settings set value = 100 where key = 'daily_cap';
  st := daily_missions_status();
  n := n + 1; if (st #>> '{c,granted}')::int <> 5 or (st #>> '{all,granted}')::int <> 5 or (st #>> '{b,granted}')::int <> 2 then bad := bad || E'\n  x 上限がゆるんだら、付いていない分だけ付く（b は2のまま）'; end if;
  update settings set value = cap0 where key = 'daily_cap';

  -- ---- 7. 遊んだ記録があとから届いたら、ボーナスが付く ----
  insert into game_events (game_slug, kind, client_id, created_at) values ('chk-late', 'play', 'client-u7-' || rnd, now() - interval '30 hours');
  insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('chk-late', 'ちょっと遊びたい', '最後まで', good, 'client-u7-' || rnd, u7);
  perform set_config('request.jwt.claim.sub', u7::text, true); st := daily_missions_status();
  n := n + 1; if not (st #>> '{b,done}')::boolean or not (st #>> '{c,done}')::boolean or (st #>> '{all,done}')::boolean or not (st #>> '{all,need_play}')::boolean then bad := bad || E'\n  x 今日の遊んだ記録がないうちは、all は未達成（need_play）'; end if;
  insert into game_events (game_slug, kind, client_id) values ('chk-late2', 'play', 'client-u7-' || rnd);
  st := daily_missions_status();
  n := n + 1; if not (st #>> '{all,done}')::boolean or (st #>> '{all,granted}')::int <> 5 then bad := bad || E'\n  x あとから遊んだ記録が届くと、all が付く'; end if;

  -- ---- 8. 感想が非表示になったら取り消す（表示に戻しても返さない） ----
  perform set_config('request.jwt.claim.sub', u1::text, true);
  select id into fid from feedback where user_id = u1 and game_slug = 'chk-low';
  update feedback set hidden = true where id = fid;
  st := daily_missions_status();
  n := n + 1; if (st #>> '{b,granted}')::int <> 0 or (st #>> '{c,granted}')::int <> 0 or (st #>> '{all,granted}')::int <> 0 then bad := bad || E'\n  x 非表示にすると、その感想のミッションのポイントは取り消される（all も）'; end if;
  update feedback set hidden = false where id = fid;
  st := daily_missions_status();
  n := n + 1; if (st #>> '{b,granted}')::int <> 0 or (select count(*) from points_ledger where user_id = u1 and reason like 'mission%' and delta > 0) <> 3 then bad := bad || E'\n  x 表示に戻しても、ミッションは二重に付かない・返らない'; end if;
  n := n + 1; if (select coalesce(sum(delta), 0) from points_ledger where user_id = u1 and reason in ('feedback', 'feedback_revoked', 'feedback_restored')) <> 10 then bad := bad || E'\n  x 012 の感想のポイントは今までどおり（非表示で取り消し・戻して返る）'; end if;

  -- ---- 9. 権限 ----
  n := n + 1; if has_function_privilege('anon', 'public.daily_missions_status()', 'execute') then bad := bad || E'\n  x daily_missions_status は anon から呼べない'; end if;
  n := n + 1; if not has_function_privilege('authenticated', 'public.daily_missions_status()', 'execute') then bad := bad || E'\n  x daily_missions_status は authenticated から呼べる'; end if;
  n := n + 1; if has_function_privilege('authenticated', 'public.missions_award(uuid)', 'execute') or has_function_privilege('authenticated', 'public.mission_grant(uuid,text,int,uuid,text)', 'execute') then bad := bad || E'\n  x 付与の部品（missions_award・mission_grant）は外から呼べない'; end if;
  perform set_config('request.jwt.claim.sub', '', true);
  begin perform daily_missions_status(); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'not_logged_in' then bad := bad || E'\n  x ログインなしは not_logged_in（いま ' || r || '）'; end if;

  -- ---- 10. 応募の検証（submission_send） ----
  perform set_config('request.jwt.claim.sub', u10::text, true);
  cases := jsonb_build_array(
    -- [名前, 期待（ok / エラー名）, data]
    jsonb_build_array('ブラウザ・play_kind なし', 'ok', jsonb_build_object('play_url', 'https://x.itch.io/game')),
    jsonb_build_array('ブラウザ・任意の https', 'ok', jsonb_build_object('play_kind', 'browser', 'play_url', 'https://example.com/play/')),
    jsonb_build_array('embed 正しい', 'ok', jsonb_build_object('play_kind', 'browser', 'play_url', 'https://x.itch.io/game', 'embed_url', 'https://itch.io/embed-upload/12345')),
    jsonb_build_array('embed ?color つき', 'ok', jsonb_build_object('play_url', 'https://x.itch.io/game', 'embed_url', 'https://itch.io/embed-upload/12345?color=333333')),
    jsonb_build_array('embed 別ホスト', 'bad_embed', jsonb_build_object('play_url', 'https://x.itch.io/game', 'embed_url', 'https://evil.com/embed-upload/1')),
    jsonb_build_array('embed に HTML', 'bad_embed', jsonb_build_object('play_url', 'https://x.itch.io/game', 'embed_url', '<iframe src="https://itch.io/embed-upload/1"></iframe>')),
    jsonb_build_array('embed 数字のあとに文字', 'bad_embed', jsonb_build_object('play_url', 'https://x.itch.io/game', 'embed_url', 'https://itch.io/embed-upload/12abc')),
    jsonb_build_array('embed の後ろに引用符', 'bad_embed', jsonb_build_object('play_url', 'https://x.itch.io/game', 'embed_url', 'https://itch.io/embed-upload/1" onload="x')),
    jsonb_build_array('embed はダウンロード型に置けない', 'bad_embed', jsonb_build_object('play_kind', 'download', 'play_url', 'https://x.itch.io/game', 'embed_url', 'https://itch.io/embed-upload/1')),
    jsonb_build_array('play_kind 不正', 'bad_play_kind', jsonb_build_object('play_kind', 'foo', 'play_url', 'https://x.itch.io/game')),
    jsonb_build_array('DL itch.io', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://author.itch.io/game', 'size', '2GB', 'os', 'Windows')),
    jsonb_build_array('DL itch.io 本体', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://itch.io/games/x', 'os', 'Windows・Mac')),
    jsonb_build_array('DL Steam', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://store.steampowered.com/app/123/Game/')),
    jsonb_build_array('DL BOOTH shop', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://shop.booth.pm/items/1')),
    jsonb_build_array('DL BOOTH', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://booth.pm/ja/items/1')),
    jsonb_build_array('DL github.com', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://github.com/a/b')),
    jsonb_build_array('DL github.com releases ページ', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://github.com/a/b/releases')),
    jsonb_build_array('DL github.io', 'ok', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.github.io/b/')),
    jsonb_build_array('DL exe 直リンク', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x/file.exe')),
    jsonb_build_array('DL zip 直リンク（大文字）', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.github.io/x/GAME.ZIP?dl=1')),
    jsonb_build_array('DL GitHub releases/download', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://github.com/a/b/releases/download/v1/setup')),
    jsonb_build_array('DL GitHub archive', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://github.com/a/b/archive/main.tar.gz')),
    jsonb_build_array('DL GitHub raw', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://github.com/a/b/raw/main/x')),
    jsonb_build_array('DL 別ホスト', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://evil.com/x')),
    jsonb_build_array('DL ホストに itch.io を含むだけ', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://itch.io.evil.com/x')),
    jsonb_build_array('DL 似たホスト', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://notitch.io/x')),
    jsonb_build_array('DL パスに itch.io', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://evil.com/itch.io')),
    jsonb_build_array('DL ユーザー情報つき', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://itch.io@evil.com/x')),
    jsonb_build_array('DL ポート指定', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://itch.io:8080/x')),
    jsonb_build_array('DL http（https でない）', 'bad_url', jsonb_build_object('play_kind', 'download', 'play_url', 'http://a.itch.io/x')),
    jsonb_build_array('os 不正', 'bad_os', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x', 'os', 'Linux')),
    jsonb_build_array('size 長すぎ', 'too_long', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x', 'size', repeat('9', 21)))
  );
  for c in select * from jsonb_array_elements(cases) loop
    delete from submissions where user_id = u10;
    d := jsonb_build_object('title', 't', 'oneliner', 'o') || (c -> 2);
    begin r := submission_send('new', null, d); if r like 'ok%' then r := 'ok'; end if; exception when others then r := sqlerrm; end;
    n := n + 1; if r <> c ->> 1 then bad := bad || E'\n  x 応募「' || (c ->> 0) || '」：期待 ' || (c ->> 1) || '／いま ' || r; end if;
  end loop;
  delete from submissions where user_id = u10;
  r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_kind', 'download', 'play_url', 'https://a.itch.io/x', 'platform', 'both', 'size', '2GB', 'os', 'Mac'));
  select data into d from submissions where user_id = u10;
  n := n + 1; if d ->> 'platform' <> 'pc' or d ->> 'play_kind' <> 'download' or d ->> 'size' <> '2GB' or d ->> 'os' <> 'Mac' then bad := bad || E'\n  x ダウンロード型は platform=pc に直し、play_kind・size・os を保存する'; end if;
  delete from submissions where user_id = u10;
  r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://a.itch.io/x', 'embed_url', 'https://itch.io/embed-upload/77', 'evil', 'x'));
  select data into d from submissions where user_id = u10;
  n := n + 1; if d ->> 'embed_url' <> 'https://itch.io/embed-upload/77' or d ? 'evil' then bad := bad || E'\n  x embed_url は保存・許可のないキーは捨てる'; end if;

  if bad = '' then raise exception 'CHECK_OK 016: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 016: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
