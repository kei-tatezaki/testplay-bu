-- 019 の確認（019_follows.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 019: N件ぜんぶ合格 ／ CHECK_FAILED 019: …
do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  u4 uuid := gen_random_uuid(); u5 uuid := gen_random_uuid(); ub uuid := gen_random_uuid();
  c int; ok boolean; j jsonb; msg text; b boolean; r record; arr text[];
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[u1,u2,u3,u4,u5,ub]) x;
  insert into profiles (user_id, handle, name, bio) values (u1, 'alice', 'アリス', 'こんにちは'), (u2, 'bob', 'ボブ', ''), (u3, 'carol', 'キャロル', ''),
    (u4, 'dave', 'デイブ', ''), (ub, 'banned_b', 'バン', '');
  insert into banned_users (user_id) values (ub);

  -- ---- u1 として：フォローする ----
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  j := follow_set('bob', true);
  n := n + 1; if (j ->> 'following')::boolean is not true or (j ->> 'followers')::int <> 1 then bad := bad || E'\n  x follow_set の返り値（' || j || '）'; end if;
  j := follow_set('bob', true);   -- 二重でもエラーにならない
  n := n + 1; if (j ->> 'followers')::int <> 1 then bad := bad || E'\n  x 二重フォローで数が増えない（' || j || '）'; end if;
  perform follow_set('carol', true);
  select follow_state('bob') into b; n := n + 1; if b is not true then bad := bad || E'\n  x follow_state が true'; end if;
  select follow_state('dave') into b; n := n + 1; if b is not false then bad := bad || E'\n  x follow_state が false'; end if;
  select count(*) into c from follows; n := n + 1; if c <> 2 then bad := bad || E'\n  x 自分の行が見える（' || c || '）'; end if;
  ok := false; begin perform follow_set('alice', true); exception when others then ok := (sqlerrm = 'self'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 自分はフォローできない（self）'; end if;
  ok := false; begin perform follow_set('nobody', true); exception when others then ok := (sqlerrm = 'no_such_user'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x いない人はフォローできない'; end if;
  ok := false; begin insert into follows (follower, followee) values (u1, u1); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 表の check：自分を自分でフォローできない'; end if;
  -- なりすまし
  ok := false; begin insert into follows (follower, followee) values (u2, u3); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 他人になりすましてフォローできない'; end if;
  ok := false; begin update follows set followee = u4; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x update は権限がない'; end if;
  reset role;

  -- ---- u2（フォローされる側）：自分に向いた行は見える・消せない ----
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  select count(*) into c from follows; n := n + 1; if c <> 1 then bad := bad || E'\n  x フォローされた側にも、自分に向いた行は見える（' || c || '）'; end if;
  delete from follows; get diagnostics c = row_count; n := n + 1; if c <> 0 then bad := bad || E'\n  x フォローされた側は、相手のフォローを消せない'; end if;
  reset role;
  -- ---- u3：関係のない行は見えない ----
  perform set_config('request.jwt.claim.sub', u4::text, true);
  set local role authenticated;
  select count(*) into c from follows; n := n + 1; if c <> 0 then bad := bad || E'\n  x 関係のない行は見えない（' || c || '）'; end if;
  reset role;

  -- ---- 数・一覧（anon でも見える） ----
  set local role anon;
  select * into r from follow_counts('bob'); n := n + 1; if r.followers <> 1 or r.following <> 0 then bad := bad || E'\n  x bob の数（' || r.followers || '/' || r.following || '）'; end if;
  select * into r from follow_counts('alice'); n := n + 1; if r.following <> 2 or r.followers <> 0 then bad := bad || E'\n  x alice の数'; end if;
  select count(*) into c from follow_counts('nobody'); n := n + 1; if c <> 0 then bad := bad || E'\n  x いない人の数は返さない'; end if;
  select count(*) into c from followers_list('bob'); n := n + 1; if c <> 1 then bad := bad || E'\n  x followers_list'; end if;
  select array_agg(handle order by handle) into arr from following_list('alice'); n := n + 1; if arr is distinct from array['bob','carol'] then bad := bad || E'\n  x following_list（' || coalesce(arr::text, 'null') || '）'; end if;
  select followers_list.handle, followers_list.name, followers_list.bio into r from followers_list('bob');
  n := n + 1; if r.handle <> 'alice' or r.name <> 'アリス' then bad := bad || E'\n  x 一覧の中身'; end if;
  select follow_state('bob') into b; n := n + 1; if b is not false then bad := bad || E'\n  x anon の follow_state は false'; end if;
  ok := false; begin perform follow_set('bob', true); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は follow_set を呼べない'; end if;
  ok := false; begin perform my_following_handles(); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は my_following_handles を呼べない'; end if;
  select count(*) into c from followers_list('bob', 1000, -5); n := n + 1; if c <> 1 then bad := bad || E'\n  x limit/offset の範囲'; end if;
  reset role;

  -- ---- 非表示・BAN の人は数にも一覧にも出ない ----
  update profiles set hidden = true where handle = 'carol';
  set local role anon;
  select * into r from follow_counts('alice'); n := n + 1; if r.following <> 1 then bad := bad || E'\n  x 非表示の人は数に入れない（' || r.following || '）'; end if;
  select count(*) into c from following_list('alice'); n := n + 1; if c <> 1 then bad := bad || E'\n  x 非表示の人は一覧に出ない'; end if;
  select count(*) into c from follow_counts('carol'); n := n + 1; if c <> 0 then bad := bad || E'\n  x 非表示の人の数は返さない'; end if;
  reset role;
  update profiles set hidden = false where handle = 'carol';
  -- BAN の人は、フォローできない（解除はできる）。BAN になる前のフォローは、数と一覧から消える
  perform set_config('request.jwt.claim.sub', ub::text, true);
  set local role authenticated;
  ok := false; begin perform follow_set('bob', true); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人はフォローできない'; end if;
  ok := false; begin insert into follows (follower, followee) values (ub, u2); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の人は表にも直接入れられない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  insert into follows (follower, followee) values (ub, u2);   -- BAN される前にあったことにする（管理者権限で）
  select * into r from follow_counts('bob'); n := n + 1; if r.followers <> 1 then bad := bad || E'\n  x BAN の人はフォロワーに数えない（' || r.followers || '）'; end if;
  perform set_config('request.jwt.claim.sub', ub::text, true);
  set local role authenticated;
  perform follow_set('bob', false); select count(*) into c from follows; n := n + 1; if c <> 0 then bad := bad || E'\n  x BAN の人も解除はできる'; end if;
  reset role;

  -- ---- プロフィールのない人はフォローできない ----
  perform set_config('request.jwt.claim.sub', u5::text, true);
  set local role authenticated;
  ok := false; begin perform follow_set('bob', true); exception when others then ok := (sqlerrm = 'need_profile'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x プロフィールがない人はフォローできない（need_profile）'; end if;
  reset role;

  -- ---- フォロー中の作者の作品 ----
  perform set_config('request.jwt.claim.sub', '', true);
  insert into game_owners (game_slug, user_id) values ('g-bob1', u2), ('g-bob2', u2), ('g-carol', u3), ('g-dave', u4);
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  select array_agg(game_slug order by game_slug) into arr from my_following_slugs();
  n := n + 1; if arr is distinct from array['g-bob2','g-bob1','g-carol']::text[] and arr is distinct from array['g-bob1','g-bob2','g-carol']::text[] then bad := bad || E'\n  x my_following_slugs（' || coalesce(arr::text,'null') || '）'; end if;
  select count(*) into c from my_following_slugs() where handle = 'dave'; n := n + 1; if c <> 0 then bad := bad || E'\n  x フォローしていない作者の作品は出ない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  update profiles set hidden = true where handle = 'carol';
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  select count(*) into c from my_following_slugs() where handle = 'carol'; n := n + 1; if c <> 0 then bad := bad || E'\n  x 非表示の作者の作品は出ない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  update profiles set hidden = false where handle = 'carol';
  set local role anon;
  ok := false; begin perform my_following_slugs(); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は my_following_slugs を呼べない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', u1::text, true);

  -- ---- 解除 ----
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  j := follow_set('bob', false); n := n + 1; if (j ->> 'following')::boolean is not false or (j ->> 'followers')::int <> 0 then bad := bad || E'\n  x 解除（' || j || '）'; end if;
  select count(*) into c from my_following_handles(); n := n + 1; if c <> 1 then bad := bad || E'\n  x my_following_handles（' || c || '）'; end if;
  reset role;

  -- ---- 1分に30回まで（フォローと解除をあわせて数える） ----
  -- ここまでの u1 の操作：follow_set 4回（bob 2回目は何もしない→bob,carol,解除の3回）。いったん記録を空にして数える
  perform set_config('request.jwt.claim.sub', '', true);
  delete from follow_log where user_id = u1;
  delete from follows where follower = u1;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  for c in 1..14 loop perform follow_set('bob', true); perform follow_set('bob', false); end loop;   -- 28回
  perform follow_set('bob', true); perform follow_set('carol', true);                                  -- 30回
  ok := false; begin perform follow_set('dave', true); exception when others then ok := (sqlerrm = 'too_fast'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 1分に30回をこえたら too_fast'; end if;
  ok := false; begin perform follow_set('bob', false); exception when others then ok := (sqlerrm = 'too_fast'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 解除も too_fast に数える'; end if;
  reset role;
  -- 1分たてば、また操作できる
  update follow_log set at = now() - interval '2 minutes' where user_id = u1;
  set local role authenticated;
  ok := true; begin perform follow_set('bob', true); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 1分たてば、また操作できる'; end if;
  reset role;
  -- 別の人の操作には影響しない
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  ok := true; begin perform follow_set('bob', true); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 制限は人ごと'; end if;
  reset role;

  -- ---- 1000人まで ----
  perform set_config('request.jwt.claim.sub', '', true);
  delete from follow_log; delete from follows where follower = u1;
  insert into auth.users (id, email) select gen_random_uuid(), 'x' || g.i || '@example.com' from generate_series(1, 1000) g(i);
  insert into follows (follower, followee) select u1, id from auth.users where email like 'x%@example.com';   -- 管理者権限（トリガーは auth.uid() が空なので素通り）
  select count(*) into c from follows where follower = u1; n := n + 1; if c <> 1000 then bad := bad || E'\n  x 準備（' || c || '）'; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  ok := false; begin insert into follows (follower, followee) values (u1, u2); exception when others then ok := (sqlerrm = 'follow_limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 1001人目は follow_limit'; end if;
  reset role;

  -- ---- 権限 ----
  n := n + 1; if not has_function_privilege('anon', 'public.follow_counts(text)', 'execute') or not has_function_privilege('anon', 'public.followers_list(text,int,int)', 'execute') then bad := bad || E'\n  x anon は数と一覧を呼べる'; end if;
  n := n + 1; if has_function_privilege('anon', 'public.follow_set(text,boolean)', 'execute') or has_function_privilege('anon', 'public.my_following_handles()', 'execute') then bad := bad || E'\n  x anon は follow_set を呼べない'; end if;
  n := n + 1; if has_table_privilege('anon', 'public.follows', 'select') or has_table_privilege('authenticated', 'public.follows', 'update') or has_table_privilege('authenticated', 'public.follow_log', 'select') then bad := bad || E'\n  x 表の権限'; end if;
  -- 利用者が消えたら、フォローも消える（消す人が auth.uid() でなくても止まらない）
  delete from auth.users where id = u3;
  select count(*) into c from follows where follower = u3 or followee = u3; n := n + 1; if c <> 0 then bad := bad || E'\n  x アカウントを消したらフォローも消える'; end if;
  delete from auth.users where id = u2;
  select count(*) into c from follows where followee = u2; n := n + 1; if c <> 0 then bad := bad || E'\n  x フォローされた側が消えても消える'; end if;

  if bad = '' then raise exception 'CHECK_OK 019: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 019: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
