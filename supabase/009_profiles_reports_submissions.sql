-- プロフィール・アイコン画像・報告・作品の応募
--   profiles     … 作る人／遊ぶ人のプロフィール（名前・ID・ひとこと・アイコン・リンク）。公開してよい項目だけ持つ
--   avatars      … アイコン画像のバケット（自分のフォルダにだけ置ける）
--   reports      … 「報告する」で送られたもの（運営だけが見られる）
--   submissions  … サイトからの作品の応募（本人と運営だけが見られる）
-- テーブルには直接さわらせず、すべて関数（RPC）を通す。

-- ---------- 共通 ----------
create or replace function public.is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from banned_users where user_id = auth.uid());
$$;

create or replace function public.has_banned_word(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from banned_words w where length(w.word) > 0 and position(lower(w.word) in lower(coalesce(t, ''))) > 0);
$$;

-- ---------- プロフィール ----------
create table if not exists public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,20}$'),
  name text not null check (char_length(name) between 1 and 30),
  bio text not null default '' check (char_length(bio) <= 160),
  avatar_url text check (avatar_url is null or avatar_url ~ '^https://jwrzqaxuvmdbroemenng\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$'),
  links jsonb not null default '[]'::jsonb,
  video text check (video is null or (char_length(video) <= 200 and video ~ '^https://(www\.|m\.)?(youtube\.com|youtu\.be)/')),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

create or replace function public.profile_json(p public.profiles) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'handle', p.handle, 'name', p.name, 'bio', p.bio, 'avatar_url', p.avatar_url,
    'links', p.links, 'video', p.video,
    'games', coalesce((select jsonb_agg(o.game_slug order by o.created_at) from game_owners o where o.user_id = p.user_id), '[]'::jsonb));
$$;

-- だれでも：IDからプロフィールを見る（非表示のものは出さない）
create or replace function public.profile_get(h text) returns jsonb
language sql stable security definer set search_path = public as $$
  select profile_json(p) from profiles p where p.handle = lower(h) and not p.hidden;
$$;

-- だれでも：作品ごとの作者（アイコンと名前を作品の横に出すため）
create or replace function public.game_creators()
returns table (game_slug text, handle text, name text, avatar_url text)
language sql stable security definer set search_path = public as $$
  select distinct on (o.game_slug) o.game_slug, p.handle, p.name, p.avatar_url
  from game_owners o join profiles p on p.user_id = o.user_id
  where not p.hidden order by o.game_slug, o.created_at;
$$;

-- ログインした人：自分のプロフィール（まだ作っていなければ null）
create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select profile_json(p) || jsonb_build_object('hidden', p.hidden) from profiles p where p.user_id = auth.uid();
$$;

