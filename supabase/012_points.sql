-- ポイント制：感想を書くとポイントがたまり、作品の応募に使う
--   settings       … ポイントの決まり（数字）。管理ページで変えられる
--   points_ledger  … ポイントの記録（足す・引くの1行ずつ）。残高は合計で出す。外からは読めない・書けない
-- ポイントの計算と残高のチェックは、すべてこのデータベースの中でやる（画面からは増やせない）
--   ・感想を送る（feedback への insert）→ トリガーが条件を調べてポイントを足す
--   ・運営が感想を非表示／表示に戻す（hidden が変わる）→ トリガーが取り消す／返す
--   ・応募（submission_send）→ 30pt（settings）を同じトランザクションで引く。足りなければ not_enough_points
--   ・「見送り」（admin_submission_set）→ 引いた分を返す
-- 今までの感想には、さかのぼってポイントを付けない。

-- ---------- 決まり ----------
create table if not exists public.settings (
  key text primary key,
  value int not null check (value >= 0 and value <= 100000),
  label text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;
revoke all on public.settings from anon, authenticated;

insert into public.settings (key, value, label) values
  ('min_chars',   40, '感想の一言が、何文字以上でポイントがもらえるか（空白は数えない）'),
  ('daily_cap',   50, '1日（日本時間）にもらえるポイントの上限'),
  ('tier1_max',    2, '「感想が少ない」の上の境目（この件数まで）'),
  ('tier1_pt',    10, '感想が少ない作品（0〜tier1_max件）でもらえるポイント'),
  ('tier2_max',    9, '「ふつう」の上の境目（この件数まで）'),
  ('tier2_pt',     5, 'ふつうの作品（tier1_max+1〜tier2_max件）でもらえるポイント'),
  ('tier3_pt',     2, '感想が多い作品（それより多い）でもらえるポイント'),
  ('submit_cost', 30, '作品を応募するのに必要なポイント')
on conflict (key) do nothing;

create or replace function public.setting_int(k text, d int default 0) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select value from settings where key = k), d);
$$;

-- ---------- 記録 ----------
create table if not exists public.points_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  delta int not null,
  reason text not null check (reason in ('feedback', 'feedback_revoked', 'feedback_restored', 'submission', 'submission_refund', 'admin_adjust')),
  ref uuid,                      -- 感想のID（feedback*）／応募のID（submission*）
  note text not null default '', -- feedback で 0pt のときの理由（short／lazy／own／not_played／cap）、admin_adjust のときの運営の一言
  created_at timestamptz not null default now()
);
create index if not exists points_ledger_user on public.points_ledger (user_id, created_at desc);
create index if not exists points_ledger_ref on public.points_ledger (ref) where ref is not null;
-- 1つの感想でポイントを決めるのは1回だけ
create unique index if not exists points_ledger_feedback_once on public.points_ledger (ref) where reason = 'feedback';
alter table public.points_ledger enable row level security;
revoke all on public.points_ledger from anon, authenticated;   -- 方針（policy）も作らない：外から読めない・書けない

-- ---------- 部品（外からは呼べない） ----------
-- 同じ文字のくり返し・水増しの文か（005 の reject_lazy_dev と同じ考え）
create or replace function public.is_lazy_text(txt text) returns boolean
language sql immutable set search_path = public as $$
  select (select count(distinct c) from regexp_split_to_table(regexp_replace(coalesce(txt, ''), '[\s　]', '', 'g'), '') as c) < 12
      or regexp_replace(coalesce(txt, ''), '[\s　]', '', 'g') ~ '(.)\1{5,}';
$$;

