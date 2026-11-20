-- 018 の確認（018_likes_history.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 018: N件ぜんぶ合格 ／ CHECK_FAILED 018: …
do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  i int; c int; ok boolean; j jsonb; arr jsonb;
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[u1,u2,u3]) x;
  insert into profiles (user_id, handle, name) values (u1, 'alice', 'アリス'), (u2, 'bob', 'ボブ'), (u3, 'carol', 'キャロル');

  -- u1 として
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  insert into user_likes (game_slug) values ('odd'), ('stack');
  insert into user_history (game_slug, kind) values ('odd', 'view');
  reset role;
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  insert into user_likes (game_slug) values ('jump');

  -- RLS：他人の行が見えない・消せない・なりすまして入れられない
  select count(*) into c from user_likes; n := n + 1; if c <> 1 then bad := bad || E'\n  x 自分のいいねだけ見える（' || c || '）'; end if;
  select count(*) into c from user_history; n := n + 1; if c <> 0 then bad := bad || E'\n  x 他人の履歴は見えない（' || c || '）'; end if;
  delete from user_likes where game_slug = 'odd'; get diagnostics c = row_count;
  n := n + 1; if c <> 0 then bad := bad || E'\n  x 他人のいいねは消せない'; end if;
  delete from user_history; get diagnostics c = row_count;
  n := n + 1; if c <> 0 then bad := bad || E'\n  x 他人の履歴は消せない'; end if;
  ok := false; begin insert into user_likes (user_id, game_slug) values (u1, 'new'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 他人になりすましていいねを入れられない'; end if;
  ok := false; begin insert into user_history (user_id, game_slug, kind) values (u1, 'new', 'play'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 他人になりすまして履歴を入れられない'; end if;
  ok := false; begin update user_likes set game_slug = 'zzz'; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x update は権限がない'; end if;
  ok := false; begin insert into user_likes (game_slug) values ('Bad Slug'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x slug の形がおかしいと入らない'; end if;
  ok := false; begin insert into user_history (game_slug, kind) values ('odd', 'zzz'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x kind は view/play だけ'; end if;
  select count(*) into c from user_history; n := n + 1; if c <> 0 then bad := bad || E'\n  x 履歴の件数'; end if;
  -- 自分のいいねは消せる
  delete from user_likes where game_slug = 'jump'; get diagnostics c = row_count;
  n := n + 1; if c <> 1 then bad := bad || E'\n  x 自分のいいねは消せる'; end if;
  -- anon は表に触れない
  reset role; set local role anon;
  ok := false; begin perform count(*) from user_likes; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は user_likes を読めない'; end if;
  reset role;

  -- 30分重複：view は30分以内なら入れない。play は入れる。30分より後は入る。別の作品は入る
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  insert into user_history (game_slug, kind) values ('odd', 'view');
  select count(*) into c from user_history where game_slug = 'odd' and kind = 'view';
  n := n + 1; if c <> 1 then bad := bad || E'\n  x 同じ作品の view は30分以内に重複しない（' || c || '）'; end if;
  insert into user_history (game_slug, kind, seconds, created_at) values ('odd', 'play', 95, now()), ('odd', 'play', 40, now() - interval '5 minutes');
  select count(*) into c from user_history where kind = 'play'; n := n + 1; if c <> 2 then bad := bad || E'\n  x play は重複しても入る'; end if;
  insert into user_history (game_slug, kind) values ('stack', 'view');
  select count(*) into c from user_history where kind = 'view'; n := n + 1; if c <> 2 then bad := bad || E'\n  x 別の作品の view は入る'; end if;
  insert into user_history (game_slug, kind, created_at) values ('odd', 'view', now() - interval '31 minutes');
  select count(*) into c from user_history where game_slug = 'odd' and kind = 'view'; n := n + 1; if c <> 2 then bad := bad || E'\n  x 30分より前のものは入る（' || c || '）'; end if;
  insert into user_history (game_slug, kind, created_at) values ('odd', 'view', now() - interval '20 minutes');
  select count(*) into c from user_history where game_slug = 'odd' and kind = 'view'; n := n + 1; if c <> 2 then bad := bad || E'\n  x 前の記録の30分以内は入らない（' || c || '）'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  insert into user_history (game_slug, kind) values ('odd', 'view');
  select count(*) into c from user_history; n := n + 1; if c <> 1 then bad := bad || E'\n  x 重複の判定は人ごと'; end if;
  reset role;

  -- 500件の上限：u3 に 600 件（古い順に1分ずつ）入れる → 新しい500件だけ残る
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  for i in 1..600 loop
    insert into user_history (game_slug, kind, created_at) values ('g' || (i % 7), 'play', now() - make_interval(mins => 1000 - i));
  end loop;
  select count(*) into c from user_history; n := n + 1; if c <> 500 then bad := bad || E'\n  x 履歴は500件まで（' || c || '）'; end if;
  select count(*) into c from user_history where created_at < now() - make_interval(mins => 1000 - 100); n := n + 1; if c <> 0 then bad := bad || E'\n  x 古いほうから消える（' || c || '）'; end if;
  select count(*) into c from user_history where created_at = (select max(created_at) from user_history); n := n + 1; if c <> 1 then bad := bad || E'\n  x 新しい行は残る'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  select count(*) into c from user_history; n := n + 1; if c <> 5 then bad := bad || E'\n  x 他人の500件上限が自分の履歴を消さない（' || c || '）'; end if;
  reset role;

  -- 公開設定と public_likes
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  select count(*) into c from public_likes('alice'); n := n + 1; if c <> 0 then bad := bad || E'\n  x 既定は非公開（空）'; end if;
  n := n + 1; if (my_profile() ->> 'likes_public') <> 'false' then bad := bad || E'\n  x my_profile の likes_public は false'; end if;
  perform likes_public_set(true);
  n := n + 1; if (my_profile() ->> 'likes_public') <> 'true' then bad := bad || E'\n  x オンにできる'; end if;
  reset role; set local role anon;
  select count(*) into c from public_likes('alice'); n := n + 1; if c <> 2 then bad := bad || E'\n  x 公開中は anon にも見える（' || c || '）'; end if;
  select count(*) into c from public_likes('ALICE'); n := n + 1; if c <> 2 then bad := bad || E'\n  x ID の大文字小文字は問わない'; end if;
  select count(*) into c from public_likes('bob'); n := n + 1; if c <> 0 then bad := bad || E'\n  x 非公開の人は空'; end if;
  reset role;
  -- 新しい順
  update user_likes set created_at = now() - interval '1 day' where user_id = u1 and game_slug = 'odd';
  n := n + 1; if (select game_slug from public_likes('alice') limit 1) <> 'stack' then bad := bad || E'\n  x 新しい順'; end if;
  -- 非表示・BAN は空
  update profiles set hidden = true where user_id = u1;
  select count(*) into c from public_likes('alice'); n := n + 1; if c <> 0 then bad := bad || E'\n  x 非表示のプロフィールは空'; end if;
  update profiles set hidden = false where user_id = u1;
  insert into banned_users (user_id) values (u1);
  select count(*) into c from public_likes('alice'); n := n + 1; if c <> 0 then bad := bad || E'\n  x BAN の人は空'; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  ok := false; begin insert into user_likes (game_slug) values ('new'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人はいいねを入れられない'; end if;
  ok := false; begin insert into user_history (game_slug, kind) values ('new', 'play'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人は履歴を入れられない'; end if;
  ok := false; begin perform import_local(array['x1'], '[]'::jsonb); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人は import_local できない'; end if;
  ok := false; begin perform likes_public_set(true); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人は公開をオンにできない'; end if;
  perform likes_public_set(false);
  n := n + 1; if (my_profile() ->> 'likes_public') <> 'false' then bad := bad || E'\n  x BAN の人でも非公開には戻せる'; end if;
  -- 自分のいいねは BAN でも消せる
  delete from user_likes where game_slug = 'stack'; get diagnostics c = row_count; n := n + 1; if c <> 1 then bad := bad || E'\n  x BAN でも自分のいいねは消せる'; end if;
  reset role;
  delete from banned_users where user_id = u1;
  -- プロフィールのない人は公開にできない
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  set local role authenticated;
  ok := false; begin perform likes_public_set(true); exception when others then ok := (sqlerrm = 'no_profile'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x プロフィールがない人は no_profile'; end if;
  reset role;

  -- import_local
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  ok := false; begin perform import_local(array['x'], '[]'); exception when others then ok := false; end;
  select count(*) into c from user_likes; n := n + 1; if c <> 1 then bad := bad || E'\n  x import の準備（u2 のいいねは x の1件）（' || c || '）'; end if;
  j := import_local(array['a1','a2','a1','Bad Slug','x', null], jsonb_build_array(
    jsonb_build_object('slug','a1','kind','view','at', (extract(epoch from now() - interval '2 hours') * 1000)::bigint),
    jsonb_build_object('slug','a1','kind','play','seconds',180,'at', to_char((now() - interval '1 hour') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
    jsonb_build_object('slug','a1','kind','play','seconds',180,'at', to_char((now() - interval '1 hour') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
    jsonb_build_object('slug','a2','kind','view','at', (extract(epoch from now() + interval '1 day') * 1000)::bigint),
    jsonb_build_object('slug','Bad','kind','view','at', 1700000000000),
    jsonb_build_object('slug','a3','kind','zzz','at', 1700000000000),
    jsonb_build_object('slug','a4','kind','play','seconds','abc','at', 'ゴミ'),
    jsonb_build_object('slug','a5','kind','play','seconds',999999,'at', 1700000000000),
    '"文字列"'::jsonb, '5'::jsonb));
  n := n + 1; if (j ->> 'likes')::int <> 2 then bad := bad || E'\n  x import のいいね：新規2件（a1,a2。重複・変な slug・既にあるものは除く）（' || j || '）'; end if;
  n := n + 1; if (j ->> 'history')::int <> 3 then bad := bad || E'\n  x import の履歴：3件（view, play, 上限に丸めた play）（' || j || '）'; end if;
  select count(*) into c from user_history where game_slug = 'a2'; n := n + 1; if c <> 0 then bad := bad || E'\n  x 未来の日時は入れない'; end if;
  select count(*) into c from user_history where game_slug = 'a5' and seconds = 86400; n := n + 1; if c <> 1 then bad := bad || E'\n  x 秒数は 86400 に丸める'; end if;
  -- 2回目（同じ中身）は何も増えない
  j := import_local(array['a1','a2'], jsonb_build_array(
    jsonb_build_object('slug','a1','kind','play','seconds',180,'at', to_char((now() - interval '1 hour') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))));
  n := n + 1; if (j ->> 'likes')::int <> 0 or (j ->> 'history')::int <> 0 then bad := bad || E'\n  x 2回目は重複で0件（' || j || '）'; end if;
  -- 上限：いいね250個・履歴250件 → 200ずつ
  select jsonb_agg(jsonb_build_object('slug','h' || g.i,'kind','play','seconds',10,'at', (extract(epoch from now() - make_interval(mins => g.i + 10)) * 1000)::bigint)) into arr from generate_series(1,250) g(i);
  j := import_local((select array_agg('l' || g.i) from generate_series(1,250) g(i)), arr);
  n := n + 1; if (j ->> 'likes')::int <> 200 then bad := bad || E'\n  x いいねは200まで（' || j || '）'; end if;
  n := n + 1; if (j ->> 'history')::int <> 200 then bad := bad || E'\n  x 履歴は200まで（' || j || '）'; end if;
  ok := false; begin perform import_local(null, null); ok := true; exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x null でもエラーにならない'; end if;
  reset role;
  -- ログインなしは呼べない
  set local role anon;
  ok := false; begin perform import_local(array['a'], '[]'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は import_local を呼べない'; end if;
  reset role;

  -- 権限
  n := n + 1; if not has_function_privilege('anon', 'public.public_likes(text)', 'execute') then bad := bad || E'\n  x anon は public_likes を呼べる'; end if;
  n := n + 1; if has_function_privilege('anon', 'public.likes_public_set(boolean)', 'execute') then bad := bad || E'\n  x anon は likes_public_set を呼べない'; end if;
  n := n + 1; if has_table_privilege('anon', 'public.user_history', 'select') or has_table_privilege('authenticated', 'public.user_history', 'update') or has_table_privilege('authenticated', 'public.user_likes', 'update') then bad := bad || E'\n  x 表の権限'; end if;
  -- 利用者が消えたら記録も消える
  delete from auth.users where id = u3;
  select count(*) into c from user_history where user_id = u3; n := n + 1; if c <> 0 then bad := bad || E'\n  x アカウントを消したら履歴も消える'; end if;

  if bad = '' then raise exception 'CHECK_OK 018: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 018: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
