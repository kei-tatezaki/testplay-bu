-- 017 の確認（017_ai_coach.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 017: N件ぜんぶ合格 ／ CHECK_FAILED 017: …
do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  i int; r int; ok boolean; m text; old_lim int;
begin
  insert into auth.users (id, email) values (u1, 'c1-' || u1 || '@example.com'), (u2, 'c2-' || u2 || '@example.com'), (u3, 'c3-' || u3 || '@example.com');
  perform set_config('request.jwt.claim.sub', u1::text, true);

  n := n + 1; if setting_int('ai_coach_daily_limit', -1) <> 20 then bad := bad || E'\n  x 既定の上限は20'; end if;
  n := n + 1; if ai_coach_take() <> 19 then bad := bad || E'\n  x 1回目の残りは19'; end if;
  for i in 2..20 loop r := ai_coach_take(); end loop;
  n := n + 1; if r <> 0 then bad := bad || E'\n  x 20回目の残りは0（いま ' || r || '）'; end if;
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 21回目は例外 limit'; end if;
  n := n + 1; if (select count from ai_coach_uses where user_id = u1 and day = mission_day()) <> 20 then bad := bad || E'\n  x 失敗した21回目は数えない（20のまま）'; end if;

  -- 返す：1回返すと、もう1回取れる
  perform ai_coach_refund();
  n := n + 1; if ai_coach_take() <> 0 then bad := bad || E'\n  x refund のあと1回取れる（残り0）'; end if;

  -- 別の日・別の人は別に数える
  insert into ai_coach_uses (user_id, day, count) values (u2, mission_day() - 1, 20);
  perform set_config('request.jwt.claim.sub', u2::text, true);
  n := n + 1; if ai_coach_take() <> 19 then bad := bad || E'\n  x 前の日に20回使っていても、今日は19残る'; end if;

  -- 上限は settings で変えられる
  update settings set value = 2 where key = 'ai_coach_daily_limit';
  perform set_config('request.jwt.claim.sub', u3::text, true);
  n := n + 1; if ai_coach_take() <> 1 then bad := bad || E'\n  x 上限2のとき1回目の残りは1'; end if;
  perform ai_coach_take();
  ok := false; begin perform ai_coach_take(); exception when others then ok := (sqlerrm = 'limit'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 上限2のとき3回目は limit'; end if;

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
  n := n + 1; if has_function_privilege('anon', 'public.ai_coach_take()', 'execute') then bad := bad || E'\n  x anon は呼べない'; end if;
  n := n + 1; if has_table_privilege('authenticated', 'public.ai_coach_uses', 'select') then bad := bad || E'\n  x ai_coach_uses は直接読めない'; end if;

  if bad = '' then raise exception 'CHECK_OK 017: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 017: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