create or replace function public.points_balance(uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from points_ledger where user_id = uid;
$$;

-- 今日（日本時間）にもらった分（取り消しで減らさない：上限は「もらった総量」で見る）
create or replace function public.points_today(uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from points_ledger
  where user_id = uid and reason = 'feedback'
    and (created_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date;
$$;

-- 表示中の感想が n 件の作品に感想を書くと、いくつもらえるか（上限の前）
create or replace function public.points_for_count(n int) returns int
language sql stable security definer set search_path = public as $$
  select case when n <= setting_int('tier1_max', 2) then setting_int('tier1_pt', 10)
              when n <= setting_int('tier2_max', 9) then setting_int('tier2_pt', 5)
              else setting_int('tier3_pt', 2) end;
$$;

create or replace function public.points_lock(uid uuid) returns void
language sql security definer set search_path = public as $$
  select pg_advisory_xact_lock(hashtextextended('points:' || uid::text, 0));
$$;

-- ---------- 貯める：感想を送ったとき ----------
create or replace function public.feedback_points_award() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n int; base int; got int; cap int; give int; why text := '';
begin
  if new.user_id is null then return new; end if;
  begin
    perform points_lock(new.user_id);
    cap := setting_int('daily_cap', 50);
    got := points_today(new.user_id);
    select count(*) into n from feedback f
      where f.game_slug = new.game_slug and f.hidden = false and f.id <> new.id and f.user_id is distinct from new.user_id;
    base := points_for_count(n);
    if char_length(regexp_replace(coalesce(new.free, ''), '[\s　]', '', 'g')) < setting_int('min_chars', 40) then why := 'short';
    elsif is_lazy_text(new.free) then why := 'lazy';
    elsif exists (select 1 from game_owners o where o.game_slug = new.game_slug and o.user_id = new.user_id) then why := 'own';
    elsif not exists (select 1 from game_events e where e.game_slug = new.game_slug and e.client_id = new.client_id and e.kind = 'play') then why := 'not_played';
    elsif got >= cap then why := 'cap';
    end if;
    give := case when why = '' then least(base, cap - got) else 0 end;
    insert into points_ledger (user_id, delta, reason, ref, note) values (new.user_id, give, 'feedback', new.id, why);
  exception when others then
    -- ポイントの計算でつまずいても、感想は受け付ける
    raise warning 'feedback_points_award: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists feedback_points_award on public.feedback;
create trigger feedback_points_award after insert on public.feedback
  for each row execute function public.feedback_points_award();

-- ---------- 取り消す・返す：感想が非表示／表示に戻ったとき ----------
-- admin_set_hidden・mod_hide・mod_unhide・BANの一括非表示は、どれも feedback.hidden を変えるので、ここ1か所で受ける
-- 「いまの正味」を見て動くので、何度繰り返しても二重にならない
create or replace function public.feedback_points_hidden() returns trigger
language plpgsql security definer set search_path = public as $$
declare orig int; net int;
begin
  if new.user_id is null then return new; end if;
  perform points_lock(new.user_id);
  select delta into orig from points_ledger where reason = 'feedback' and ref = new.id;
  if coalesce(orig, 0) <= 0 then return new; end if;   -- 0pt だった感想・さかのぼり前の感想は何もしない
  select coalesce(sum(delta), 0) into net from points_ledger
    where ref = new.id and reason in ('feedback', 'feedback_revoked', 'feedback_restored');
  if new.hidden and net > 0 then
    insert into points_ledger (user_id, delta, reason, ref) values (new.user_id, -net, 'feedback_revoked', new.id);
  elsif not new.hidden and net = 0 then
    insert into points_ledger (user_id, delta, reason, ref) values (new.user_id, orig, 'feedback_restored', new.id);
  end if;
  return new;
end $$;
drop trigger if exists feedback_points_hidden on public.feedback;
create trigger feedback_points_hidden after update of hidden on public.feedback
  for each row when (old.hidden is distinct from new.hidden)
  execute function public.feedback_points_hidden();

-- ---------- 使う：作品の応募（009 の submission_send を、ポイントを引く形に置きかえる） ----------
create or replace function public.submission_send(p_kind text, p_slug text, p_data jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d jsonb := coalesce(p_data, '{}'::jsonb);
  k text; val text; clean jsonb := '{}'::jsonb;
  cost int := setting_int('submit_cost', 30);
  sid uuid;
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
  if p_kind = 'new' and cost > 0 and not is_admin() then
    perform points_lock(uid);
    if points_balance(uid) < cost then raise exception 'not_enough_points'; end if;
  end if;
  insert into submissions (user_id, kind, game_slug, data) values (uid, p_kind, case when p_kind = 'edit' then p_slug end, clean)
    returning id into sid;
  if p_kind = 'new' and cost > 0 and not is_admin() then
    insert into points_ledger (user_id, delta, reason, ref) values (uid, -cost, 'submission', sid);
  end if;
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

-- この作品にいま感想を書くと何ポイントか（だれでも。ログインしていれば自分の分も考える）
--   p_client を渡すと「遊んだか」も見る。blocked は 0pt になる理由：already／own／not_played／cap
create or replace function public.game_point_hint(p_slug text, p_client text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); n int; base int; blocked text; left_today int; pts int;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  select count(*) into n from feedback f where f.game_slug = p_slug and f.hidden = false and f.user_id is distinct from uid;
  base := points_for_count(n);
  pts := base;
  if uid is not null then
    left_today := greatest(setting_int('daily_cap', 50) - points_today(uid), 0);
    if exists (select 1 from game_owners o where o.game_slug = p_slug and o.user_id = uid) then blocked := 'own';
    elsif exists (select 1 from feedback f where f.game_slug = p_slug and f.user_id = uid) then blocked := 'already';
    elsif p_client is not null and length(p_client) between 8 and 64
          and not exists (select 1 from game_events e where e.game_slug = p_slug and e.client_id = p_client and e.kind = 'play') then blocked := 'not_played';
    elsif left_today <= 0 then blocked := 'cap';
    end if;
    pts := case when blocked is null then least(base, left_today) else 0 end;
  end if;
  return jsonb_build_object('feedbacks', n, 'base', base, 'points', pts, 'blocked', blocked, 'left_today', left_today);
end $$;

-- 感想を送った直後：その感想で何ポイントもらえたか（なぜ 0pt かの理由つき）
create or replace function public.feedback_points_result(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('delta', l.delta, 'note', l.note, 'balance', points_balance(auth.uid()))
  from feedback f join points_ledger l on l.ref = f.id and l.reason = 'feedback'
  where f.user_id = auth.uid() and f.game_slug = p_slug;
$$;

-- ---------- 運営だけ ----------
create or replace function public.admin_points_users()
returns table (user_id uuid, name text, email text, handle text, balance int, earned int, spent int, adjusted int, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select u.id,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text,
           u.email::text, p.handle,
           coalesce(sum(l.delta), 0)::int,
           coalesce(sum(l.delta) filter (where l.reason in ('feedback', 'feedback_revoked', 'feedback_restored')), 0)::int,
           coalesce(-sum(l.delta) filter (where l.reason in ('submission', 'submission_refund')), 0)::int,
           coalesce(sum(l.delta) filter (where l.reason = 'admin_adjust'), 0)::int,
           max(l.created_at)
    from auth.users u
    left join points_ledger l on l.user_id = u.id
    left join profiles p on p.user_id = u.id
    where exists (select 1 from points_ledger x where x.user_id = u.id) or p.user_id is not null
    group by u.id, u.raw_user_meta_data, u.email, p.handle
    order by 5 desc, 9 desc nulls last
    limit 500;
end $$;

create or replace function public.admin_points_adjust(uid uuid, delta int, note text) returns text
language plpgsql security definer set search_path = public as $$
declare n text := left(btrim(coalesce(note, '')), 200); bal int;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if delta is null or delta = 0 or abs(delta) > 10000 then raise exception 'bad_delta'; end if;
  if n = '' then raise exception 'need_note'; end if;
  if not exists (select 1 from auth.users where id = uid) then raise exception 'no_user'; end if;
  perform points_lock(uid);
  insert into points_ledger (user_id, delta, reason, note) values (uid, delta, 'admin_adjust', n);
  bal := points_balance(uid);
  return (case when delta > 0 then '+' else '' end) || delta || 'pt にしました（残高 ' || bal || 'pt）';
end $$;

create or replace function public.admin_settings_get()
returns table (key text, value int, label text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select s.key, s.value, s.label from settings s
    order by array_position(array['min_chars','daily_cap','tier1_max','tier1_pt','tier2_max','tier2_pt','tier3_pt','submit_cost'], s.key), s.key;
end $$;

create or replace function public.admin_settings_set(p_key text, p_value int) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if p_value is null or p_value < 0 or p_value > 100000 then raise exception 'bad_value'; end if;
  if p_key = 'min_chars' and (p_value < 1 or p_value > 400) then raise exception 'bad_value'; end if;
  update settings set value = p_value, updated_at = now() where key = p_key;
  if not found then raise exception 'bad_key'; end if;
  if setting_int('tier1_max') >= setting_int('tier2_max') then raise exception 'bad_tiers'; end if;   -- 境目は 少ない < ふつう の順（置きかえた値ごと取り消される）
  return '変えました';
end $$;

-- ---------- 概要に、配った・使われたポイントを足す（011 の admin_overview を置きかえる） ----------
create or replace function public.admin_overview(since_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_n     int  := greatest(1, least(coalesce(since_days, 7), 3650));
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_d0    date := (now() at time zone 'Asia/Tokyo')::date - (greatest(1, least(coalesce(since_days, 7), 3650)) - 1);
  v_t0    timestamptz;
  v_g     int  := case when greatest(1, least(coalesce(since_days, 7), 3650)) <= 7 then 7
                       else least(greatest(1, least(coalesce(since_days, 7), 3650)), 30) end;
  res     jsonb;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  v_t0 := v_d0::timestamp at time zone 'Asia/Tokyo';
  with
  sv as (select * from site_visits  where day >= v_d0),
  ev as (select * from game_events  where day >= v_d0),
  ps as (select * from play_sessions where created_at >= v_t0),
  fb as (select * from feedback      where created_at >= v_t0),
  sb as (select * from submissions   where created_at >= v_t0),
  pl as (select * from points_ledger where created_at >= v_t0)
  select jsonb_build_object(
    'since_days',  v_n,
    'from',        to_char(v_d0, 'YYYY-MM-DD'),
    'visitors',    (select count(distinct client_id) from sv),
    'visits',      (select count(*) from sv),
    'plays',       (select count(*) from ev where kind = 'play'),
    'players',     (select count(distinct client_id) from ev where kind = 'play'),
    'play_seconds_total', (select coalesce(sum(seconds), 0) from ps),
    'sessions',    (select count(*) from ps),
    'feedbacks',   jsonb_build_object(
                     'visible', (select count(*) from fb where hidden = false),
                     'hidden',  (select count(*) from fb where hidden = true)),
    'likes',       (select count(*) from ev where kind = 'like'),
    'hmms',        (select count(*) from ev where kind = 'hmm'),
    'submissions', jsonb_build_object(
                     'new', (select count(*) from sb where status = 'new'),
                     'ok',  (select count(*) from sb where status = 'ok'),
                     'ng',  (select count(*) from sb where status = 'ng')),
    'submissions_open', (select count(*) from submissions where status = 'new'),
    'reports_open',     (select count(*) from reports where done = false),
    'bans',        jsonb_build_object(
                     'client', (select count(*) from banned_clients),
                     'user',   (select count(*) from banned_users)),
    'points',      jsonb_build_object(
                     'granted',     (select coalesce(sum(delta), 0) from pl where reason = 'feedback'),
                     'revoked',     (select coalesce(-sum(delta), 0) from pl where reason in ('feedback_revoked', 'feedback_restored')),
                     'spent',       (select coalesce(-sum(delta), 0) from pl where reason = 'submission'),
                     'refunded',    (select coalesce(sum(delta), 0) from pl where reason = 'submission_refund'),
                     'adjusted',    (select coalesce(sum(delta), 0) from pl where reason = 'admin_adjust'),
                     'outstanding', (select coalesce(sum(delta), 0) from points_ledger)),
    'new_users',   (select count(*) from auth.users u where u.created_at >= v_t0),
    'daily',       (select coalesce(jsonb_agg(jsonb_build_object(
                       'day', to_char(g.d, 'YYYY-MM-DD'),
                       'visits',    (select count(*) from site_visits x where x.day = g.d),
                       'plays',     (select count(*) from game_events e where e.kind = 'play' and e.day = g.d),
                       'feedbacks', (select count(*) from feedback f where (f.created_at at time zone 'Asia/Tokyo')::date = g.d)
                     ) order by g.d), '[]'::jsonb)
                    from (select (v_today - i)::date as d from generate_series(0, v_g - 1) i) g),
    'top_games',   (select coalesce(jsonb_agg(jsonb_build_object('slug', t.game_slug, 'plays', t.plays, 'feedbacks', t.feedbacks)
                                              order by t.plays desc, t.feedbacks desc, t.game_slug), '[]'::jsonb)
                    from (select p.game_slug, p.plays,
                                 (select count(*) from fb where fb.game_slug = p.game_slug and fb.hidden = false) as feedbacks
                          from (select game_slug, count(*) as plays from ev where kind = 'play' group by game_slug) p
                          order by p.plays desc, 3 desc, p.game_slug limit 5) t)
  ) into res;
  return res;
end $$;
-- ---------- 権限 ----------
revoke all on function
  public.setting_int(text, int), public.is_lazy_text(text), public.points_balance(uuid), public.points_today(uuid),
  public.points_for_count(int), public.points_lock(uuid),
  public.feedback_points_award(), public.feedback_points_hidden(),
  public.submission_send(text, text, jsonb), public.admin_submission_set(uuid, text, text),
  public.my_points(), public.points_rule(), public.game_point_hint(text, text), public.feedback_points_result(text),
  public.admin_points_users(), public.admin_points_adjust(uuid, int, text), public.admin_settings_get(), public.admin_settings_set(text, int),
  public.admin_overview(int)
  from public, anon, authenticated;

grant execute on function public.points_rule(), public.game_point_hint(text, text) to anon, authenticated;
grant execute on function
  public.submission_send(text, text, jsonb), public.admin_submission_set(uuid, text, text),
  public.my_points(), public.feedback_points_result(text),
  public.admin_points_users(), public.admin_points_adjust(uuid, int, text), public.admin_settings_get(), public.admin_settings_set(text, int),
  public.admin_overview(int)
  to authenticated;

select 'ok 012' as result;
