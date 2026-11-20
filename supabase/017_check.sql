-- 017 の確認（017_ai_coach.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 017: N件ぜんぶ合格 ／ CHECK_FAILED 017: …
do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid(); adm uuid := gen_random_uuid();
  i int; r int; ok boolean; rows_ record; cnt int;
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[u1,u2,u3,u4,adm]) x;
  perform set_config('request.jwt.claim.sub', u1::text, true);

  n := n + 1; if setting_int('ai_coach_daily_limit', -1) <> 30 then bad := bad || E'\n  x 既定の上限は30'; end if;
  n := n + 1; if exists (select 1 from settings where key like '%global%') then bad := bad || E'\n  x 全体の上限は作らない'; end if;
  n := n + 1; if ai_coach_take() <> 29 then bad := bad || E'\n  x 1回目の残りは29'; end if;

  -- 連打：直近60秒に6回まで。7回目は too_fast（失敗した回は数えない）
  for i in 2..6 loop r := ai_coach_take(); end loop;
  n := n + 1; if r <> 24 then bad := bad || E'\n  x 6回目の残りは24（いま ' || r || '）'; end if;
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'too_fast'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 60秒に7回目は too_fast'; end if;
  n := n + 1; if (select count from ai_coach_uses where user_id = u1 and day = mission_day()) <> 6 then bad := bad || E'\n  x 断った回は数えない（6のまま）'; end if;
  -- 60秒より前の記録は連打に数えない
  update ai_coach_log set at = now() - interval '61 seconds' where user_id = u1;
  n := n + 1; if ai_coach_take() <> 23 then bad := bad || E'\n  x 61秒前の記録は連打に数えない'; end if;
  -- refund：回数と記録を1つ戻す
  perform ai_coach_refund();
  n := n + 1; if (select count from ai_coach_uses where user_id = u1 and day = mission_day()) <> 6 then bad := bad || E'\n  x refund で回数が1戻る'; end if;
  n := n + 1; if (select count(*) from ai_coach_log where user_id = u1) <> 6 then bad := bad || E'\n  x refund で記録も1行戻る（7→6）'; end if;

  -- 1日の上限（既定30）
  update ai_coach_log set at = now() - interval '1 day' where user_id = u1;
  update ai_coach_uses set count = 29 where user_id = u1 and day = mission_day();
  n := n + 1; if ai_coach_take() <> 0 then bad := bad || E'\n  x 30回目の残りは0'; end if;
  update ai_coach_log set at = now() - interval '1 day' where user_id = u1;
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 31回目は limit'; end if;
  -- 別の日・別の人は別に数える
  insert into ai_coach_uses (user_id, day, count) values (u2, mission_day() - 1, 20);
  perform set_config('request.jwt.claim.sub', u2::text, true);
  n := n + 1; if ai_coach_take() <> 29 then bad := bad || E'\n  x 前の日に20回使っていても、今日は29残る'; end if;

  -- 7日より古い記録は、take のたびに消える
  insert into ai_coach_log (user_id, at) values (u3, now() - interval '8 days'), (u3, now() - interval '6 days');
  perform set_config('request.jwt.claim.sub', u3::text, true);
  perform ai_coach_take();
  n := n + 1; if (select count(*) from ai_coach_log where user_id = u3) <> 2 or exists (select 1 from ai_coach_log where at < now() - interval '7 days') then bad := bad || E'\n  x 8日前の記録だけ消える（6日前は残る）'; end if;

  -- 既定の値を変える（settings）
  update settings set value = 2 where key = 'ai_coach_daily_limit';
  update ai_coach_log set at = now() - interval '1 day' where user_id = u3;
  n := n + 1; if ai_coach_take() <> 0 then bad := bad || E'\n  x 既定2・u3は1回使用済み→2回目で残り0'; end if;
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 既定2のとき3回目は limit'; end if;

  -- アカウント別の上書き（運営だけ）
  n := n + 1; ok := false; begin perform admin_ai_limit_set(u3, 5, 'x'); exception when others then ok := (sqlerrm = 'not_admin'); end;
  if not ok then bad := bad || E'\n  x 運営でない人は上限を変えられない'; end if;
  ok := false; begin perform admin_ai_usage(7); exception when others then ok := (sqlerrm = 'not_admin'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 運営でない人は利用を見られない'; end if;
  insert into admins (user_id) values (adm);
  perform set_config('request.jwt.claim.sub', adm::text, true);
  perform admin_ai_limit_set(u3, 5, '先生のテスト');
  n := n + 1; if (select daily_limit from ai_coach_limits where user_id = u3) <> 5 then bad := bad || E'\n  x 上書きが保存される'; end if;
  ok := false; begin perform admin_ai_limit_set(u3, -1, null); exception when others then ok := (sqlerrm = 'bad_value'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 負の上限は bad_value'; end if;
  perform set_config('request.jwt.claim.sub', u3::text, true);
  update ai_coach_log set at = now() - interval '1 day' where user_id = u3;
  n := n + 1; if ai_coach_take() <> 2 then bad := bad || E'\n  x 上書き5・使用済み2→3回目で残り2（いま ' || coalesce((select count from ai_coach_uses where user_id=u3 and day=mission_day()),-1) || '）'; end if;
  -- 0 で停止
  perform set_config('request.jwt.claim.sub', adm::text, true);
  perform admin_ai_limit_set(u3, 0, '停止');
  perform set_config('request.jwt.claim.sub', u3::text, true);
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 上限0は停止（limit）'; end if;
  -- 解除すると既定（2）に戻る
  perform set_config('request.jwt.claim.sub', adm::text, true);
  perform admin_ai_limit_clear(u3);
  n := n + 1; if exists (select 1 from ai_coach_limits where user_id = u3) then bad := bad || E'\n  x 解除で上書きが消える'; end if;

  -- 利用の一覧
  select * into rows_ from admin_ai_usage(7) where user_id = u1;
  n := n + 1; if rows_.today is distinct from 30 or rows_.total is distinct from 30 or rows_.daily_limit <> 2 or rows_.has_override then bad := bad || E'\n  x admin_ai_usage：u1 は今日30・合計30・上限（既定）2'; end if;
  perform admin_ai_limit_set(u4, 7, null);
  select * into rows_ from admin_ai_usage(7) a where a.user_id = u4;
  n := n + 1; if rows_.user_id is null or rows_.today <> 0 or rows_.daily_limit <> 7 or not rows_.has_override then bad := bad || E'\n  x 使っていなくても、上書きのある人は一覧に出る'; end if;
  n := n + 1; if (select user_id from admin_ai_usage(7) limit 1) <> u1 then bad := bad || E'\n  x 利用の多い順（先頭は u1）'; end if;
  n := n + 1; if admin_ai_today() < 31 then bad := bad || E'\n  x admin_ai_today は今日の全体の合計'; end if;

  -- ログインなし・BAN
  perform set_config('request.jwt.claim.sub', '', true);
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'login'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 未ログインは login'; end if;
  insert into banned_users (user_id) values (u2) on conflict do nothing;
  perform set_config('request.jwt.claim.sub', u2::text, true);
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BANされた人は banned'; end if;

  -- 権限
  n := n + 1; if not has_function_privilege('authenticated', 'public.ai_coach_take()', 'execute') then bad := bad || E'\n  x authenticated は ai_coach_take を呼べる'; end if;
  n := n + 1; if has_function_privilege('anon', 'public.ai_coach_take()', 'execute') or has_function_privilege('anon', 'public.admin_ai_usage(int)', 'execute') then bad := bad || E'\n  x anon は呼べない'; end if;
  n := n + 1; if has_table_privilege('authenticated', 'public.ai_coach_uses', 'select') or has_table_privilege('authenticated', 'public.ai_coach_limits', 'select') or has_table_privilege('authenticated', 'public.ai_coach_log', 'select') then bad := bad || E'\n  x 表は直接読めない'; end if;

  if bad = '' then raise exception 'CHECK_OK 017: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 017: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
