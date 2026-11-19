-- 「最初の10作品は投稿無料」キャンペーン（012 のポイント制の上に足す）
--   settings.launch_free_total … 無料枠の数（初期値10。管理ページの「ポイント」タブで変える。0にすると終わり）
--   submissions.free_launch    … 無料枠で受け付けた応募に true（ポイントは引かない）
--   枠の数え方：free_launch で、見送り（status = 'ng'）になっていない新しい応募の数。見送りになると、その枠は戻る
--   1人が使える無料枠は1回まで（見送りになった分は数えない）。管理者の応募は、もともと無料なので枠を使わない
--   launch_free_left() … 残りの枠の数（だれでも呼べる）

insert into public.settings (key, value, label) values
  ('launch_free_total', 10, '「最初の○作品は投稿無料」の作品数（0にするとキャンペーンを終わる。使った枠は管理ページの概要で見られる）')
on conflict (key) do nothing;

alter table public.submissions add column if not exists free_launch boolean not null default false;
create index if not exists submissions_free_launch on public.submissions (free_launch) where free_launch;

-- 使っている枠の数（内部用）
create or replace function public.launch_free_used() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from submissions where free_launch and status <> 'ng';
$$;

-- 残りの枠（だれでも）
create or replace function public.launch_free_left() returns int
language sql stable security definer set search_path = public as $$
  select greatest(setting_int('launch_free_total', 0) - launch_free_used(), 0);
$$;

-- 運営だけ：枠の使用数と全体の数
create or replace function public.admin_launch_free() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return jsonb_build_object('used', launch_free_used(), 'total', setting_int('launch_free_total', 0), 'left', launch_free_left());
end $$;

-- 応募：無料枠があれば、ポイントを引かずに受け付ける（012 の submission_send を置きかえる）。無料のときは 'ok_free'、ポイントを引いたときは 'ok'
create or replace function public.submission_send(p_kind text, p_slug text, p_data jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d jsonb := coalesce(p_data, '{}'::jsonb);
  k text; val text; clean jsonb := '{}'::jsonb;
  cost int := setting_int('submit_cost', 30);
  sid uuid;
  use_free boolean := false;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if p_kind not in ('new', 'edit') then raise exception 'bad_kind'; end if;
  if p_kind = 'edit' and not can_see_game(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  if (select count(*) from submissions where user_id = uid and status = 'new') >= 5 then raise exception 'too_many'; end if;
  if jsonb_typeof(d) <> 'object' then raise exception 'bad_data'; end if;
  foreach k in array array['title', 'play_url', 'oneliner', 'platform', 'check', 'question', 'minutes', 'genre', 'stage', 'rating', 'controls', 'image_url', 'note'] loop
    if jsonb_typeof(d -> k) = 'string' then
      val := btrim(d ->> k);
      if char_length(val) > 400 then raise exception 'too_long'; end if;
      if val <> '' then clean := clean || jsonb_build_object(k, val); end if;
    end if;
  end loop;
  if p_kind = 'new' then
    if coalesce(clean ->> 'title', '') = '' or coalesce(clean ->> 'oneliner', '') = '' then raise exception 'need_title'; end if;
    if coalesce(clean ->> 'play_url', '') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url'; end if;
  else
    if coalesce(clean ->> 'note', '') = '' then raise exception 'need_note'; end if;
  end if;
  if clean ? 'image_url' and (clean ->> 'image_url') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url'; end if;
  if has_banned_word(clean::text) then raise exception 'banned_word'; end if;
  -- 新しい応募だけ、ポイントが要る（直しの依頼・管理者は無料）。残高のチェックと引き算は同じトランザクションで
  -- 「最初の○作品は投稿無料」：枠が残っていて、この人がまだ無料枠を使っていない（見送りになったものは数えない）なら、ポイントを引かずに受け付ける
  if p_kind = 'new' and not is_admin() then
    perform pg_advisory_xact_lock(hashtextextended('launch_free', 0));   -- 枠の取り合いを1件ずつにする（先に全体、あとで個人の順）
    perform points_lock(uid);
    if launch_free_left() > 0
       and not exists (select 1 from submissions where user_id = uid and free_launch and status <> 'ng') then
      use_free := true;
    elsif cost > 0 and points_balance(uid) < cost then
      raise exception 'not_enough_points';
    end if;
  end if;
  insert into submissions (user_id, kind, game_slug, data, free_launch)
    values (uid, p_kind, case when p_kind = 'edit' then p_slug end, clean, use_free)
    returning id into sid;
  if p_kind = 'new' and not use_free and cost > 0 and not is_admin() then
    insert into points_ledger (user_id, delta, reason, ref) values (uid, -cost, 'submission', sid);
  end if;
  if use_free then return 'ok_free'; end if;
  return 'ok';
end $$;

-- ---------- 見送りなら返す（009 の admin_submission_set を置きかえる） ----------
create or replace function public.admin_submission_set(sid uuid, st text, note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare s public.submissions; owed int;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if st not in ('new', 'ok', 'ng') then raise exception 'bad_status'; end if;
  update submissions set status = st, admin_note = left(coalesce(note, ''), 400) where id = sid returning * into s;
  if found and st = 'ng' and s.kind = 'new' then
    perform points_lock(s.user_id);
    -- 引いた分から、もう返した分を引いた残り（何度「見送り」にしても二重に返さない）
    select coalesce(-sum(delta), 0) into owed from points_ledger where ref = sid and reason in ('submission', 'submission_refund');
    if owed > 0 then
      insert into points_ledger (user_id, delta, reason, ref) values (s.user_id, owed, 'submission_refund', sid);
    end if;
  end if;
  return case st when 'ok' then '「載せた」にしました' when 'ng' then '「見送り」にしました' else '「確認中」に戻しました' end;
end $$;

-- ---------- ログインした人・だれでも ----------
-- 自分のポイント：残高・今日もらった分・1日の上限・投稿に必要なポイント・最近の記録20件
create or replace function public.my_points() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  return jsonb_build_object(
    'balance', points_balance(uid),
    'today', points_today(uid),
    'daily_cap', setting_int('daily_cap', 50),
    'submit_cost', setting_int('submit_cost', 30),
    'is_admin', is_admin(),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'delta', r.delta, 'reason', r.reason, 'note', r.note, 'created_at', r.created_at, 'label', r.label)
               order by r.created_at desc, r.id desc), '[]'::jsonb)
               from (select l.*,
                            case when l.reason like 'feedback%' then (select f.game_slug from feedback f where f.id = l.ref)
                                 when l.reason like 'submission%' then (select s.data ->> 'title' from submissions s where s.id = l.ref) end as label
                     from points_ledger l where l.user_id = uid and (l.delta <> 0)
                     order by l.created_at desc, l.id desc limit 20) r));
