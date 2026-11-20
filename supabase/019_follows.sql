-- 019：フォロー（誰が誰をフォローしているか）
--   follows       … フォローの記録。本人（follower）だけが入れる・消せる。読めるのは、自分が関係する行だけ
--   follow_log    … フォロー操作の記録（1分に30回までの制限に使う。誰も直接は読めない）
--   follow_set / follow_counts / follow_state / followers_list / following_list / my_following_handles … 画面が使う関数
-- 注意：公開プロフィールの JSON には利用者の uuid を入れていない（profile_json）。
--       そのため、関数は uuid ではなく「ID（handle）」で相手を指す。
-- 制限：1人がフォローできるのは1000人まで（follow_limit）／1分に30回をこえる操作は too_fast
-- 数と一覧に出るのは「プロフィールがあって、非表示でも BAN でもない人」だけ（数と一覧が食いちがわないように、同じ条件にそろえる）

create table if not exists public.follows (
  follower uuid not null default auth.uid() references auth.users (id) on delete cascade,
  followee uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create index if not exists follows_followee on public.follows (followee, created_at desc);
alter table public.follows enable row level security;
revoke all on public.follows from anon, authenticated;
grant select, insert, delete on public.follows to authenticated;
drop policy if exists "follows: 自分が関係する行だけ見られる" on public.follows;
create policy "follows: 自分が関係する行だけ見られる" on public.follows for select to authenticated
  using (follower = auth.uid() or followee = auth.uid());
drop policy if exists "follows: 本人だけフォローできる" on public.follows;
create policy "follows: 本人だけフォローできる" on public.follows for insert to authenticated
  with check (follower = auth.uid() and not public.is_banned());
drop policy if exists "follows: 本人だけ解除できる" on public.follows;
create policy "follows: 本人だけ解除できる" on public.follows for delete to authenticated
  using (follower = auth.uid());

create table if not exists public.follow_log (
  id bigserial primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  at timestamptz not null default now()
);
create index if not exists follow_log_recent on public.follow_log (user_id, at desc);
alter table public.follow_log enable row level security;
revoke all on public.follow_log from anon, authenticated;

-- 入れる前：1000人まで・プロフィールがある人だけ（自分も）・1分に30回まで。入れる／消すの両方を数える
create or replace function public.follows_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int; fid uuid;
begin
  -- アカウント削除などで、利用者本人の操作ではないとき（auth.uid() が空）は何もしない
  if tg_op = 'DELETE' then fid := old.follower; else fid := new.follower; end if;
  if uid is null or uid <> fid then if tg_op = 'DELETE' then return old; else return new; end if; end if;
  perform pg_advisory_xact_lock(hashtextextended('follows:' || uid::text, 0));
  delete from follow_log where user_id = uid and at < now() - interval '1 hour';
  select count(*) into n from follow_log where user_id = uid and at > now() - interval '1 minute';
  if n >= 30 then raise exception 'too_fast'; end if;
  if tg_op = 'INSERT' then
    if (select count(*) from follows where follower = uid) >= 1000 then raise exception 'follow_limit'; end if;
    if not exists (select 1 from profiles where user_id = uid) then raise exception 'need_profile'; end if;
    if not exists (select 1 from profiles where user_id = new.followee and not hidden) then raise exception 'no_such_user'; end if;
  end if;
  insert into follow_log (user_id) values (uid);
  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists follows_guard_ins on public.follows;
create trigger follows_guard_ins before insert on public.follows for each row execute function public.follows_guard();
drop trigger if exists follows_guard_del on public.follows;
create trigger follows_guard_del before delete on public.follows for each row execute function public.follows_guard();

-- ---------- 画面が使う関数 ----------
-- だれでも：フォロー中・フォロワーの数
create or replace function public.follow_counts(p_handle text)
returns table (following bigint, followers bigint)
language sql stable security definer set search_path = public as $$
  with t as (select user_id from profiles where handle = lower(btrim(coalesce(p_handle, ''))) and not hidden)
  select
    (select count(*) from follows f join profiles q on q.user_id = f.followee and not q.hidden
       where f.follower = (select user_id from t) and not exists (select 1 from banned_users b where b.user_id = f.followee)),
    (select count(*) from follows f join profiles q on q.user_id = f.follower and not q.hidden
       where f.followee = (select user_id from t) and not exists (select 1 from banned_users b where b.user_id = f.follower))
  where exists (select 1 from t);
$$;

-- ログインした人：その人を自分がフォローしているか（ログインなしは false）
create or replace function public.follow_state(p_handle text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from follows f join profiles p on p.user_id = f.followee
    where f.follower = auth.uid() and p.handle = lower(btrim(coalesce(p_handle, ''))));
$$;

-- だれでも：フォロワーの一覧（新しい順）。出すのは公開してよい項目だけ
create or replace function public.followers_list(p_handle text, p_limit int default 50, p_offset int default 0)
returns table (handle text, name text, avatar_url text, bio text)
language sql stable security definer set search_path = public as $$
  select q.handle, q.name, q.avatar_url, q.bio
  from profiles t join follows f on f.followee = t.user_id join profiles q on q.user_id = f.follower
  where t.handle = lower(btrim(coalesce(p_handle, ''))) and not t.hidden and not q.hidden
    and not exists (select 1 from banned_users b where b.user_id = q.user_id)
  order by f.created_at desc, q.handle
  limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0));
