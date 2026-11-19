-- 013_launch_free.sql（最初の10作品は投稿無料）の確かめ。使い捨てのローカルPostgres専用（本番では流さない）
--   bash supabase/tests/run_local.sh supabase/tests/013_check.sql
-- どこかが違うと、その場で「FAIL: ...」のエラーで止まる。最後まで行けば「ALL OK」
\set ON_ERROR_STOP 1
create function public.t_ok(label text, cond boolean) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', label; end if; raise notice 'ok  %', label; end $$;

-- 人：u1〜u14=応募する人 u2=作品g1の作者 u3=管理者
insert into auth.users (id, email) select ('00000000-0000-0000-0000-0000000000' || lpad(i::text, 2, '0'))::uuid, 'u' || i || '@example.com' from generate_series(1, 30) i;
insert into public.admins (user_id) values ('00000000-0000-0000-0000-000000000003');
insert into public.game_owners (game_slug, user_id) values ('g1', '00000000-0000-0000-0000-000000000002');
create function public.t_u(i int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-0000000000' || lpad(i::text, 2, '0'))::uuid $$;
create function public.t_as(u int, q text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', case when u > 0 then public.t_u(u)::text else '' end, true);
  if u < 0 then set local role anon; else set local role authenticated; end if;   -- u < 0：ログインしていない人（anon）
  begin execute q into r; exception when others then r := 'ERR ' || sqlerrm; end;
  reset role; return r;
end $$;
create function public.t_bal(u int) returns int language sql as $$ select public.points_balance(public.t_u(u)) $$;
create function public.t_sub(u int) returns text language sql as $$
  select public.t_as(u, $q$ select public.submission_send('new', null, '{"title":"t","oneliner":"o","play_url":"https://example.com/g"}'::jsonb) $q$) $$;
create function public.t_left() returns int language sql as $$ select public.t_as(-1, 'select public.launch_free_left()::text')::int $$;
create function public.t_sid(u int) returns uuid language sql as $$ select id from public.submissions where user_id = public.t_u(u) and kind = 'new' order by created_at limit 1 $$;

-- 1 はじめは10枠・だれでも（ログインなしでも）読める
select public.t_ok('1a 初期値は10', public.setting_int('launch_free_total') = 10);
select public.t_ok('1b ログインなしでも残りの枠が読める（10）', public.t_left() = 10);
-- 2 ポイント0の人が、無料で応募できる
select public.t_sub(1) as r \gset
select public.t_ok('2a 枠があればポイント0でも受け付ける（ok_free）', :'r' = 'ok_free');
select public.t_ok('2b 応募に free_launch が付き、ポイントは動かない', (select free_launch from public.submissions where user_id = public.t_u(1)) and public.t_bal(1) = 0
  and not exists (select 1 from public.points_ledger where user_id = public.t_u(1)));
select public.t_ok('2c 残りが9になる', public.t_left() = 9);
-- 3 1人1回
select public.t_sub(1) as r \gset
select public.t_ok('3 同じ人の2回目は無料にならない（ポイントが要る）', :'r' = 'ERR not_enough_points' and (select count(*) from public.submissions where user_id = public.t_u(1)) = 1 and public.t_left() = 9);
-- 4 検証で落ちた応募は枠を使わない
select public.t_as(2, $q$ select public.submission_send('new', null, '{"title":"t"}'::jsonb) $q$) as r \gset
select public.t_ok('4 検証で落ちた応募は枠を使わない', :'r' = 'ERR need_title' and public.t_left() = 9);
-- 5 直しの依頼・管理者は枠を使わない
select public.t_as(2, $q$ select public.submission_send('edit', 'g1', '{"note":"直してね"}'::jsonb) $q$) as r \gset
select public.t_ok('5a 直しの依頼は枠を使わない', :'r' = 'ok' and public.t_left() = 9 and not (select free_launch from public.submissions where kind = 'edit'));
select public.t_sub(3) as r \gset
select public.t_ok('5b 管理者の応募は枠を使わない（もともと無料）', :'r' = 'ok' and public.t_left() = 9 and not (select free_launch from public.submissions where user_id = public.t_u(3)));
-- 6 のこりを使い切る（u2・u4〜u10・u15 の9人）
select public.t_sub(i) from unnest(array[2,4,5,6,7,8,9,10,15]) i;   -- u3 は管理者なので入れない
select public.t_ok('6a 10作品で枠がなくなる', public.t_left() = 0 and (select count(*) from public.submissions where free_launch) = 10);
select public.t_sub(11) as r \gset
select public.t_ok('6b 枠がなければ、今までどおりポイントが要る', :'r' = 'ERR not_enough_points' and not exists (select 1 from public.submissions where user_id = public.t_u(11)));
-- 7 枠がないときの、ポイントでの応募（30pt引く・free_launch なし）
select public.t_as(3, $q$ select public.admin_points_adjust(public.t_u(12), 40, 'テスト') $q$) \gset
select public.t_sub(12) as r \gset
select public.t_ok('7 枠がなくてもポイントがあれば応募できる（30pt引く）', :'r' = 'ok' and public.t_bal(12) = 10
  and not (select free_launch from public.submissions where user_id = public.t_u(12)) and public.t_left() = 0);
-- 8 見送りで枠が戻る
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng', 'ごめんね') $q$, public.t_sid(1))) \gset
select public.t_ok('8a 見送りにすると枠が1つ戻る', public.t_left() = 1);
select public.t_ok('8b 無料の応募を見送りにしても、ポイントは増えない', public.t_bal(1) = 0 and not exists (select 1 from public.points_ledger where user_id = public.t_u(1)));
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng', 'もう一度') $q$, public.t_sid(1))) \gset
select public.t_ok('8c 何度見送りにしても二重に戻らない', public.t_left() = 1);
select public.t_sub(11) as r \gset
select public.t_ok('8d 戻った枠は、次の人が使える', :'r' = 'ok_free' and public.t_left() = 0);
select public.t_sub(1) as r \gset
select public.t_ok('8e 枠がまた埋まったので、見送りだった人もポイントが要る', :'r' = 'ERR not_enough_points');
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, public.t_sid(12))) \gset
select public.t_ok('8f ポイントで応募した分を見送りにすると、30pt返り、枠は増えない', public.t_bal(12) = 40 and public.t_left() = 0);
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ok') $q$, public.t_sid(2))) \gset
select public.t_ok('8g 「載せた」にしても枠は戻らない', public.t_left() = 0);
-- 9 見送りだった人は、枠があればもう一度無料で出せる
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, public.t_sid(5))) \gset
select public.t_sub(5) as r \gset
select public.t_ok('9 見送りになった人は、枠が戻ればもう一度無料', :'r' = 'ok_free' and public.t_left() = 0);
-- 10 枠の数は管理ページで変えられる
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 12) $q$) as r \gset
select public.t_ok('10a 枠を12にすると残りが2になる', :'r' = '変えました' and public.t_left() = 2);
select public.t_as(1, $q$ select public.admin_settings_set('launch_free_total', 99) $q$) as r \gset
select public.t_ok('10b 管理者でなければ変えられない', :'r' = 'ERR not_admin' and public.t_left() = 2);
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 0) $q$) as r \gset
select public.t_ok('10c 0にするとキャンペーンが終わる（残り0）', public.t_left() = 0);
select public.t_sub(13) as r \gset
select public.t_ok('10d 終わったあとはポイントが要る', :'r' = 'ERR not_enough_points');
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 1) $q$) as r \gset
select public.t_ok('10e 使った枠より少なくしても、残りは0（マイナスにならない）', public.t_left() = 0);
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 12) $q$) \gset
-- 11 my_points に枠の情報
select public.t_as(13, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('11a 枠が残っていて、まだ使っていない人は launch_free_can = true', (:'r')::jsonb ->> 'launch_free_can' = 'true' and (:'r')::jsonb ->> 'launch_free_left' = '2' and (:'r')::jsonb ->> 'launch_free_total' = '12');
select public.t_as(2, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('11b もう使った人は launch_free_can = false', (:'r')::jsonb ->> 'launch_free_can' = 'false' and (:'r')::jsonb ->> 'launch_free_left' = '2');
select public.t_as(1, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('11c 見送りだった人は、また使える', (:'r')::jsonb ->> 'launch_free_can' = 'true');
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 10) $q$) \gset
select public.t_as(13, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('11d 枠がなければ false', (:'r')::jsonb ->> 'launch_free_can' = 'false' and (:'r')::jsonb ->> 'launch_free_left' = '0');
-- 12 管理者用
select public.t_as(3, $q$ select public.admin_launch_free()::text $q$) as r \gset
select public.t_ok('12a 運営は使った数と全体の数が見られる', (:'r')::jsonb ->> 'used' = '10' and (:'r')::jsonb ->> 'total' = '10' and (:'r')::jsonb ->> 'left' = '0');
select public.t_as(2, $q$ select public.admin_launch_free()::text $q$) as r \gset
select public.t_ok('12b 管理者でなければ呼べない', :'r' = 'ERR not_admin');
select public.t_as(3, $q$ select count(*)::text from public.admin_settings_get() $q$) as r \gset
select public.t_as(3, $q$ select value::text from public.admin_settings_get() where key = 'launch_free_total' $q$) as r2 \gset
select public.t_ok('12c 設定の一覧に launch_free_total が入る', :'r' = '9' and :'r2' = '10');
-- 13 外から触れない
select public.t_as(-1, $q$ select public.launch_free_used()::text $q$) as a, public.t_as(2, $q$ select public.launch_free_used()::text $q$) as b \gset
select public.t_ok('13a launch_free_used は外から呼べない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%');
select public.t_as(-1, $q$ select public.submission_send('new', null, '{}'::jsonb) $q$) as a, public.t_as(-1, $q$ select public.my_points()::text $q$) as b, public.t_as(-1, $q$ select public.admin_launch_free()::text $q$) as c \gset
select public.t_ok('13b ログインなしは応募・my_points・管理用を呼べない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%' and :'c' like 'ERR permission denied%');
select public.t_as(1, $q$ update public.submissions set free_launch = true $q$) as a, public.t_as(1, $q$ select count(*)::text from public.submissions $q$) as b \gset
select public.t_ok('13c 応募の free_launch は外から書き換えられない・読めない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%');
-- 14 BAN された人は枠を使えない
insert into public.banned_users (user_id) values (public.t_u(14));
select public.t_as(3, $q$ select public.admin_settings_set('launch_free_total', 20) $q$) \gset
select public.t_sub(14) as r \gset
select public.t_ok('14 BANされた人は無料でも応募できない', :'r' = 'ERR banned');
select 'ALL OK' as result;
