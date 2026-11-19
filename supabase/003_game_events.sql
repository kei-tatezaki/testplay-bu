-- 「遊ぶ」「👍」「🤔」を記録して、作品ごとの数字（遊ばれた数・感想の数・評価）を出せるようにする
-- 同じ人が同じ日に同じ作品で何回押しても1回として数える

create table if not exists public.game_events (
  id bigint generated always as identity primary key,
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  kind text not null check (kind in ('play','like','hmm')),
  client_id text not null check (length(client_id) between 8 and 64),
  day date not null default ((now() at time zone 'Asia/Tokyo')::date),
  created_at timestamptz not null default now()
);
create unique index if not exists game_events_once on public.game_events (game_slug, kind, client_id, day);
create index if not exists game_events_recent on public.game_events (created_at);

alter table public.game_events enable row level security;
drop policy if exists "誰でも記録できる" on public.game_events;
create policy "誰でも記録できる" on public.game_events for insert to anon, authenticated with check (true);
-- 一件ずつの記録（client_id）は外から読めない。集計だけを下の関数で出す
revoke all on public.game_events from anon, authenticated;
grant insert on public.game_events to anon, authenticated;

-- 直近 since_days 日の作品ごとの数字
create or replace function public.game_stats(since_days int default 7)
returns table (
  game_slug text, plays bigint, likes bigint, hmms bigint,
  feedbacks bigint, again_much bigint, again_some bigint
)
language sql stable security definer set search_path = public as $$
  with w as (select now() - make_interval(days => greatest(1, least(coalesce(since_days, 7), 3650))) as t),
  e as (
    select game_slug,
           count(distinct client_id) filter (where kind = 'play') as plays,
           count(distinct client_id) filter (where kind = 'like') as likes,
           count(distinct client_id) filter (where kind = 'hmm')  as hmms
    from game_events, w where created_at >= w.t group by game_slug
  ),
  f as (
    select game_slug,
           count(*) as feedbacks,
           count(*) filter (where again = 'すごく遊びたい')   as again_much,
           count(*) filter (where again = 'ちょっと遊びたい') as again_some
    from feedback, w where hidden = false and created_at >= w.t group by game_slug
  )
  select coalesce(e.game_slug, f.game_slug),
         coalesce(e.plays, 0), coalesce(e.likes, 0), coalesce(e.hmms, 0),
         coalesce(f.feedbacks, 0), coalesce(f.again_much, 0), coalesce(f.again_some, 0)
  from e full join f on e.game_slug = f.game_slug;
$$;
revoke all on function public.game_stats(int) from public;
grant execute on function public.game_stats(int) to anon, authenticated;
