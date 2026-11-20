-- 017: AIコーチ（Edge Function feedback-coach）の回数制限
--   ・既定の1日の回数        … settings 'ai_coach_daily_limit'（既定30）
--   ・アカウントごとの上書き … ai_coach_limits（0 で、その人だけ停止）。運営だけが読み書きできる
--   ・短時間の連打           … 同じ人が直近60秒に6回使っていたら 'too_fast'
--   ・1日は日本時間の朝5時区切り（ミッションと同じ mission_day()）
-- 012（settings・setting_int）・006（is_admin）・009（is_banned）・016（mission_day）のあとに流す。何度流しても同じ。
--   ai_coach_take()   … 1回分を取り、その人の残り回数を返す。例外：login / banned / limit / too_fast
--   ai_coach_refund() … AI の呼び出しが失敗したとき、取った1回を返す（連打の記録も1行戻す）

create table if not exists public.ai_coach_uses (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  count int not null default 0 check (count >= 0),
  primary key (user_id, day)
);
create table if not exists public.ai_coach_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  at timestamptz not null default now()
);
create index if not exists ai_coach_log_user_at on public.ai_coach_log (user_id, at desc);
create index if not exists ai_coach_log_at on public.ai_coach_log (at);
create table if not exists public.ai_coach_limits (
  user_id uuid primary key references auth.users (id) on delete cascade,
  daily_limit int not null check (daily_limit >= 0 and daily_limit <= 100000),
  note text,
  updated_at timestamptz not null default now()
);
alter table public.ai_coach_uses enable row level security;
alter table public.ai_coach_log enable row level security;
alter table public.ai_coach_limits enable row level security;
revoke all on public.ai_coach_uses, public.ai_coach_log, public.ai_coach_limits from anon, authenticated;

insert into public.settings (key, value, label) values
  ('ai_coach_daily_limit', 30, 'AIコーチを、1人が1日（朝5時区切り）に使える回数（初期値。人ごとに変えられる）')
on conflict (key) do nothing;

create or replace function public.ai_coach_take() returns int
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d date := mission_day();
  lim int; c int;
begin
  if uid is null then raise exception 'login'; end if;
  if is_banned() then raise exception 'banned'; end if;
  delete from ai_coach_log where at < now() - interval '7 days';
  lim := coalesce((select daily_limit from ai_coach_limits where user_id = uid), setting_int('ai_coach_daily_limit', 30));
  if coalesce((select count from ai_coach_uses where user_id = uid and day = d), 0) >= lim then raise exception 'limit'; end if;
  if (select count(*) from ai_coach_log where user_id = uid and at > now() - interval '60 seconds') >= 6 then raise exception 'too_fast'; end if;
  insert into ai_coach_uses (user_id, day, count) values (uid, d, 1)
    on conflict (user_id, day) do update set count = ai_coach_uses.count + 1 returning count into c;
  insert into ai_coach_log (user_id) values (uid);
  return lim - c;
end $$;

create or replace function public.ai_coach_refund() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update ai_coach_uses set count = count - 1 where user_id = auth.uid() and day = mission_day() and count > 0;
  delete from ai_coach_log where id = (select id from ai_coach_log where user_id = auth.uid() order by at desc, id desc limit 1);
end $$;

-- ---------- 運営だけ ----------
create or replace function public.admin_ai_limit_set(p_user uuid, p_limit int, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if p_limit is null or p_limit < 0 or p_limit > 100000 then raise exception 'bad_value'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'no_user'; end if;
  insert into ai_coach_limits (user_id, daily_limit, note) values (p_user, p_limit, nullif(left(coalesce(p_note, ''), 200), ''))
    on conflict (user_id) do update set daily_limit = excluded.daily_limit, note = excluded.note, updated_at = now();
  return case when p_limit = 0 then '停止しました' else '変えました' end;
end $$;

create or replace function public.admin_ai_limit_clear(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  delete from ai_coach_limits where user_id = p_user;
  return '初期値に戻しました';
end $$;

-- 利用の多い順。今日・期間（p_days 日、今日を入れる）の合計・その人の上限
create or replace function public.admin_ai_usage(p_days int default 7)
returns table (user_id uuid, name text, email text, today int, total int, daily_limit int, has_override boolean, note text)
language plpgsql stable security definer set search_path = public as $$
declare dd int := greatest(1, least(coalesce(p_days, 7), 90));
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select x.id,
           coalesce(x.raw_user_meta_data ->> 'full_name', x.raw_user_meta_data ->> 'name', split_part(x.email, '@', 1))::text,
           x.email::text,
           coalesce(u.today, 0)::int, coalesce(u.total, 0)::int,
           coalesce(l.daily_limit, setting_int('ai_coach_daily_limit', 30))::int,
           l.user_id is not null, l.note
    from (select s.user_id as id,
                 sum(s.count) filter (where s.day = mission_day()) as today,
                 sum(s.count) filter (where s.day > mission_day() - dd) as total
          from ai_coach_uses s group by s.user_id) u
    full join ai_coach_limits l on l.user_id = u.id
    join auth.users x on x.id = coalesce(u.id, l.user_id)
    order by coalesce(u.total, 0) desc, coalesce(u.today, 0) desc, x.email
    limit 200;
end $$;

create or replace function public.admin_ai_today() returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select sum(count) from ai_coach_uses where day = mission_day()), 0)::int;
end $$;

revoke all on function public.ai_coach_take(), public.ai_coach_refund(), public.admin_ai_limit_set(uuid, int, text),
  public.admin_ai_limit_clear(uuid), public.admin_ai_usage(int), public.admin_ai_today() from public, anon, authenticated;
grant execute on function public.ai_coach_take(), public.ai_coach_refund(), public.admin_ai_limit_set(uuid, int, text),
  public.admin_ai_limit_clear(uuid), public.admin_ai_usage(int), public.admin_ai_today() to authenticated;

select 'ok 017' as result;
