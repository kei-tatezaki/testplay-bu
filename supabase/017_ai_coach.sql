-- 017: AIコーチ（Edge Function feedback-coach）の1日の回数制限
--   ai_coach_uses … 1人1日（JST 朝5時区切り＝ミッションと同じ「今日」）に何回使ったか
--   ai_coach_take()   … 1回分を取る。残り回数を返す。上限（settings 'ai_coach_daily_limit'、既定20）を超えたら例外 'limit'
--   ai_coach_refund() … Gemini が失敗したとき、取った1回を返す
-- 016（mission_day）と 012（settings・setting_int）のあとに流す。何度流しても同じ。

create table if not exists public.ai_coach_uses (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  count int not null default 0 check (count >= 0),
  primary key (user_id, day)
);
alter table public.ai_coach_uses enable row level security;
revoke all on public.ai_coach_uses from anon, authenticated;

insert into public.settings (key, value, label) values
  ('ai_coach_daily_limit', 20, 'AIコーチを、1人が1日（日本時間の朝5時区切り）に使える回数')
on conflict (key) do nothing;

create or replace function public.ai_coach_take() returns int
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d date := mission_day();
  lim int := setting_int('ai_coach_daily_limit', 20);
  c int;
begin
  if uid is null then raise exception 'login'; end if;
  if is_banned() then raise exception 'banned'; end if;
  insert into ai_coach_uses (user_id, day, count) values (uid, d, 0) on conflict do nothing;
  update ai_coach_uses set count = count + 1 where user_id = uid and day = d and count < lim returning count into c;
  if c is null then raise exception 'limit'; end if;
  return lim - c;
end $$;

create or replace function public.ai_coach_refund() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update ai_coach_uses set count = count - 1 where user_id = auth.uid() and day = mission_day() and count > 0;
end $$;

revoke all on function public.ai_coach_take(), public.ai_coach_refund() from public, anon, authenticated;
grant execute on function public.ai_coach_take(), public.ai_coach_refund() to authenticated;

select 'ok 017' as result;
