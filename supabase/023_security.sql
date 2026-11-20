-- 023 守りを固める
--   ・緊急停止スイッチ（settings.read_only = 1 のあいだ、運営以外の書き込みを全部止める。読むのはそのまま）
--   ・書き込みの回数制限：1時間あたり「同じネットワーク（IPアドレスの指紋）」「同じアカウント」「同じ端末ID」ごと
--     IPアドレスそのものは保存しない。秘密の文字列と日付をまぜた指紋（16文字）だけを、2日で消える数え表に置く
--   ・site_status()：だれでも「いま止めているか」だけ読める（サイトの上にお知らせを出すため）
-- 何度流しても同じ結果になる（if not exists / or replace / on conflict）。

-- ---------- 数え表と、指紋用の秘密 ----------
create table if not exists public.rate_hits (
  bucket text not null,
  k      text not null,
  win    timestamptz not null,
  n      int not null default 1,
  primary key (bucket, k, win)
);
alter table public.rate_hits enable row level security;
revoke all on public.rate_hits from anon, authenticated;

create table if not exists public.private_salt (
  id   int primary key default 1 check (id = 1),
  salt text not null default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
);
alter table public.private_salt enable row level security;
revoke all on public.private_salt from anon, authenticated;
insert into public.private_salt (id) values (1) on conflict (id) do nothing;

insert into public.settings (key, value, label) values
  ('read_only', 0, '緊急停止（1 にすると、運営以外は感想・投稿・いいねなどを送れなくなる。0 で元に戻る）')
on conflict (key) do nothing;

-- ---------- 道具 ----------
-- いまのリクエストのネットワークの指紋（IPアドレス＋秘密＋日付の md5 の先頭16文字）。わからなければ null
create or replace function public.req_ip_key() returns text
language plpgsql stable security definer set search_path = public as $$
declare h json; ip text; s text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then return null;
  end;
  if h is null then return null; end if;
  ip := trim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-forwarded-for', h->>'x-real-ip', ''), ',', 1));
  if ip = '' then return null; end if;
  select salt into s from private_salt where id = 1;
  return left(md5(coalesce(s, '') || '|' || ip || '|' || ((now() at time zone 'Asia/Tokyo')::date)::text), 16);
end $$;

-- 1回数える。上限を超えたら too_many（その書き込みごと取り消される）
create or replace function public.rl_hit(p_bucket text, p_key text, p_max int, p_window_sec int default 3600) returns void
language plpgsql security definer set search_path = public as $$
declare w timestamptz; c int;
begin
  if p_key is null or p_key = '' or p_max is null or p_max <= 0 then return; end if;
  w := to_timestamp(floor(extract(epoch from now()) / p_window_sec) * p_window_sec);
  insert into rate_hits (bucket, k, win, n) values (p_bucket, p_key, w, 1)
  on conflict (bucket, k, win) do update set n = rate_hits.n + 1
  returning n into c;
  if c > p_max then raise exception 'too_many' using hint = 'rate_limited'; end if;
  if random() < 0.01 then delete from rate_hits where win < now() - interval '2 days'; end if;
end $$;

-- いまの呼び出しの役割（anon / authenticated / service_role / null=SQLエディタなど）
create or replace function public.req_role() returns text
language plpgsql stable as $$
declare r text;
begin
  r := nullif(current_setting('request.jwt.claim.role', true), '');
  if r is null then
    begin r := (nullif(current_setting('request.jwt.claims', true), '')::json)->>'role';
    exception when others then r := null; end;
  end if;
  return r;
end $$;

-- ---------- 書き込みの見張り（各テーブルの BEFORE トリガー） ----------
-- 上限（1時間）：TG_ARGV[0] = 同じネットワーク、TG_ARGV[1] = 同じアカウント・同じ端末
-- 学校やLT会場では大勢が同じネットワークになるので、ネットワークの上限は大きめにしてある
create or replace function public.write_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r text := req_role();
  ip_max int := coalesce(nullif(tg_argv[0], '')::int, 3000);
  one_max int := coalesce(nullif(tg_argv[1], '')::int, 600);
  cid text; uid uuid := auth.uid();
begin
  -- SQLエディタ・サーバー側（service_role）・運営はそのまま通す
  if r is null or r = 'service_role' or is_admin() then return coalesce(new, old); end if;
  if setting_int('read_only', 0) = 1 then raise exception 'read_only' using hint = 'site_paused'; end if;
  if tg_op = 'DELETE' then return old; end if;
  perform rl_hit(tg_table_name || ':ip', req_ip_key(), ip_max);
  if uid is not null then perform rl_hit(tg_table_name || ':u', uid::text, one_max); end if;
  cid := to_jsonb(new)->>'client_id';
  if cid is not null then perform rl_hit(tg_table_name || ':c', cid, one_max); end if;
  return new;
end $$;

do $$
declare t record;
begin
  for t in select * from (values
    -- テーブル          ネットワーク  1人
    ('feedback',          '300',  '30'),
    ('game_events',       '3000', '400'),
    ('play_sessions',     '1500', '150'),
    ('site_visits',       '500',  '30'),
    ('color_scores',      '500',  '60'),
    ('first_impressions', '800',  '80'),
    ('reports',           '60',   '15'),
    ('submissions',       '40',   '10'),
    ('profiles',          '200',  '30'),
    ('user_likes',        '2000', '300'),
    ('user_history',      '5000', '800'),
    ('follows',           '1000', '200'),
    ('pc_list',           '1000', '200'),
    ('result_quotes',     '300',  '60')
  ) as v(tbl, ipmax, onemax)
  loop
    if to_regclass('public.' || t.tbl) is null then continue; end if;
    execute format('drop trigger if exists zz_write_guard on public.%I', t.tbl);
    execute format('create trigger zz_write_guard before insert or update or delete on public.%I
                    for each row execute function public.write_guard(%L, %L)', t.tbl, t.ipmax, t.onemax);
  end loop;
end $$;

-- ---------- だれでも読める：いま止めているか ----------
create or replace function public.site_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('read_only', setting_int('read_only', 0) = 1);
$$;

revoke all on function public.req_ip_key(), public.rl_hit(text, text, int, int), public.write_guard() from public, anon, authenticated;
revoke all on function public.site_status() from public;
grant execute on function public.site_status() to anon, authenticated;
