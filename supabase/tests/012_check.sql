-- 012_points.sql の確かめ。使い捨てのローカルPostgres専用（本番では流さない）
--   bash supabase/tests/run_local.sh supabase/tests/012_check.sql
-- どこかが違うと、その場で「FAIL: ...」のエラーで止まる。最後まで行けば「ALL OK」
\set ON_ERROR_STOP 1
create function public.t_ok(label text, cond boolean) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', label; end if; raise notice 'ok  %', label; end $$;

-- 人：u1=もらう人 u2=作品g1の作者 u3=管理者 u4=お金のない人 u5〜=ほかの人
insert into auth.users (id, email) select ('00000000-0000-0000-0000-0000000000' || lpad(i::text, 2, '0'))::uuid, 'u' || i || '@example.com' from generate_series(1, 30) i;
insert into public.admins (user_id) values ('00000000-0000-0000-0000-000000000003');
insert into public.game_owners (game_slug, user_id) values ('g1', '00000000-0000-0000-0000-000000000002');

create function public.t_u(i int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-0000000000' || lpad(i::text, 2, '0'))::uuid $$;
create function public.t_text(n int) returns text language sql as $$ select format('操作がわかりやすくて楽しかったです。%s番目のステージで迷ったので、ヒントがあると嬉しいです。', n) $$;
-- ログインしたその人として、感想を送る（RLS も効く）。遊んだ記録を付けるかは play で選ぶ
create function public.t_fb(u int, slug text, free text, play boolean default true) returns text language plpgsql as $$
declare cid text := 'client-' || u; r text;
begin
  if play then insert into public.game_events (game_slug, kind, client_id) values (slug, 'play', cid) on conflict do nothing; end if;
  perform set_config('request.jwt.claim.sub', public.t_u(u)::text, true);
  set local role authenticated;
  begin
    insert into public.feedback (game_slug, again, reach, free, client_id) values (slug, 'ちょっと遊びたい', '最後まで', free, cid);
    r := (public.feedback_points_result(slug))::text;
  exception when others then r := 'ERR ' || sqlerrm; end;
  reset role;
  return r;
end $$;
create function public.t_as(u int, q text) returns text language plpgsql as $$
declare r text; v jsonb;
begin
  perform set_config('request.jwt.claim.sub', case when u > 0 then public.t_u(u)::text else '' end, true);
  set local role authenticated;
  begin execute q into r; exception when others then r := 'ERR ' || sqlerrm; end;
  reset role; return r;
end $$;
create function public.t_bal(u int) returns int language sql as $$ select public.points_balance(public.t_u(u)) $$;
create function public.t_fid(u int, slug text) returns uuid language sql as $$ select id from public.feedback where user_id = public.t_u(u) and game_slug = slug $$;

-- 1 ポイントがもらえる（感想0件 → 10pt）
select public.t_fb(1, 'g2', public.t_text(1)) as r \gset
select public.t_ok('1 もらえる 10pt', :'r' like '%"delta": 10%' and public.t_bal(1) = 10);
-- 2 40字未満
select public.t_fb(1, 'g3', 'おもしろかったです。もう一回遊びたい') as r \gset
select public.t_ok('2 40字未満は 0pt（感想は入る）', :'r' like '%"delta": 0%' and :'r' like '%"note": "short"%'
  and exists (select 1 from public.feedback where user_id = public.t_u(1) and game_slug = 'g3') and public.t_bal(1) = 10);
select public.t_fb(1, 'g3b', 'おもしろい' || repeat('　 ', 30) || 'です') as r \gset
select public.t_ok('2b 空白でかさ増ししても 0pt', :'r' like '%"note": "short"%');
-- 3 遊んでいない
select public.t_fb(1, 'g4', public.t_text(4), false) as r \gset
select public.t_ok('3 遊んでいないと 0pt', :'r' like '%"delta": 0%' and :'r' like '%"note": "not_played"%');
-- 4 自分の作品
select public.t_fb(2, 'g1', public.t_text(5)) as r \gset
select public.t_ok('4 自分の作品は 0pt', :'r' like '%"delta": 0%' and :'r' like '%"note": "own"%');
-- 5 くり返しの文
select public.t_fb(4, 'g5', repeat('あ', 50)) as r \gset
select public.t_ok('5a 同じ文字のくり返しは 0pt', :'r' like '%"delta": 0%' and :'r' like '%"note": "lazy"%');
select public.t_fb(4, 'g6', repeat('ありがとうございます', 6)) as r \gset
select public.t_ok('5b 水増し（文字の種類が少ない）も 0pt', :'r' like '%"note": "lazy"%');
select public.t_as(4, $q$ insert into public.feedback (game_slug, again, reach, free, client_id, is_dev) values ('g7','もういいかな','最後まで', repeat('あ', 50), 'client-4', true) $q$) as r \gset
select public.t_ok('5c 開発者の感想は今までどおり断る', :'r' like '%lazy_dev%');
select public.t_ok('5d is_lazy_text', public.is_lazy_text('ああああああああ') and public.is_lazy_text('あいうあいうあいうあいう') and not public.is_lazy_text(public.t_text(1)));
-- 6 1日の上限（50）：u1 は 10pt もっている → あと4件で 50、5件目は 0
select public.t_fb(1, 'g8', public.t_text(8)), public.t_fb(1, 'g9', public.t_text(9)), public.t_fb(1, 'g10', public.t_text(10)), public.t_fb(1, 'g11', public.t_text(11)) \gset
select public.t_ok('6a 上限ちょうどの 50pt', public.t_bal(1) = 50);
select public.t_fb(1, 'g12', public.t_text(12)) as r \gset
select public.t_ok('6b 上限をこえたら 0pt（理由 cap）', :'r' like '%"delta": 0%' and :'r' like '%"note": "cap"%' and public.t_bal(1) = 50);
-- 上限を55に上げると、超える分は切り捨て（5pt だけ）
select public.t_as(3, $q$ select public.admin_settings_set('daily_cap', 55) $q$) \gset
select public.t_fb(1, 'g13', public.t_text(13)) as r \gset
select public.t_ok('6c 超える分は切り捨て 5pt', :'r' like '%"delta": 5%' and public.t_bal(1) = 55);
select public.t_as(3, $q$ select public.admin_settings_set('daily_cap', 50) $q$) \gset
-- 7 感想の件数でポイントが変わる（自分の分は数えない）
select count(public.t_fb(i, 'g20', public.t_text(i))) from generate_series(10, 12) i \gset
select public.t_fb(13, 'g20', public.t_text(13)) as r \gset
select public.t_ok('7a 3件の作品は 5pt', :'r' like '%"delta": 5%');
select count(public.t_fb(i, 'g21', public.t_text(i))) from generate_series(14, 23) i \gset
select public.t_fb(24, 'g21', public.t_text(24)) as r \gset
select public.t_ok('7b 10件の作品は 2pt', :'r' like '%"delta": 2%');
select public.t_fb(25, 'g22', public.t_text(1)) as a, public.t_fb(26, 'g22', public.t_text(2)) as b, public.t_fb(27, 'g22', public.t_text(3)) as c \gset
select public.t_fb(28, 'g22', public.t_text(4)) as d \gset
select public.t_ok('7c 境目：0〜2件は 10pt、3件目からは 5pt', :'a' like '%"delta": 10%' and :'b' like '%"delta": 10%' and :'c' like '%"delta": 10%' and :'d' like '%"delta": 5%');
-- u25 の感想を隠すと、表示は 26,27,28 の3件 → u29 は 5pt
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, true) $q$, public.t_fid(25, 'g22'))) \gset
select public.t_fb(29, 'g22', public.t_text(5)) as r \gset
select public.t_ok('7d 非表示の感想は数えない', :'r' like '%"delta": 5%');
-- 8 ヒント
select public.t_as(0, $q$ select public.game_point_hint('g30') $q$) as r \gset
select public.t_ok('8a game_point_hint（ログインなし）', :'r' like '%"points": 10%');
select public.t_as(1, $q$ select public.game_point_hint('g2') $q$) as r \gset
select public.t_ok('8b game_point_hint（もう書いた）', :'r' like '%"blocked": "already"%');
select public.t_as(2, $q$ select public.game_point_hint('g1') $q$) as r \gset
select public.t_ok('8c game_point_hint（自分の作品）', :'r' like '%"blocked": "own"%');
select public.t_as(1, $q$ select public.game_point_hint('g30') $q$) as r \gset
select public.t_ok('8d game_point_hint（上限）', :'r' like '%"blocked": "cap"%');
select public.t_as(5, $q$ select public.game_point_hint('g31', 'client-5xx') $q$) as r \gset
select public.t_ok('8e game_point_hint（遊んでいない）', :'r' like '%"blocked": "not_played"%');
select public.t_as(0, $q$ select public.points_rule() $q$) as r \gset
select public.t_ok('8f points_rule（ログインなし）', :'r' like '%"submit_cost": 30%');
-- 9 取り消し・返す（u1 の g2 の感想 10pt）
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, true) $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9a 非表示で取り消し -10', public.t_bal(1) = 45 and (select count(*) from public.points_ledger where user_id = public.t_u(1) and reason = 'feedback_revoked') = 1);
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, true) $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9b もう一度非表示にしても二重に取り消さない', public.t_bal(1) = 45);
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, false) $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9c 表示に戻すと返る +10', public.t_bal(1) = 55 and (select count(*) from public.points_ledger where user_id = public.t_u(1) and reason = 'feedback_restored') = 1);
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, false) $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9d 二重に返さない', public.t_bal(1) = 55);
-- BANの一括非表示でも取り消す
select public.t_as(3, format($q$ select public.admin_ban(%L, 'テスト') $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9e BANの一括非表示で全部取り消す → 0pt', public.t_bal(1) = 0 and not exists (select 1 from public.feedback where user_id = public.t_u(1) and not hidden));
select public.t_as(3, $q$ select public.admin_unban(public.t_u(1)::text) $q$) \gset
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, false) $q$, public.t_fid(1, 'g2'))) \gset
select public.t_ok('9f 1件ずつ戻すと、その分が返る', public.t_bal(1) = 10);
-- 0pt の感想を隠しても、戻しても、何も起きない
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, true) $q$, public.t_fid(1, 'g3'))) \gset
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, false) $q$, public.t_fid(1, 'g3'))) \gset
select public.t_ok('9g 0pt の感想は動かない', public.t_bal(1) = 10);
-- さかのぼらない：012 より前にあった感想（記録なし）は、隠しても戻してもポイントが動かない
alter table public.feedback disable trigger feedback_points_award;
insert into public.feedback (game_slug, again, reach, free, client_id, user_id) values ('g40', 'ちょっと遊びたい', '最後まで', public.t_text(40), 'client-6', public.t_u(6));
alter table public.feedback enable trigger feedback_points_award;
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, true) $q$, public.t_fid(6, 'g40'))) \gset
select public.t_as(3, format($q$ select public.admin_set_hidden(%L, false) $q$, public.t_fid(6, 'g40'))) \gset
select public.t_ok('9h さかのぼってポイントを付けない', public.t_bal(6) = 0 and not exists (select 1 from public.points_ledger where user_id = public.t_u(6)));
-- 10 応募でポイントを引く
select public.t_as(4, $q$ select public.submission_send('new', null, '{"title":"t","oneliner":"o","play_url":"https://example.com/g"}'::jsonb) $q$) as r \gset
select public.t_ok('10a ポイントが足りないと not_enough_points', :'r' = 'ERR not_enough_points' and not exists (select 1 from public.submissions where user_id = public.t_u(4)));
select public.t_as(3, $q$ select public.admin_points_adjust(public.t_u(4), 40, '最初のおくりもの') $q$) \gset
select public.t_as(4, $q$ select public.submission_send('new', null, '{"title":"t","oneliner":"o","play_url":"https://example.com/g"}'::jsonb) $q$) as r \gset
select public.t_ok('10b 足りれば応募できて 30pt 引かれる', :'r' = 'ok' and public.t_bal(4) = 10 and (select delta from public.points_ledger where user_id = public.t_u(4) and reason = 'submission') = -30);
select public.t_as(4, $q$ select public.submission_send('new', null, '{"title":"t"}'::jsonb) $q$) as r \gset
select public.t_ok('10c 検証で落ちた応募は引かれない', :'r' = 'ERR need_title' and public.t_bal(4) = 10);
select public.t_as(2, $q$ select public.submission_send('edit', 'g1', '{"note":"直してね"}'::jsonb) $q$) as r \gset
select public.t_ok('10d 直しの依頼は無料', :'r' = 'ok' and public.t_bal(2) = 0);
select public.t_as(3, $q$ select public.submission_send('new', null, '{"title":"t","oneliner":"o","play_url":"https://example.com/g"}'::jsonb) $q$) as r \gset
select public.t_ok('10e 管理者は無料', :'r' = 'ok' and public.t_bal(3) = 0);
-- 11 見送りで返す
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng', 'ごめんね') $q$, (select id from public.submissions where user_id = public.t_u(4)))) \gset
select public.t_ok('11a 見送りで 30pt 返る', public.t_bal(4) = 40);
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng', 'もう一度') $q$, (select id from public.submissions where user_id = public.t_u(4)))) \gset
select public.t_ok('11b 二重に返さない', public.t_bal(4) = 40);
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, (select id from public.submissions where user_id = public.t_u(2) and kind = 'edit'))) \gset
select public.t_ok('11c 直しの依頼を見送りにしても増えない', public.t_bal(2) = 0);
select public.t_as(3, format($q$ select public.admin_submission_set(%L, 'ng') $q$, (select id from public.submissions where user_id = public.t_u(3)))) \gset
select public.t_ok('11d 管理者の（無料の）応募を見送りにしても増えない', public.t_bal(3) = 0);
-- 12 外から触れない
select public.t_as(1, $q$ select count(*)::text from public.points_ledger $q$) as r \gset
select public.t_ok('12a 外から ledger を読めない', :'r' like 'ERR permission denied%');
select public.t_as(1, $q$ insert into public.points_ledger (user_id, delta, reason) values (public.t_u(1), 999, 'admin_adjust') $q$) as r \gset
select public.t_ok('12b 外から ledger に書けない', :'r' like 'ERR permission denied%');
select public.t_as(1, $q$ update public.points_ledger set delta = 999 $q$) as r1, public.t_as(1, $q$ delete from public.points_ledger $q$) as r2 \gset
select public.t_ok('12c ledger の更新・削除もできない', :'r1' like 'ERR permission denied%' and :'r2' like 'ERR permission denied%');
select public.t_as(1, $q$ select count(*)::text from public.settings $q$) as r1, public.t_as(1, $q$ update public.settings set value = 0 $q$) as r2 \gset
select public.t_ok('12d settings も読めない・書けない', :'r1' like 'ERR permission denied%' and :'r2' like 'ERR permission denied%');
select public.t_as(1, $q$ select public.admin_points_adjust(public.t_u(1), 999, 'x') $q$) as a, public.t_as(1, $q$ select public.admin_settings_set('daily_cap', 9999) $q$) as b,
       public.t_as(1, $q$ select count(*)::text from public.admin_points_users() $q$) as c, public.t_as(1, $q$ select count(*)::text from public.admin_settings_get() $q$) as d \gset
