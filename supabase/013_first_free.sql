-- 「最初の1本は投稿無料」（012 のポイント制の上に足す）
--   全員、最初の1本の新しい応募は、ポイントなしで受け付ける（上限なし・期限なし）。2本目からは submit_cost（30pt）
--   判定：その人に、見送り（status = 'ng'）になっていない新しい応募（kind = 'new'）が1本もない → 無料
--         見送りになると、その1本は数えないので、次の応募がまた無料になる
--   直しの依頼・管理者の応募は、もともと無料で、「最初の1本」には数えない（管理者は無料枠も使わない）
--   submissions.free_launch … 無料で受け付けた応募に true（ポイントは引かない。運営が数を見るためだけに記録する）
--   first_free_available() … いま自分の応募が無料になるか（ログインした本人の分だけ返す）

alter table public.submissions add column if not exists free_launch boolean not null default false;
create index if not exists submissions_free_launch on public.submissions (free_launch) where free_launch;

-- いま、自分（ログインした人）の次の新しい応募は無料か
create or replace function public.first_free_available() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  return not exists (select 1 from submissions where user_id = uid and kind = 'new' and status <> 'ng');
end $$;

-- 運営だけ：無料で受け付けた応募の数（見送りになった分は除く）
create or replace function public.admin_free_used() returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return (select count(*)::int from submissions where free_launch and status <> 'ng');
end $$;

-- 応募：最初の1本は、ポイントを引かずに受け付ける（012 の submission_send を置きかえる）。無料のときは 'ok_free'、ポイントを引いたときは 'ok'
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
  -- 「最初の1本は投稿無料」：その人に、見送りになっていない新しい応募がまだ1本もなければ、ポイントを引かずに受け付ける。2本目からは cost（30pt）
  --   見送りになった応募は数えないので、見送りになれば、次の応募がまた無料になる
  if p_kind = 'new' and not is_admin() then
    perform points_lock(uid);
    if not exists (select 1 from submissions where user_id = uid and kind = 'new' and status <> 'ng') then
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


-- 自分のポイント：最初の1本が無料か（first_free）を足す（012 の my_points を置きかえる）
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
    'first_free', first_free_available(),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'delta', r.delta, 'reason', r.reason, 'note', r.note, 'created_at', r.created_at, 'label', r.label)
               order by r.created_at desc, r.id desc), '[]'::jsonb)
               from (select l.*,
                            case when l.reason like 'feedback%' then (select f.game_slug from feedback f where f.id = l.ref)
                                 when l.reason like 'submission%' then (select s.data ->> 'title' from submissions s where s.id = l.ref) end as label
                     from points_ledger l where l.user_id = uid and (l.delta <> 0)
                     order by l.created_at desc, l.id desc limit 20) r));
end $$;

-- ---------- 権限 ----------
revoke all on function public.first_free_available(), public.admin_free_used(),
  public.submission_send(text, text, jsonb), public.my_points()
  from public, anon, authenticated;
grant execute on function public.first_free_available(), public.admin_free_used(),
  public.submission_send(text, text, jsonb), public.my_points() to authenticated;

select 'ok 013' as result;
