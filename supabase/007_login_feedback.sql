-- 感想はログインした人だけが送れる（遊ぶ・👍・🤔はログインなしでOKのまま）
-- BANは端末だけでなくアカウントでもかける

alter table public.feedback add column if not exists user_id uuid references auth.users (id) on delete set null;
alter table public.feedback alter column user_id set default auth.uid();
create unique index if not exists feedback_one_per_user on public.feedback (game_slug, user_id) where user_id is not null;

-- 今までの「誰でも送れる」ルールを外して、ログインした人だけにする
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'feedback' and cmd = 'INSERT' loop
    execute format('drop policy %I on public.feedback', p.policyname);
  end loop;
end $$;
create policy "ログインした人だけ感想を送れる" on public.feedback for insert to authenticated
  with check (hidden = false and liked_by_dev = false and user_id = auth.uid());
revoke insert on public.feedback from anon;
grant insert on public.feedback to authenticated;

-- アカウントのBAN
create table if not exists public.banned_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text,
  created_at timestamptz not null default now()
);
alter table public.banned_users enable row level security;
revoke all on public.banned_users from anon, authenticated;

create or replace function public.reject_banned_users() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is not null and exists (select 1 from banned_users where user_id = new.user_id) then
    raise exception 'banned' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists feedback_reject_banned_users on public.feedback;
create trigger feedback_reject_banned_users before insert on public.feedback
  for each row execute function public.reject_banned_users();

-- BANは端末とアカウントの両方にかけて、どちらの感想も非表示にする
create or replace function public.mod_ban_by_feedback(fid uuid, why text default null) returns text
language plpgsql security definer set search_path = public as $$
declare cid text; uid uuid; n int;
begin
  select client_id, user_id into cid, uid from feedback where id = fid;
  if cid is null then return 'その感想が見つかりません'; end if;
  insert into banned_clients (client_id, reason) values (cid, why)
    on conflict (client_id) do update set reason = excluded.reason;
  if uid is not null then
    insert into banned_users (user_id, reason) values (uid, why)
      on conflict (user_id) do update set reason = excluded.reason;
  end if;
  update feedback set hidden = true where client_id = cid or (uid is not null and user_id = uid);
  get diagnostics n = row_count;
  return 'BANしました（感想 ' || n || ' 件を非表示）';
end $$;
revoke all on function public.mod_ban_by_feedback(uuid, text) from public, anon, authenticated;

-- 管理ページ：感想の一覧に「書いた人の名前」を足す
drop function if exists public.admin_feedback(int);
create function public.admin_feedback(lim int default 200)
returns table (
  id uuid, created_at timestamptz, game_slug text, is_dev boolean, again text, reach text,
  stop_at text, good text[], bad text[], answer text, free text, hidden boolean,
  client_id text, author text, by_same_client bigint, banned boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select f.id, f.created_at, f.game_slug, f.is_dev, f.again, f.reach, f.stop_at, f.good, f.bad, f.answer, f.free, f.hidden,
           f.client_id,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1), '（ログインなし）')::text,
           (select count(*) from feedback x where x.client_id = f.client_id or (f.user_id is not null and x.user_id = f.user_id)),
           exists (select 1 from banned_clients b where b.client_id = f.client_id)
             or exists (select 1 from banned_users b where b.user_id = f.user_id)
    from feedback f left join auth.users u on u.id = f.user_id
    order by f.created_at desc
    limit greatest(1, least(coalesce(lim, 200), 1000));
end $$;

-- 管理ページ：BAN一覧（端末とアカウント）
drop function if exists public.admin_bans();
create function public.admin_bans()
returns table (kind text, ident text, label text, reason text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select 'アカウント'::text, b.user_id::text,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text,
           b.reason, b.created_at
    from banned_users b left join auth.users u on u.id = b.user_id
    union all
    select '端末'::text, c.client_id, left(c.client_id, 8) || '…', c.reason, c.created_at from banned_clients c
    order by 5 desc;
end $$;

drop function if exists public.admin_unban(text);
create function public.admin_unban(ident text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  delete from banned_clients where client_id = ident;
  delete from banned_users where user_id::text = ident;
  return 'BANを解きました（非表示にした感想は、必要なら1件ずつ戻してください）';
end $$;

revoke all on function public.admin_feedback(int), public.admin_bans(), public.admin_unban(text) from public, anon;
grant execute on function public.admin_feedback(int), public.admin_bans(), public.admin_unban(text) to authenticated;