$$;

-- だれでも：フォロー中の一覧（新しい順）
create or replace function public.following_list(p_handle text, p_limit int default 50, p_offset int default 0)
returns table (handle text, name text, avatar_url text, bio text)
language sql stable security definer set search_path = public as $$
  select q.handle, q.name, q.avatar_url, q.bio
  from profiles t join follows f on f.follower = t.user_id join profiles q on q.user_id = f.followee
  where t.handle = lower(btrim(coalesce(p_handle, ''))) and not t.hidden and not q.hidden
    and not exists (select 1 from banned_users b where b.user_id = q.user_id)
  order by f.created_at desc, q.handle
  limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0));
$$;

-- ログインした人：自分がフォローしている人のID（作品一覧の「フォロー中の作者」の絞り込み用。1000まで）
create or replace function public.my_following_handles() returns setof text
language sql stable security definer set search_path = public as $$
  select q.handle from follows f join profiles q on q.user_id = f.followee and not q.hidden
  where f.follower = auth.uid() order by f.created_at desc limit 1000;
$$;

-- ログインした人：フォローする／解除する。返すのは {following, followers}
-- エラー：not_logged_in／banned（BAN の人はフォローできない。解除はできる）／need_profile／no_such_user／self／follow_limit／too_fast
create or replace function public.follow_set(p_handle text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); tid uuid; h text := lower(btrim(coalesce(p_handle, '')));
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  select user_id into tid from profiles where handle = h and not hidden;
  if tid is null then raise exception 'no_such_user'; end if;
  if tid = uid then raise exception 'self'; end if;
  if coalesce(p_on, false) then
    if is_banned() then raise exception 'banned'; end if;
    if not exists (select 1 from follows where follower = uid and followee = tid) then
      insert into follows (follower, followee) values (uid, tid);
    end if;
  else
    delete from follows where follower = uid and followee = tid;
  end if;
  return jsonb_build_object('following', coalesce(p_on, false),
    'followers', (select c.followers from follow_counts(h) c));
end $$;

-- ---------- 権限 ----------
revoke all on function public.follows_guard(), public.follow_counts(text), public.follow_state(text),
  public.followers_list(text, int, int), public.following_list(text, int, int),
  public.my_following_handles(), public.follow_set(text, boolean) from public, anon, authenticated;
grant execute on function public.follow_counts(text), public.follow_state(text),
  public.followers_list(text, int, int), public.following_list(text, int, int) to anon, authenticated;
grant execute on function public.my_following_handles(), public.follow_set(text, boolean) to authenticated;
