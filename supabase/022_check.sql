-- 022 の確認（022_result_card.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 022: N件ぜんぶ合格 ／ CHECK_FAILED 022: …
do $chk$
declare
  n int := 0; bad text := '';
  uo uuid := gen_random_uuid(); ux uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); ul uuid := gen_random_uuid(); ua uuid := gen_random_uuid();
  j jsonb; ok boolean; c int; i int; fa uuid; fb uuid; fh uuid; fo uuid; fother uuid; fbn uuid; flz uuid; fe uuid; q jsonb;
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[uo, ux, ub, ul, ua]) x;
  insert into admins (user_id) values (ua);
  insert into game_owners (game_slug, user_id) values ('gx', uo);
  insert into game_owners (game_slug, user_id) values ('gy', uo);

  -- ================= 数が少ない（遊んだ4人・感想4件）：割合は null、数は出る =================
  for i in 1..4 loop
    insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'play-client-000' || i);
    insert into play_sessions (game_slug, client_id, seconds, device) values ('gx', 'play-client-000' || i, 60 * i, 'pc');
    insert into feedback (game_slug, again, reach, answer, free, client_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', '', 'fb-client-000' || i);
  end loop;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'plays')::int <> 4 or (j ->> 'sessions')::int <> 4 or (j ->> 'feedbacks')::int <> 4 then bad := bad || E'\n  x 少なくても数は出る（' || j || '）'; end if;
  n := n + 1; if j -> 'again_pct' <> 'null'::jsonb or j -> 'answer_pct' <> 'null'::jsonb or j -> 'median_seconds' <> 'null'::jsonb or j -> 'fi_pct' <> 'null'::jsonb then bad := bad || E'\n  x 5未満は割合・真ん中が null（' || j || '）'; end if;
  n := n + 1; if (j ->> 'again_n')::int <> 4 then bad := bad || E'\n  x 母数（' || j || '）'; end if;

  -- ================= 5件になると出る。hidden・BAN・作者本人・lazy は数えない =================
  insert into feedback (game_slug, again, reach, answer, free, client_id) values ('gx', 'もういいかな', '途中でやめた', 'いいえ', 'あまり合わなかったです', 'fb-client-0005') returning id into fb;
  insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'play-client-0005');
  insert into play_sessions (game_slug, client_id, seconds, device) values ('gx', 'play-client-0005', 300, 'sp');
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'again_pct')::int <> 80 or (j ->> 'again_n')::int <> 5 then bad := bad || E'\n  x 5件で割合（4/5=80）（' || j || '）'; end if;
  n := n + 1; if (j ->> 'answer_pct')::int <> 80 or (j ->> 'answer_n')::int <> 5 then bad := bad || E'\n  x 作者の質問のはいの割合（4/5=80）（' || j || '）'; end if;
  n := n + 1; if (j ->> 'median_seconds')::int <> 180 then bad := bad || E'\n  x 遊んだ時間の真ん中（60,120,180,240,300→180）（' || j || '）'; end if;
  n := n + 1; if (j ->> 'plays')::int <> 5 or (j ->> 'sessions')::int <> 5 then bad := bad || E'\n  x 人数・回数（' || j || '）'; end if;

  -- hidden は数えない
  insert into feedback (game_slug, again, reach, answer, free, client_id, hidden) values ('gx', 'すごく遊びたい', '最後まで', 'はい', 'ひみつ', 'fb-client-hid1', false) returning id into fh;
  update feedback set hidden = true where id = fh;
  -- BAN された端末の感想・遊んだ記録は数えない
  insert into feedback (game_slug, again, reach, answer, free, client_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', 'BANされる人', 'fb-client-ban1') returning id into fbn;
  insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'fb-client-ban1');
  insert into play_sessions (game_slug, client_id, seconds) values ('gx', 'fb-client-ban1', 9999);
  insert into banned_clients (client_id) values ('fb-client-ban1');
  -- 作者本人の感想は数えない
  insert into feedback (game_slug, again, reach, answer, free, client_id, user_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', '作者の感想', 'fb-client-own1', uo) returning id into fo;
  -- BAN されたアカウントの感想は数えない（BAN は後から付ける）
  insert into feedback (game_slug, again, reach, answer, free, client_id, user_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', 'BANアカウント', 'fb-client-ban2', ub);
  insert into banned_users (user_id) values (ub);
  -- lazy（ポイントの記録で lazy とされた）感想は数えない
  insert into feedback (game_slug, again, reach, answer, free, client_id, user_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', repeat('あ', 45), 'fb-client-lzy1', ul) returning id into flz;
  select count(*) into c from points_ledger where ref = flz and note = 'lazy'; n := n + 1; if c <> 1 then bad := bad || E'\n  x （前提）lazy の記録ができている（' || c || '）'; end if;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'feedbacks')::int <> 5 or (j ->> 'again_pct')::int <> 80 or (j ->> 'answer_n')::int <> 5 then bad := bad || E'\n  x hidden・BAN・作者本人・lazy は数えない（' || j || '）'; end if;
  n := n + 1; if (j ->> 'plays')::int <> 5 or (j ->> 'sessions')::int <> 5 or (j ->> 'median_seconds')::int <> 180 then bad := bad || E'\n  x BAN の端末の遊んだ記録は数えない（' || j || '）'; end if;

  -- いいね（端末ごとに1人）
  insert into game_events (game_slug, kind, client_id) values ('gx', 'like', 'play-client-0001'), ('gx', 'like', 'play-client-0002');
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'likes')::int <> 2 then bad := bad || E'\n  x いいね数（' || j || '）'; end if;

  -- 第一印象：4件では null、5件で出る（遊びたい=3 の割合）
  for i in 1..4 loop
    insert into first_impressions (game_slug, client_id, level) values ('gx', 'fi-client-000' || i, case when i <= 3 then 3 else 1 end);
  end loop;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if j -> 'fi_pct' <> 'null'::jsonb or (j ->> 'fi_n')::int <> 4 then bad := bad || E'\n  x 第一印象 4件は null（' || j || '）'; end if;
  insert into first_impressions (game_slug, client_id, level) values ('gx', 'fi-client-0005', 2);
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'fi_pct')::int <> 60 or (j ->> 'fi_n')::int <> 5 then bad := bad || E'\n  x 第一印象 5件で 3/5=60（' || j || '）'; end if;

  -- 集計期間と集計した日時
  n := n + 1; if j ->> 'first_day' is null or j ->> 'last_day' is null or j ->> 'generated_at' is null or (j ->> 'first_day') > (j ->> 'last_day') then bad := bad || E'\n  x 期間と集計した日時（' || j || '）'; end if;

  -- 何もない作品でも落ちない（人数0・割合 null）
  set local role anon; j := public_result('nothing'); reset role;
  n := n + 1; if (j ->> 'plays')::int <> 0 or j -> 'again_pct' <> 'null'::jsonb or j -> 'first_day' <> 'null'::jsonb or jsonb_array_length(j -> 'quotes') <> 0 then bad := bad || E'\n  x データなしの作品（' || j || '）'; end if;
  ok := false; begin perform public_result('BAD SLUG!'); exception when others then ok := (sqlerrm = 'bad_slug'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x slug の形が違う（bad_slug）'; end if;

  -- ================= 印象的な感想 =================
  select id into fa from feedback where client_id = 'fb-client-0001';
  update feedback set free = repeat('あいうえお', 30) || 'ここは出ない' where id = fa;
  insert into feedback (game_slug, again, reach, free, client_id) values ('gy', 'すごく遊びたい', '最後まで', 'ほかの作品の感想', 'fb-client-other') returning id into fother;
  -- 作者以外は選べない
  perform set_config('request.jwt.claim.sub', ux::text, true);
  set local role authenticated;
  ok := false; begin perform dev_result_quote_set('gx', fa, 1); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者以外は選べない（not_allowed）'; end if;
  ok := false; begin perform dev_result_quote_clear('gx', 1); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者以外は外せない'; end if;
  ok := false; begin perform dev_result_quotes('gx'); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者以外は選択を読めない'; end if;
  reset role;
  -- 運営でも、作者として登録されていなければ選べない
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated;
  ok := false; begin perform dev_result_quote_set('gx', fa, 1); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者でない運営は選べない'; end if;
  reset role;
  -- 未ログイン（anon）は呼べない
  n := n + 1; if has_function_privilege('anon', 'public.dev_result_quote_set(text,uuid,integer)', 'execute') or has_function_privilege('anon', 'public.dev_result_quote_clear(text,integer)', 'execute') or has_function_privilege('anon', 'public.dev_result_quotes(text)', 'execute') or has_function_privilege('anon', 'public.admin_set_game_rating(text,text)', 'execute') then bad := bad || E'\n  x anon は作者・運営の関数を呼べない'; end if;
  n := n + 1; if not has_function_privilege('anon', 'public.public_result(text)', 'execute') then bad := bad || E'\n  x anon は public_result を呼べる'; end if;
  n := n + 1; if has_table_privilege('anon', 'public.result_quotes', 'select') or has_table_privilege('authenticated', 'public.result_quotes', 'select') or has_table_privilege('authenticated', 'public.result_quotes', 'insert')
                or has_table_privilege('authenticated', 'public.game_ratings', 'select') then bad := bad || E'\n  x 表への直接の権限はない'; end if;

  -- 作者は選べる。ただし、よその作品の感想・hidden・本文が空の感想・位置4は選べない
  perform set_config('request.jwt.claim.sub', uo::text, true);
  set local role authenticated;
  perform dev_result_quote_set('gx', fa, 1);
  perform dev_result_quote_set('gx', fb, 2);
  ok := false; begin perform dev_result_quote_set('gx', fother, 3); exception when others then ok := (sqlerrm = 'bad_feedback'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x ほかの作品の感想は選べない'; end if;
  ok := false; begin perform dev_result_quote_set('gx', fh, 3); exception when others then ok := (sqlerrm = 'bad_feedback'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x hidden の感想は選べない'; end if;
  select id into fe from feedback where client_id = 'fb-client-0002';  -- 本文が空
  ok := false; begin perform dev_result_quote_set('gx', fe, 3); exception when others then ok := (sqlerrm = 'bad_feedback'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 本文が空の感想は選べない'; end if;
  ok := false; begin perform dev_result_quote_set('gx', fa, 4); exception when others then ok := (sqlerrm = 'bad_position'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 位置は1〜3（bad_position）'; end if;
  ok := false; begin perform dev_result_quote_set('gx', fbn, 3); exception when others then ok := (sqlerrm = 'bad_feedback'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN の端末の感想は選べない'; end if;
  select count(*) into c from dev_result_quotes('gx'); n := n + 1; if c <> 2 then bad := bad || E'\n  x 作者は選択を読める（' || c || '）'; end if;
  -- 同じ感想を別の位置にすると、移る（重ならない）
  perform dev_result_quote_set('gx', fa, 3);
  select count(*) into c from dev_result_quotes('gx'); n := n + 1; if c <> 2 then bad := bad || E'\n  x 同じ感想は1か所だけ（' || c || '）'; end if;
  perform dev_result_quote_set('gx', fa, 1);
  reset role;

  set local role anon; j := public_result('gx'); reset role;
  q := j -> 'quotes';
  n := n + 1; if jsonb_array_length(q) <> 2 or (q -> 0 ->> 'pos') <> '1' or (q -> 1 ->> 'pos') <> '2' then bad := bad || E'\n  x 選んだ感想が位置順に出る（' || q || '）'; end if;
  n := n + 1; if char_length(q -> 0 ->> 'text') <> 120 or (q -> 0 ->> 'truncated') <> 'true' or (q -> 0 ->> 'text') like '%ここは出ない%' then bad := bad || E'\n  x 本文は先頭120字まで（' || char_length(q -> 0 ->> 'text') || '）'; end if;
  n := n + 1; if (q -> 1 ->> 'truncated') <> 'false' or (q -> 1 ->> 'text') <> 'あまり合わなかったです' then bad := bad || E'\n  x 短い感想はそのまま（' || q -> 1 || '）'; end if;
  -- 名前・端末ID・アカウントは出ない
  n := n + 1; if j::text like '%fb-client%' or j::text like '%' || uo::text || '%' or (q -> 0) ?| array['client_id', 'user_id', 'name', 'id', 'feedback_id'] then bad := bad || E'\n  x 感想から名前・IDが出ていない（' || q || '）'; end if;
  -- あとから hidden になった感想は、カードから消える
  update feedback set hidden = true where id = fb;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if jsonb_array_length(j -> 'quotes') <> 1 then bad := bad || E'\n  x hidden にした感想はカードに出ない（' || (j -> 'quotes') || '）'; end if;
  update feedback set hidden = false where id = fb;
  -- 外す
  perform set_config('request.jwt.claim.sub', uo::text, true);
  set local role authenticated; perform dev_result_quote_clear('gx', 1); reset role;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if jsonb_array_length(j -> 'quotes') <> 1 then bad := bad || E'\n  x 外すと減る（' || (j -> 'quotes') || '）'; end if;
  -- 感想が消えたら選択も消える
  delete from feedback where id = fb;
  select count(*) into c from result_quotes where game_slug = 'gx'; n := n + 1; if c <> 0 then bad := bad || E'\n  x 感想が消えたら選択も消える（' || c || '）'; end if;

  -- ================= R18 は空 =================
  perform set_config('request.jwt.claim.sub', ux::text, true);
  set local role authenticated;
  ok := false; begin perform admin_set_game_rating('gx', 'r18'); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 運営でなければ年齢制限を付けられない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated; perform admin_set_game_rating('gx', 'r18'); reset role;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'blocked') <> 'true' or j ? 'plays' or j ? 'quotes' or j ? 'feedbacks' then bad := bad || E'\n  x R18 は数字も感想も返さない（' || j || '）'; end if;
  -- R15 は返す
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated; perform admin_set_game_rating('gx', 'r15'); reset role;
  set local role anon; j := public_result('gx'); reset role;
  n := n + 1; if (j ->> 'blocked') <> 'false' or (j ->> 'plays')::int <> 5 then bad := bad || E'\n  x R15 は返す（' || j || '）'; end if;
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated; perform admin_set_game_rating('gx', ''); reset role;
  select count(*) into c from game_ratings; n := n + 1; if c <> 0 then bad := bad || E'\n  x 空で印を外せる（' || c || '）'; end if;

  if bad = '' then raise exception 'CHECK_OK 022: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 022: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
