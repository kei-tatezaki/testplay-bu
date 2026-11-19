-- 013_first_free.sql（最初の1本は投稿無料）の確かめ。使い捨てのローカルPostgres専用（本番では流さない）
--   bash supabase/tests/run_local.sh supabase/tests/013_check.sql
-- どこかが違うと、その場で「FAIL: ...」のエラーで止まる。最後まで行けば「ALL OK」
\set ON_ERROR_STOP 1
create function public.t_ok(label text, cond boolean) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', label; end if; raise notice 'ok  %', label; end $$;

-- 人：u1〜u8=応募する人 u2=作品g1の作者 u3=管理者
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
create function public.t_sub(u int, title text default 't') returns text language sql as $$
  select public.t_as(u, format($q$ select public.submission_send('new', null, '{"title":"%s","oneliner":"o","play_url":"https://example.com/g"}'::jsonb) $q$, title)) $$;
create function public.t_sid(u int, title text) returns uuid language sql as $$ select id from public.submissions where user_id = public.t_u(u) and data ->> 'title' = title $$;
create function public.t_ff(u int) returns text language sql as $$ select public.t_as(u, 'select public.first_free_available()::text') $$;

-- 1 最初の1本は、ポイント0でも無料
select public.t_ok('1a 最初は無料になる', public.t_ff(1) = 'true');
select public.t_sub(1, 'a1') as r \gset
select public.t_ok('1b 最初の1本はポイントなしで受け付ける（ok_free）', :'r' = 'ok_free');
select public.t_ok('1c free_launch が付き、ポイントは動かない', (select free_launch from public.submissions where user_id = public.t_u(1)) and public.t_bal(1) = 0
  and not exists (select 1 from public.points_ledger where user_id = public.t_u(1)));
-- 2 2本目からはポイントが要る
select public.t_ok('2a 1本目のあとは無料でなくなる', public.t_ff(1) = 'false');
select public.t_sub(1, 'a2') as r \gset
select public.t_ok('2b 2本目はポイントがないと断られる', :'r' = 'ERR not_enough_points' and (select count(*) from public.submissions where user_id = public.t_u(1)) = 1);
select public.t_as(3, $q$ select public.admin_points_adjust(public.t_u(1), 40, 'テスト') $q$) \gset
select public.t_sub(1, 'a2') as r \gset
select public.t_ok('2c ポイントがあれば2本目を送れて、30pt引かれる', :'r' = 'ok' and public.t_bal(1) = 10
  and not (select free_launch from public.submissions where user_id = public.t_u(1) and data ->> 'title' = 'a2'));
