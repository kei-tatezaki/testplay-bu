-- 感想の削除とBAN
--
-- 運営の使い方（Supabase の SQL Editor で実行する。サイトからは呼べない）
--   最近の感想を見る       select * from mod_recent limit 50;
--   感想を消す（非表示）    select mod_hide('感想のid');
--   消した感想を戻す        select mod_unhide('感想のid');
--   書いた人をBANする      select mod_ban_by_feedback('感想のid', '理由');
--                          → その人の感想を全部非表示にして、以後は感想も👍も送れなくする
--   BANを解く              select mod_unban('client_id');
--
-- いまはログインがないので、BANは「端末（ブラウザ）」単位。ログインを入れたらアカウント単位にする。

create table if not exists public.banned_clients (
  client_id text primary key,
  reason text,
  created_at timestamptz not null default now()
);
alter table public.banned_clients enable row level security;
revoke all on public.banned_clients from anon, authenticated;

-- BANされた端末からの送信を断る
create or replace function public.reject_banned_clients() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from banned_clients where client_id = new.client_id) then
    raise exception 'banned' using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists feedback_reject_banned on public.feedback;
create trigger feedback_reject_banned before insert on public.feedback
  for each row execute function public.reject_banned_clients();
drop trigger if exists game_events_reject_banned on public.game_events;
create trigger game_events_reject_banned before insert on public.game_events
  for each row execute function public.reject_banned_clients();
drop trigger if exists color_scores_reject_banned on public.color_scores;
create trigger color_scores_reject_banned before insert on public.color_scores
  for each row execute function public.reject_banned_clients();

-- 開発者のいい加減な感想を自動で断る
--   同じ文字が6回以上続く（「ああああああ」）、使っている文字の種類が少なすぎる（水増し）
create or replace function public.reject_lazy_dev() returns trigger
language plpgsql set search_path = public as $$
declare
  t text := regexp_replace(coalesce(new.free, ''), '\s', '', 'g');
  kinds int;
begin
  if new.is_dev then
    select count(distinct c) into kinds from regexp_split_to_table(t, '') as c;
    if kinds < 12 or t ~ '(.)\1{5,}' then
      raise exception 'lazy_dev' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists feedback_reject_lazy_dev on public.feedback;
create trigger feedback_reject_lazy_dev before insert on public.feedback
  for each row execute function public.reject_lazy_dev();

-- 運営用の一覧（外からは見えない）
create or replace view public.mod_recent as
  select f.id, f.created_at, f.game_slug, f.is_dev, f.again, f.reach, f.free, f.hidden, f.client_id,
         (select count(*) from feedback x where x.client_id = f.client_id) as by_same_client,
         exists (select 1 from banned_clients b where b.client_id = f.client_id) as banned
  from feedback f
  order by f.created_at desc;
revoke all on public.mod_recent from anon, authenticated;

-- 運営用の操作（外からは呼べない）
create or replace function public.mod_hide(fid uuid) returns text
language sql security definer set search_path = public as $$
  update feedback set hidden = true where id = fid returning '非表示にしました: ' || game_slug;
$$;
create or replace function public.mod_unhide(fid uuid) returns text
language sql security definer set search_path = public as $$
  update feedback set hidden = false where id = fid returning '表示に戻しました: ' || game_slug;
$$;
create or replace function public.mod_ban(cid text, why text default null) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into banned_clients (client_id, reason) values (cid, why)
    on conflict (client_id) do update set reason = excluded.reason;
  update feedback set hidden = true where client_id = cid;
  get diagnostics n = row_count;
  return 'BANしました（感想 ' || n || ' 件を非表示）';
end $$;
create or replace function public.mod_ban_by_feedback(fid uuid, why text default null) returns text
language plpgsql security definer set search_path = public as $$
declare cid text;
begin
  select client_id into cid from feedback where id = fid;
  if cid is null then return 'その感想が見つかりません'; end if;
  return mod_ban(cid, why);
end $$;
create or replace function public.mod_unban(cid text) returns text
language sql security definer set search_path = public as $$
  delete from banned_clients where client_id = cid returning 'BANを解きました';
$$;
revoke all on function public.mod_hide(uuid), public.mod_unhide(uuid), public.mod_ban(text, text),
  public.mod_ban_by_feedback(uuid, text), public.mod_unban(text) from public, anon, authenticated;