end $$;

-- ポイントの決まり（だれでも）
create or replace function public.points_rule() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'min_chars', setting_int('min_chars', 40), 'daily_cap', setting_int('daily_cap', 50),
    'tier1_max', setting_int('tier1_max', 2), 'tier1_pt', setting_int('tier1_pt', 10),
    'tier2_max', setting_int('tier2_max', 9), 'tier2_pt', setting_int('tier2_pt', 5),
    'tier3_pt', setting_int('tier3_pt', 2), 'submit_cost', setting_int('submit_cost', 30));
$$;

-- 自分のポイント：無料枠の残りと、自分がいま使えるか、を足す（012 の my_points を置きかえる）
create or replace function public.my_points() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  return jsonb_build_object(
    'balance', points_balance(uid),
    'today', points_today(uid),
    'daily_cap', setting_int('daily_cap', 50),
    'submit_cost', setting_int('submit_cost', 30),
    'is_admin', is_admin(),
    'launch_free_left', launch_free_left(),
    'launch_free_can', launch_free_left() > 0 and not exists (select 1 from submissions s where s.user_id = uid and s.free_launch and s.status <> 'ng'),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'delta', r.delta, 'reason', r.reason, 'note', r.note, 'created_at', r.created_at, 'label', r.label)
               order by r.created_at desc, r.id desc), '[]'::jsonb)
               from (select l.*,
                            case when l.reason like 'feedback%' then (select f.game_slug from feedback f where f.id = l.ref)
                                 when l.reason like 'submission%' then (select s.data ->> 'title' from submissions s where s.id = l.ref) end as label
                     from points_ledger l where l.user_id = uid and (l.delta <> 0)
                     order by l.created_at desc, l.id desc limit 20) r));
end $$;

-- ポイントの決まり（だれでも）
create or replace function public.points_rule() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'min_chars', setting_int('min_chars', 40), 'daily_cap', setting_int('daily_cap', 50),
    'tier1_max', setting_int('tier1_max', 2), 'tier1_pt', setting_int('tier1_pt', 10),
    'tier2_max', setting_int('tier2_max', 9), 'tier2_pt', setting_int('tier2_pt', 5),
    'tier3_pt', setting_int('tier3_pt', 2), 'submit_cost', setting_int('submit_cost', 30));
$$;

-- 管理ページの設定一覧に launch_free_total を足す（012 の admin_settings_get を置きかえる）
create or replace function public.admin_settings_get()
returns table (key text, value int, label text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select s.key, s.value, s.label from settings s
    order by array_position(array['min_chars','daily_cap','tier1_max','tier1_pt','tier2_max','tier2_pt','tier3_pt','submit_cost','launch_free_total'], s.key), s.key;
end $$;

-- ---------- 権限 ----------
revoke all on function public.launch_free_used(), public.launch_free_left(), public.admin_launch_free(),
  public.submission_send(text, text, jsonb), public.my_points(), public.admin_settings_get()
  from public, anon, authenticated;
grant execute on function public.launch_free_left() to anon, authenticated;
grant execute on function public.admin_launch_free(), public.submission_send(text, text, jsonb), public.my_points(), public.admin_settings_get() to authenticated;

select 'ok 013' as result;