-- ログインした人：自分のプロフィールを作る・直す
create or replace function public.profile_save(p_handle text, p_name text, p_bio text, p_avatar_url text, p_links jsonb, p_video text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  h text := lower(btrim(coalesce(p_handle, '')));
  n text := btrim(coalesce(p_name, ''));
  b text := btrim(coalesce(p_bio, ''));
  v text := nullif(btrim(coalesce(p_video, '')), '');
  av text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  l jsonb := coalesce(p_links, '[]'::jsonb);
  item jsonb;
  res public.profiles;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if h !~ '^[a-z0-9_]{3,20}$' then raise exception 'bad_handle'; end if;
  if h in ('unei', 'admin', 'official', 'staff', 'support', 'testplaybu', 'testplay', 'tpb', 'null', 'undefined', 'me')
     and not is_admin() then raise exception 'handle_taken'; end if;
  if char_length(n) < 1 or char_length(n) > 30 then raise exception 'bad_name'; end if;
  if n ~ '運営|公式' and not is_admin() then raise exception 'bad_name'; end if;
  if char_length(b) > 160 then raise exception 'bad_bio'; end if;
  if has_banned_word(n) or has_banned_word(b) or has_banned_word(h) then raise exception 'banned_word'; end if;
  if jsonb_typeof(l) <> 'array' or jsonb_array_length(l) > 6 then raise exception 'bad_links'; end if;
  for item in select * from jsonb_array_elements(l) loop
    if jsonb_typeof(item) <> 'string' or char_length(item #>> '{}') > 200 or (item #>> '{}') !~ '^https://[^\s<>"'']+$' then
      raise exception 'bad_links';
    end if;
  end loop;
  if v is not null and (char_length(v) > 200 or v !~ '^https://(www\.|m\.)?(youtube\.com|youtu\.be)/') then raise exception 'bad_video'; end if;
  if av is not null and av !~ ('^https://jwrzqaxuvmdbroemenng\.supabase\.co/storage/v1/object/public/avatars/' || uid::text || '/[A-Za-z0-9._-]{1,80}$') then
    raise exception 'bad_avatar';
  end if;
  if exists (select 1 from profiles where handle = h and user_id <> uid) then raise exception 'handle_taken'; end if;
  insert into profiles (user_id, handle, name, bio, avatar_url, links, video)
    values (uid, h, n, b, av, l, v)
  on conflict (user_id) do update
    set handle = excluded.handle, name = excluded.name, bio = excluded.bio, avatar_url = excluded.avatar_url,
        links = excluded.links, video = excluded.video, updated_at = now()
  returning * into res;
  return profile_json(res);
end $$;

-- ログインした人：自分が送った感想
create or replace function public.my_feedback()
returns table (id uuid, created_at timestamptz, game_slug text, again text, reach text, good text[], bad text[], free text, hidden boolean, liked_by_dev boolean)
language sql stable security definer set search_path = public as $$
  select f.id, f.created_at, f.game_slug, f.again, f.reach, f.good, f.bad, f.free, f.hidden, f.liked_by_dev
  from feedback f where f.user_id = auth.uid() order by f.created_at desc limit 300;
$$;

-- 運営：プロフィールを隠す・戻す
create or replace function public.admin_profile_hide(h text, hide boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update profiles set hidden = hide where handle = lower(h);
  if not found then return 'そのIDのプロフィールはありません'; end if;
  return case when hide then 'プロフィールを非表示にしました' else 'プロフィールを表示に戻しました' end;
end $$;

create or replace function public.admin_profiles()
returns table (user_id uuid, handle text, name text, bio text, avatar_url text, hidden boolean, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select p.user_id, p.handle, p.name, p.bio, p.avatar_url, p.hidden, p.updated_at from profiles p order by p.updated_at desc limit 500;
end $$;

-- ---------- アイコン画像（Storage） ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 307200, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = true, file_size_limit = 307200, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];

drop policy if exists "avatars: 自分のフォルダを見られる" on storage.objects;
create policy "avatars: 自分のフォルダを見られる" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "avatars: 自分のフォルダに置ける" on storage.objects;
create policy "avatars: 自分のフォルダに置ける" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned());
drop policy if exists "avatars: 自分のフォルダを消せる" on storage.objects;
create policy "avatars: 自分のフォルダを消せる" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- 報告 ----------
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  kind text not null check (kind in ('game', 'profile')),
  target text not null check (target ~ '^[a-z0-9_-]{1,40}$'),
  reason text not null check (reason in ('broken', 'bad_content', 'rating', 'copy', 'spam', 'other')),
  detail text not null default '' check (char_length(detail) <= 400),
  client_id text not null check (length(client_id) between 8 and 64),
  user_id uuid references auth.users (id) on delete set null,
  done boolean not null default false
);
create index if not exists reports_created on public.reports (created_at desc);
alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;

-- だれでも：報告を送る（1つの端末から1日5件まで。同じ相手に同じ理由は1日1回）
create or replace function public.report_send(p_kind text, p_target text, p_reason text, p_detail text, p_client text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_client is null or length(p_client) < 8 or length(p_client) > 64 then raise exception 'bad_client'; end if;
  if exists (select 1 from banned_clients where client_id = p_client) or is_banned() then raise exception 'banned'; end if;
  if (select count(*) from reports where client_id = p_client and created_at > now() - interval '1 day') >= 5 then raise exception 'too_many'; end if;
  if exists (select 1 from reports where client_id = p_client and kind = p_kind and target = p_target and reason = p_reason
             and created_at > now() - interval '1 day') then
    return 'ok';
  end if;
  insert into reports (kind, target, reason, detail, client_id, user_id)
    values (p_kind, p_target, p_reason, left(btrim(coalesce(p_detail, '')), 400), p_client, auth.uid());
  return 'ok';
end $$;

create or replace function public.admin_reports()
returns table (id uuid, created_at timestamptz, kind text, target text, reason text, detail text, client_id text, by_name text, done boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select r.id, r.created_at, r.kind, r.target, r.reason, r.detail, r.client_id,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text, r.done
    from reports r left join auth.users u on u.id = r.user_id
    order by r.done, r.created_at desc limit 500;
end $$;

create or replace function public.admin_report_done(rid uuid, val boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update reports set done = val where id = rid;
  return case when val then '対応済みにしました' else '未対応に戻しました' end;
end $$;

-- ---------- 作品の応募 ----------
create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null default 'new' check (kind in ('new', 'edit')),
  game_slug text check (game_slug is null or game_slug ~ '^[a-z0-9-]{1,40}$'),
  data jsonb not null,
  status text not null default 'new' check (status in ('new', 'ok', 'ng')),
  admin_note text not null default ''
);
create index if not exists submissions_user on public.submissions (user_id, created_at desc);
alter table public.submissions enable row level security;
revoke all on public.submissions from anon, authenticated;

-- ログインした人：作品を応募する／載っている作品の直しをたのむ
-- data は {title, play_url, oneliner, platform, check, question, minutes, genre, stage, rating, controls, image_url, note}
create or replace function public.submission_send(p_kind text, p_slug text, p_data jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d jsonb := coalesce(p_data, '{}'::jsonb);
  k text; val text; clean jsonb := '{}'::jsonb;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if p_kind not in ('new', 'edit') then raise exception 'bad_kind'; end if;
  if p_kind = 'edit' and not can_see_game(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  if (select count(*) from submissions where user_id = uid and status = 'new') >= 5 then raise exception 'too_many'; end if;
  if jsonb_typeof(d) <> 'object' then raise exception 'bad_data'; end if;
  foreach k in array array['title', 'play_url', 'oneliner', 'platform', 'check', 'question', 'minutes', 'genre', 'stage', 'rating', 'controls', 'image_url', 'note'] loop
    if jsonb_typeof(d -> k) = 'string' then
      val := btrim(d ->> k);
      if char_length(val) > 400 then raise exception 'too_long'; end if;
      if val <> '' then clean := clean || jsonb_build_object(k, val); end if;
    end if;
  end loop;
  if p_kind = 'new' then
    if coalesce(clean ->> 'title', '') = '' or coalesce(clean ->> 'oneliner', '') = '' then raise exception 'need_title'; end if;
    if coalesce(clean ->> 'play_url', '') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url'; end if;
  else
    if coalesce(clean ->> 'note', '') = '' then raise exception 'need_note'; end if;
  end if;
  if clean ? 'image_url' and (clean ->> 'image_url') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url'; end if;
  if has_banned_word(clean::text) then raise exception 'banned_word'; end if;
  insert into submissions (user_id, kind, game_slug, data) values (uid, p_kind, case when p_kind = 'edit' then p_slug end, clean);
  return 'ok';
end $$;

create or replace function public.my_submissions()
returns table (id uuid, created_at timestamptz, kind text, game_slug text, data jsonb, status text, admin_note text)
language sql stable security definer set search_path = public as $$
  select s.id, s.created_at, s.kind, s.game_slug, s.data, s.status, s.admin_note
  from submissions s where s.user_id = auth.uid() order by s.created_at desc limit 50;
$$;

create or replace function public.admin_submissions()
returns table (id uuid, created_at timestamptz, user_id uuid, by_name text, by_email text, handle text, kind text, game_slug text, data jsonb, status text, admin_note text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select s.id, s.created_at, s.user_id,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text,
           u.email::text, p.handle, s.kind, s.game_slug, s.data, s.status, s.admin_note
    from submissions s join auth.users u on u.id = s.user_id left join profiles p on p.user_id = s.user_id
    order by (s.status = 'new') desc, s.created_at desc limit 300;
end $$;

create or replace function public.admin_submission_set(sid uuid, st text, note text default '') returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if st not in ('new', 'ok', 'ng') then raise exception 'bad_status'; end if;
  update submissions set status = st, admin_note = left(coalesce(note, ''), 400) where id = sid;
  return case st when 'ok' then '「載せた」にしました' when 'ng' then '「見送り」にしました' else '「確認中」に戻しました' end;
end $$;

-- ---------- 権限 ----------
revoke all on function
  public.is_banned(), public.has_banned_word(text), public.profile_json(public.profiles),
  public.profile_get(text), public.game_creators(), public.my_profile(),
  public.profile_save(text, text, text, text, jsonb, text), public.my_feedback(),
  public.admin_profile_hide(text, boolean), public.admin_profiles(),
  public.report_send(text, text, text, text, text), public.admin_reports(), public.admin_report_done(uuid, boolean),
  public.submission_send(text, text, jsonb), public.my_submissions(), public.admin_submissions(),
  public.admin_submission_set(uuid, text, text)
  from public, anon, authenticated;

grant execute on function public.profile_get(text), public.game_creators(), public.report_send(text, text, text, text, text)
  to anon, authenticated;
grant execute on function public.is_banned() to authenticated;
grant execute on function
  public.my_profile(), public.profile_save(text, text, text, text, jsonb, text), public.my_feedback(),
  public.admin_profile_hide(text, boolean), public.admin_profiles(),
  public.admin_reports(), public.admin_report_done(uuid, boolean),
  public.submission_send(text, text, jsonb), public.my_submissions(), public.admin_submissions(),
  public.admin_submission_set(uuid, text, text)
  to authenticated;

select 'ok 009' as result;
