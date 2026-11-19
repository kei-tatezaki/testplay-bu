-- 開発者向けアナリティクス
--   play_sessions … サイトの中で遊んだ時間（ゲームを開いてから閉じるまで）
--   game_owners   … どの作品を誰が作ったか（管理ページで運営が決める）
--   dev_stats     … 作者（と運営）だけが見られる、作品ごとの数字

create table if not exists public.play_sessions (
  id bigint generated always as identity primary key,
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  client_id text not null check (length(client_id) between 8 and 64),
  seconds int not null check (seconds between 0 and 21600),
  device text check (device in ('pc', 'sp')),
  created_at timestamptz not null default now()
);
create index if not exists play_sessions_game on public.play_sessions (game_slug, created_at);
alter table public.play_sessions enable row level security;
drop policy if exists "誰でも記録できる" on public.play_sessions;
create policy "誰でも記録できる" on public.play_sessions for insert to anon, authenticated with check (true);
revoke all on public.play_sessions from anon, authenticated;
grant insert on public.play_sessions to anon, authenticated;
drop trigger if exists play_sessions_reject_banned on public.play_sessions;
create trigger play_sessions_reject_banned before insert on public.play_sessions
  for each row execute function public.reject_banned_clients();

create table if not exists public.game_owners (
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (game_slug, user_id)
);
alter table public.game_owners enable row level security;
revoke all on public.game_owners from anon, authenticated;

create or replace function public.can_see_game(slug text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (is_admin() or exists (select 1 from game_owners where game_slug = slug and user_id = auth.uid()));
$$;

-- 自分が作者になっている作品
create or replace function public.dev_games() returns table (game_slug text)
language sql stable security definer set search_path = public as $$
  select game_slug from game_owners where user_id = auth.uid() order by created_at;
$$;

-- 作品ごとの数字（直近 since_days 日）
create or replace function public.dev_stats(slug text, since_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t timestamptz := now() - make_interval(days => greatest(1, least(coalesce(since_days, 30), 3650)));
  res jsonb;
begin
  if not can_see_game(slug) then raise exception 'not_allowed'; end if;
  with
  ev as (select * from game_events where game_slug = slug and created_at >= t),
  ps as (select * from play_sessions where game_slug = slug and created_at >= t),
  fb as (select * from feedback where game_slug = slug and hidden = false and created_at >= t)
  select jsonb_build_object(
    'plays',    (select count(distinct client_id) from ev where kind = 'play'),
    'likes',    (select count(distinct client_id) from ev where kind = 'like'),
    'hmm',      (select coalesce(jsonb_object_agg(r, n), '{}'::jsonb) from (select coalesce(reason, 'none') r, count(distinct client_id) n from ev where kind = 'hmm' group by 1) x),
    'sessions', (select count(*) from ps),
    'median_seconds', (select percentile_cont(0.5) within group (order by seconds) from ps),
    'quit30',   (select count(*) from ps where seconds < 30),
    'buckets',  (select jsonb_build_array(
                   count(*) filter (where seconds < 30),
                   count(*) filter (where seconds >= 30 and seconds < 60),
                   count(*) filter (where seconds >= 60 and seconds < 180),
                   count(*) filter (where seconds >= 180 and seconds < 300),
                   count(*) filter (where seconds >= 300)) from ps),
    'devices',  (select coalesce(jsonb_object_agg(d, n), '{}'::jsonb) from (select coalesce(device, '?') d, count(*) n from ps group by 1) x),
    'hours',    (select coalesce(jsonb_object_agg(h, n), '{}'::jsonb) from (select extract(hour from created_at at time zone 'Asia/Tokyo')::int h, count(*) n from ev where kind = 'play' group by 1) x),
    'feedbacks',(select count(*) from fb),
    'again',    (select coalesce(jsonb_object_agg(again, n), '{}'::jsonb) from (select again, count(*) n from fb group by 1) x),
    'reach',    (select coalesce(jsonb_object_agg(reach, n), '{}'::jsonb) from (select reach, count(*) n from fb group by 1) x),
    'stop_at',  (select coalesce(jsonb_agg(stop_at order by created_at desc), '[]'::jsonb) from fb where coalesce(stop_at, '') <> ''),
    'good',     (select coalesce(jsonb_object_agg(v, n), '{}'::jsonb) from (select unnest(good) v, count(*) n from fb group by 1) x),
    'bad',      (select coalesce(jsonb_object_agg(v, n), '{}'::jsonb) from (select unnest(bad) v, count(*) n from fb group by 1) x),
    'answer',   (select coalesce(jsonb_object_agg(answer, n), '{}'::jsonb) from (select answer, count(*) n from fb where answer is not null group by 1) x)
  ) into res;
  return res;
end $$;

-- 作品に届いた感想（だれが書いたかは出さない）
create or replace function public.dev_feedback(slug text, lim int default 200)
returns table (id uuid, created_at timestamptz, again text, reach text, stop_at text, good text[], bad text[],
               answer text, free text, is_dev boolean, liked_by_dev boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_game(slug) then raise exception 'not_allowed'; end if;
  return query
    select f.id, f.created_at, f.again, f.reach, f.stop_at, f.good, f.bad, f.answer, f.free, f.is_dev, f.liked_by_dev
    from feedback f where f.game_slug = slug and f.hidden = false
    order by f.created_at desc limit greatest(1, least(coalesce(lim, 200), 1000));
end $$;

-- 作者が感想に「いいね」する
create or replace function public.dev_like(fid uuid, val boolean) returns text
language plpgsql security definer set search_path = public as $$
declare slug text;
begin
  select game_slug into slug from feedback where id = fid;
  if slug is null or not can_see_game(slug) then raise exception 'not_allowed'; end if;
  update feedback set liked_by_dev = val where id = fid;
  return case when val then 'いいねしました' else 'いいねを取り消しました' end;
end $$;

-- 管理ページ：ログインしたことのある人の一覧と、作者の設定
create or replace function public.admin_users()
returns table (id uuid, name text, email text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select u.id, coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text,
           u.email::text, u.created_at
    from auth.users u order by u.created_at desc;
end $$;

create or replace function public.admin_owners()
returns table (game_slug text, user_id uuid, name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select o.game_slug, o.user_id, coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text
    from game_owners o join auth.users u on u.id = o.user_id order by o.game_slug, o.created_at;
end $$;

create or replace function public.admin_set_owner(slug text, uid uuid, add boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if add then
    insert into game_owners (game_slug, user_id) values (slug, uid) on conflict do nothing;
    return '作者にしました';
  end if;
  delete from game_owners where game_slug = slug and user_id = uid;
  return '作者から外しました';
end $$;

revoke all on function public.can_see_game(text), public.dev_games(), public.dev_stats(text, int), public.dev_feedback(text, int),
  public.dev_like(uuid, boolean), public.admin_users(), public.admin_owners(), public.admin_set_owner(text, uuid, boolean) from public, anon;
grant execute on function public.can_see_game(text), public.dev_games(), public.dev_stats(text, int), public.dev_feedback(text, int),
  public.dev_like(uuid, boolean), public.admin_users(), public.admin_owners(), public.admin_set_owner(text, uuid, boolean) to authenticated;