select public.t_ok('12e 管理者でなければ調整・設定・一覧は呼べない', :'a' = 'ERR not_admin' and :'b' = 'ERR not_admin' and :'c' = 'ERR not_admin' and :'d' = 'ERR not_admin');
select public.t_as(1, $q$ select public.points_balance(public.t_u(1))::text $q$) as a, public.t_as(1, $q$ select public.points_lock(public.t_u(1))::text $q$) as b \gset
select public.t_ok('12f 内部の部品は外から呼べない', :'a' like 'ERR permission denied%' and :'b' like 'ERR permission denied%');
select public.t_as(0, $q$ select public.my_points()::text $q$) as r \gset
select public.t_ok('12g ログインなしは my_points を呼べない', :'r' like 'ERR%');
select public.t_as(1, $q$ insert into public.feedback (game_slug, again, reach, free, client_id, delta) values ('g50','もういいかな','最後まで','x','client-1', 99) $q$) as r \gset
select public.t_ok('12h feedback から delta は入れられない', :'r' like 'ERR%');
-- 13 my_points・管理者用
select public.t_as(1, $q$ select public.my_points() $q$) as r \gset
select public.t_ok('13a my_points', :'r' like '%"balance": 10%' and :'r' like '%"daily_cap": 50%' and :'r' like '%"recent": [%');
select public.t_ok('13b 最近の記録は20件まで・0pt は出さない', jsonb_array_length((:'r')::jsonb -> 'recent') between 1 and 20 and :'r' not like '%"delta": 0,%');
select public.t_as(3, $q$ select count(*)::text from public.admin_points_users() $q$) as r \gset
select public.t_ok('13c admin_points_users', :'r'::int >= 5);
select public.t_as(3, $q$ select count(*)::text from public.admin_settings_get() $q$) as r \gset
select public.t_ok('13d admin_settings_get は8行', :'r' = '8');
select public.t_as(3, $q$ select public.admin_settings_set('submit_cost', 20) $q$) as r \gset
select public.t_ok('13e 設定を変えると反映される', :'r' = '変えました' and public.setting_int('submit_cost') = 20);
select public.t_as(3, $q$ select public.admin_settings_set('tier1_max', 50) $q$) as r \gset
select public.t_ok('13f 境目が逆になる設定は断る', :'r' = 'ERR bad_tiers' and public.setting_int('tier1_max') = 2);
select public.t_as(3, $q$ select public.admin_points_adjust(public.t_u(1), 5, '  ') $q$) as r \gset
select public.t_ok('13g 調整は理由が要る', :'r' = 'ERR need_note');
select public.t_as(3, $q$ select public.admin_settings_set('submit_cost', 30) $q$) \gset
-- 14 概要
select public.t_as(3, $q$ select (public.admin_overview(7) -> 'points')::text $q$) as r \gset
select public.t_ok('14 admin_overview に points が入る', :'r' like '%"granted"%' and (:'r')::jsonb ->> 'outstanding' = (select sum(delta)::text from public.points_ledger));
-- 15 ポイントの計算がこわれても感想は受け付ける
alter table public.points_ledger rename to points_ledger_x;
select public.t_as(7, format($q$ insert into public.feedback (game_slug, again, reach, free, client_id) values ('g60','もういいかな','最後まで',%L,'client-7') returning 'ok' $q$, public.t_text(60))) as r \gset
alter table public.points_ledger_x rename to points_ledger;
select public.t_ok('15 ledger がこわれても感想は入る', exists (select 1 from public.feedback where user_id = public.t_u(7) and game_slug = 'g60'));
select 'ALL OK' as result;
