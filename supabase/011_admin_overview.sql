-- 管理ページの「概要」タブ用
--   site_visits    … サイトを開いた記録（1つの端末は、1日に1回だけ数える）
--   admin_overview … 訪問・遊んだ数・感想・応募・報告などの合計と、日ごとの数、よく遊ばれた作品（運営だけ）

-- ---------- 訪問の記録 ----------
-- game_events などと同じ作り：だれでも書き込める（insert だけ）／中身は外から読めない／BANされた端末は断る
-- day は日本時間の日付。同じ端末が同じ日にもう一度送っても、unique で断られるだけ（サイト側は気にしない）
create table if not exists public.site_visits (
  id bigint generated always as identity primary key,
  client_id text not null check (length(client_id) between 8 and 64),
  day date not null default ((now() at time zone 'Asia/Tokyo')::date),
  created_at timestamptz not null default now(),
  unique (client_id, day)
);
create index if not exists site_visits_day on public.site_visits (day);

alter table public.site_visits enable row level security;
drop policy if exists "誰でも記録できる" on public.site_visits;
create policy "誰でも記録できる" on public.site_visits for insert to anon, authenticated with check (true);
revoke all on public.site_visits from anon, authenticated;
grant insert on public.site_visits to anon, authenticated;
drop trigger if exists site_visits_reject_banned on public.site_visits;
create trigger site_visits_reject_banned before insert on public.site_visits
  for each row execute function public.reject_banned_clients();

-- ---------- 概要 ----------
-- since_days：1（今日）・7・30・3650（ぜんぶ）。日本時間の日付で数える（7なら、今日を入れて7日）
-- 返すもの
--   visitors / visits       訪問した端末の数（重複なし）／「端末×日」の数
--   plays                   「遊ぶ」を押した数（同じ人が同じ作品を同じ日に押しても1回）
--   players                 遊んだ端末の数（重複なし）
--   play_seconds_total      サイトの中で遊んだ時間の合計（秒）／ sessions はその数
--   feedbacks               {visible, hidden}
--   likes / hmms            👍・🤔 を押した数（同じ人が同じ作品を同じ日に押しても1回）
--   submissions             期間中の応募の数 {new, ok, ng}（new=確認中、ok=載せた・直した、ng=見送り）
--   submissions_open        確認中の応募の数（期間に関係なく、いまの数）
--   reports_open            未対応の報告の数（いまの数）
--   bans                    BANの数（いまの数）{client, user}
--   new_users               期間中に初めてログインしたアカウントの数
--   daily                   日ごとの {day, visits, plays, feedbacks}（古い順。今日までの7日〜30日・0の日も入れる）
--   top_games               遊ばれた数が多い作品の上位5つ {slug, plays, feedbacks}（feedbacks は表示中の感想）
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
  sb as (select * from submissions   where created_at >= v_t0)
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

-- 管理者だけ（anon は呼べない）
revoke all on function public.admin_overview(int) from public, anon;
grant execute on function public.admin_overview(int) to authenticated;
