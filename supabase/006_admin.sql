-- 管理ページ（admin.html）用
-- ログインした人のうち admins に入っている人だけが、感想の一覧・非表示・BANを使える。
-- 最初の1人は claim_first_admin() で自分を管理者にする（管理者が1人もいないときだけ使える）。

create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create or replace function public.claim_first_admin() returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from admins) then
    return case when is_admin() then 'already_admin' else 'taken' end;
  end if;
  insert into admins (user_id) values (auth.uid());
  return 'ok';
end $$;

-- 感想の一覧（新しい順）
create or replace function public.admin_feedback(lim int default 200)
returns table (
  id uuid, created_at timestamptz, game_slug text, is_dev boolean, again text, reach text,
  stop_at text, good text[], bad text[], answer text, free text, hidden boolean,
  client_id text, by_same_client bigint, banned boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select f.id, f.created_at, f.game_slug, f.is_dev, f.again, f.reach, f.stop_at, f.good, f.bad, f.answer, f.free, f.hidden,
           f.client_id,
           (select count(*) from feedback x where x.client_id = f.client_id),
           exists (select 1 from banned_clients b where b.client_id = f.client_id)
    from feedback f
    order by f.created_at desc
    limit greatest(1, least(coalesce(lim, 200), 1000));
end $$;

create or replace function public.admin_set_hidden(fid uuid, hide boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update feedback set hidden = hide where id = fid;
  return case when hide then '非表示にしました' else '表示に戻しました' end;
end $$;

create or replace function public.admin_ban(fid uuid, why text default null) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return mod_ban_by_feedback(fid, why);
end $$;

create or replace function public.admin_bans()
returns table (client_id text, reason text, created_at timestamptz, feedbacks bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select b.client_id, b.reason, b.created_at, (select count(*) from feedback f where f.client_id = b.client_id)
    from banned_clients b order by b.created_at desc;
end $$;

create or replace function public.admin_unban(cid text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  delete from banned_clients where client_id = cid;
  return 'BANを解きました（非表示にした感想は、必要なら1件ずつ戻してください）';
end $$;

revoke all on function public.is_admin(), public.claim_first_admin(), public.admin_feedback(int),
  public.admin_set_hidden(uuid, boolean), public.admin_ban(uuid, text), public.admin_bans(), public.admin_unban(text)
  from public, anon;
grant execute on function public.is_admin(), public.claim_first_admin(), public.admin_feedback(int),
  public.admin_set_hidden(uuid, boolean), public.admin_ban(uuid, text), public.admin_bans(), public.admin_unban(text)
  to authenticated;
