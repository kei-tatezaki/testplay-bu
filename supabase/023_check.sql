-- 023 の確認（023_security.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 023: N件ぜんぶ合格 ／ CHECK_FAILED 023: …
do $chk$
declare
  n int := 0; bad text := ''; i int; r text; ua uuid := gen_random_uuid(); uu uuid := gen_random_uuid(); j jsonb;
  hdr text := '{"x-forwarded-for":"203.0.113.7, 10.0.0.1"}';
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[ua, uu]) x;
  insert into admins (user_id) values (ua);
  update settings set value = 0 where key = 'read_only';

  -- ---------- 指紋：IPそのものは出てこない、同じIPなら同じ、違うIPなら違う ----------
  perform set_config('request.headers', hdr, true);
  r := req_ip_key();
  n := n + 1; if r is null or length(r) <> 16 or r like '%203%' then bad := bad || E'\n  x 指紋は16文字でIPを含まない（' || coalesce(r, 'null') || '）'; end if;
  perform set_config('request.headers', '{"x-forwarded-for":"198.51.100.9"}', true);
  n := n + 1; if req_ip_key() = r then bad := bad || E'\n  x 違うIPなら違う指紋'; end if;
  perform set_config('request.headers', '', true);
  n := n + 1; if req_ip_key() is not null then bad := bad || E'\n  x ヘッダーがなければ null'; end if;

  -- ---------- SQLエディタ（役割なし）は数えない ----------
  for i in 1..200 loop insert into play_sessions (game_slug, client_id, seconds) values ('gx', 'editor-client-01', 10); end loop;
  n := n + 1; if exists (select 1 from rate_hits where k = 'editor-client-01') then bad := bad || E'\n  x 役割なしは数えない'; end if;

  -- ---------- ログインなしの同じ端末（遊んだ時間の記録は150）：150回まで、151回目で止まる ----------
  perform set_config('request.headers', hdr, true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    for i in 1..150 loop insert into play_sessions (game_slug, client_id, seconds) values ('gx', 'spam-client-0001', 10); end loop;
    r := 'ok';
  exception when others then r := 'ERR ' || sqlerrm || ' at ' || i; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x 150回までは通る（' || r || '）'; end if;
  begin insert into play_sessions (game_slug, client_id, seconds) values ('gx', 'spam-client-0001', 10); r := 'ok';
  exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'too_many' then bad := bad || E'\n  x 151回目は too_many（' || r || '）'; end if;
  -- 別の端末なら同じネットワークでも通る
  begin insert into play_sessions (game_slug, client_id, seconds) values ('gx', 'other-client-0001', 10); r := 'ok';
  exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x 別の端末は通る（' || r || '）'; end if;

  -- ---------- 同じネットワークの上限（site_visits は500）：端末を変えても501人目で止まる ----------
  begin
    for i in 1..500 loop insert into site_visits (client_id) values ('visit-client-' || lpad(i::text, 4, '0')); end loop; r := 'ok';
  exception when others then r := 'ERR ' || sqlerrm || ' at ' || i; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x ネットワーク500回までは通る（' || r || '）'; end if;
  begin insert into site_visits (client_id) values ('visit-client-9999'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'too_many' then bad := bad || E'\n  x 501回目は too_many（' || r || '）'; end if;
  -- 別のネットワークなら通る
  perform set_config('request.headers', '{"x-forwarded-for":"198.51.100.9"}', true);
  begin insert into site_visits (client_id) values ('visit-client-9999'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x 別のネットワークは通る（' || r || '）'; end if;

  -- ---------- 緊急停止 ----------
  update settings set value = 1 where key = 'read_only';
  perform set_config('request.headers', '{"x-forwarded-for":"192.0.2.44"}', true);
  begin insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'paused-client-01'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'read_only' then bad := bad || E'\n  x 止めている間はログインなしも止まる（' || r || '）'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', uu, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', uu::text, true);
  begin insert into feedback (game_slug, again, reach, free, client_id, user_id) values ('gx', 'すごく遊びたい', '最後まで', '', 'paused-client-02', uu); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'read_only' then bad := bad || E'\n  x 止めている間はログインした人の感想も止まる（' || r || '）'; end if;
  set local role anon; j := site_status(); reset role;
  n := n + 1; if (j ->> 'read_only')::boolean is not true then bad := bad || E'\n  x site_status が止めていると返す（' || j || '）'; end if;
  -- 運営は通る
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', ua::text, true);
  begin insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'admin-client-001'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x 止めている間も運営は通る（' || r || '）'; end if;
  -- service_role は通る
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin insert into game_events (game_slug, kind, client_id) values ('gx', 'play', 'server-client-01'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'ok' then bad := bad || E'\n  x service_role は通る（' || r || '）'; end if;
  update settings set value = 0 where key = 'read_only';

  -- ---------- 中身を守る ----------
  n := n + 1; if has_table_privilege('anon', 'public.rate_hits', 'select') or has_table_privilege('authenticated', 'public.private_salt', 'select') then bad := bad || E'\n  x 数え表と秘密はだれも読めない'; end if;
  n := n + 1; if has_function_privilege('anon', 'public.rl_hit(text, text, int, int)', 'execute') or has_function_privilege('authenticated', 'public.req_ip_key()', 'execute') then bad := bad || E'\n  x 道具の関数は外から呼べない'; end if;
  n := n + 1; if not has_function_privilege('anon', 'public.site_status()', 'execute') then bad := bad || E'\n  x site_status はだれでも呼べる'; end if;
  n := n + 1; if (select count(*) from pg_trigger where tgname = 'zz_write_guard') < 13 then bad := bad || E'\n  x 見張りが13テーブル以上に付いている（' || (select count(*) from pg_trigger where tgname = 'zz_write_guard') || '）'; end if;

  if bad = '' then raise exception 'CHECK_OK 023: %件ぜんぶ合格', n;
  else raise exception 'CHECK_FAILED 023: %', bad; end if;
end $chk$;