select public.t_sub(1, 'a3') as r \gset
select public.t_ok('2d 3本目も30pt要る（残り10ptでは足りない）', :'r' = 'ERR not_enough_points');
-- 3 ほかの人の1本目は、それぞれ無料（上限なし）
select public.t_sub(i, 'b' || i) from generate_series(4, 24) i;
select public.t_ok('3 何人でも、それぞれの1本目は無料（上限なし）', (select count(*) from public.submissions where free_launch) = 22);
-- 4 検証で落ちた応募は、無料を使わない
select public.t_as(2, $q$ select public.submission_send('new', null, '{"title":"t"}'::jsonb) $q$) as r \gset
select public.t_ok('4a 検証で落ちた応募は無料を使わない', :'r' = 'ERR need_title' and public.t_ff(2) = 'true');
-- 5 直しの依頼・管理者は「最初の1本」を使わない
select public.t_as(2, $q$ select public.submission_send('edit', 'g1', '{"note":"直してね"}'::jsonb) $q$) as r \gset
select public.t_ok('5a 直しの依頼は無料で、最初の1本を使わない', :'r' = 'ok' and public.t_ff(2) = 'true' and not (select free_launch from public.submissions where kind = 'edit'));
select public.t_sub(3, 'adm') as r \gset
select public.t_ok('5b 管理者の応募は無料で、free_launch にしない', :'r' = 'ok' and not (select free_launch from public.submissions where user_id = public.t_u(3)) and public.t_bal(3) = 0);
select public.t_sub(2, 'c2') as r \gset
select public.t_ok('5c u2 は直しの依頼のあとでも、新しい1本目は無料', :'r' = 'ok_free');
-- 6 見送りにすると、無料がもう一度使える
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng', 'ごめんね') $q$, public.t_sid(4, 'b4'))) \gset
select public.t_ok('6a 見送りにされた人は、また無料', public.t_ff(4) = 'true' and public.t_bal(4) = 0);
select public.t_sub(4, 'b4again') as r \gset
select public.t_ok('6b 次の応募がまた無料（ok_free）', :'r' = 'ok_free' and public.t_ff(4) = 'false');
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, public.t_sid(4, 'b4'))) \gset
select public.t_ok('6c もう一度「見送り」にしても、無料が増えたりポイントが動いたりしない', public.t_bal(4) = 0 and public.t_ff(4) = 'false');
-- 7 「載せた」「確認中」のままなら、無料は戻らない／ポイントで出した2本目を見送りにすると30pt返る
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ok') $q$, public.t_sid(5, 'b5'))) \gset
select public.t_ok('7a 「載せた」にしても無料は戻らない', public.t_ff(5) = 'false');
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, public.t_sid(1, 'a2'))) \gset
select public.t_ok('7b 2本目（ポイント）を見送りにすると30pt返る', public.t_bal(1) = 40);
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, public.t_sid(1, 'a1'))) \gset
select public.t_ok('7c 1本目（無料）を見送りにしてもポイントは増えず、無料がまた使える', public.t_bal(1) = 40 and public.t_ff(1) = 'true');
select public.t_sub(1, 'a4') as r \gset
select public.t_ok('7d その応募も無料で、ポイントは減らない', :'r' = 'ok_free' and public.t_bal(1) = 40);
-- 8 BAN・ログインなし
insert into public.banned_users (user_id) values (public.t_u(20));
select public.t_sub(20, 'x') as r \gset
select public.t_ok('8a BANされた人は、無料でも応募できない', :'r' = 'ERR banned');
select public.t_as(-1, $q$ select public.first_free_available()::text $q$) as a, public.t_as(-1, $q$ select public.admin_free_used()::text $q$) as b, public.t_as(-1, $q$ select public.submission_send('new', null, '{}'::jsonb) $q$) as c \gset
select public.t_ok('8b ログインなしは、first_free_available・集計・応募を呼べない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%' and :'c' like 'ERR permission denied%');
-- 9 my_points に first_free
select public.t_as(7, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('9a 使った人は first_free = false', (:'r')::jsonb ->> 'first_free' = 'false');
select public.t_as(26, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('9b まだ応募していない人は first_free = true', (:'r')::jsonb ->> 'first_free' = 'true');
select public.t_as(25, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('9c launch_free_* の古いキーは出さない', (:'r')::jsonb ? 'first_free' and not (:'r')::jsonb ? 'launch_free_left');
-- 10 運営の集計・外から触れない
select public.t_as(3, $q$ select public.admin_free_used()::text $q$) as r \gset
select public.t_ok('10a 運営は無料で受け付けた数が見られる（見送りは除く）', :'r'::int = (select count(*) from public.submissions where free_launch and status <> 'ng'));
select public.t_as(2, $q$ select public.admin_free_used()::text $q$) as r \gset
select public.t_ok('10b 管理者でなければ呼べない', :'r' = 'ERR not_admin');
select public.t_as(1, $q$ update public.submissions set free_launch = true $q$) as a, public.t_as(1, $q$ select count(*)::text from public.submissions $q$) as b \gset
select public.t_ok('10c free_launch は外から書き換えられない・読めない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%');
select public.t_ok('10d 「先着」の決まり（launch_free_total）は無い', not exists (select 1 from public.settings where key = 'launch_free_total')
  and not exists (select 1 from pg_proc where proname in ('launch_free_left', 'launch_free_used')));
select 'ALL OK' as result;
