-- 018：いいねした作品と、見た・遊んだ履歴（アカウントに保存）
--   user_likes    … いいねした作品（本人だけが読める・入れる・消せる。BAN の人は入れられない）
--   user_history  … 見た／遊んだ履歴（本人だけ。同じ作品の「見た」は30分以内なら重複を入れない。1人あたり新しい500件まで）
--   profiles.likes_public … いいねを公開するか（既定はオフ）。public_likes() が、オンの人のぶんだけ返す
--   import_local  … ログインしたとき、この端末に残っていた記録を引き継ぐ（いいね200・履歴200まで、未来の日時は除く）
-- 「存在する作品の slug だけ」は、作品の一覧がデータベースになく（games.json にだけある）判定できないため、
-- slug の形（小文字・数字・ハイフン 1〜40字）で確かめる。

-- ---------- いいね ----------
create table if not exists public.user_likes (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, game_slug)
);
create index if not exists user_likes_recent on public.user_likes (user_id, created_at desc);
alter table public.user_likes enable row level security;
revoke all on public.user_likes from anon, authenticated;
grant select, insert, delete on public.user_likes to authenticated;
drop policy if exists "likes: 本人だけ見られる" on public.user_likes;
create policy "likes: 本人だけ見られる" on public.user_likes for select to authenticated using (user_id = auth.uid());
drop policy if exists "likes: 本人だけ入れられる" on public.user_likes;
create policy "likes: 本人だけ入れられる" on public.user_likes for insert to authenticated with check (user_id = auth.uid() and not public.is_banned());
drop policy if exists "likes: 本人だけ消せる" on public.user_likes;
create policy "likes: 本人だけ消せる" on public.user_likes for delete to authenticated using (user_id = auth.uid());

-- ---------- 履歴 ----------
create table if not exists public.user_history (
  id bigserial primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  kind text not null check (kind in ('view', 'play')),
  seconds int check (seconds is null or seconds between 0 and 86400),
  created_at timestamptz not null default now()
);
create index if not exists user_history_recent on public.user_history (user_id, created_at desc, id desc);
create unique index if not exists user_history_once on public.user_history (user_id, game_slug, kind, created_at);
alter table public.user_history enable row level security;
revoke all on public.user_history from anon, authenticated;
grant select, insert, delete on public.user_history to authenticated;
grant usage on sequence public.user_history_id_seq to authenticated;
drop policy if exists "history: 本人だけ見られる" on public.user_history;
create policy "history: 本人だけ見られる" on public.user_history for select to authenticated using (user_id = auth.uid());
drop policy if exists "history: 本人だけ入れられる" on public.user_history;
create policy "history: 本人だけ入れられる" on public.user_history for insert to authenticated with check (user_id = auth.uid() and not public.is_banned());
drop policy if exists "history: 本人だけ消せる" on public.user_history;
create policy "history: 本人だけ消せる" on public.user_history for delete to authenticated using (user_id = auth.uid());

-- 同じ作品の「見た」は、前後30分以内にあれば入れない（エラーにはせず、静かに捨てる）
create or replace function public.user_history_dedupe() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'view' and exists (
    select 1 from user_history h
    where h.user_id = new.user_id and h.game_slug = new.game_slug and h.kind = 'view'
      and h.created_at between new.created_at - interval '30 minutes' and new.created_at + interval '30 minutes') then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists user_history_dedupe on public.user_history;
create trigger user_history_dedupe before insert on public.user_history
  for each row execute function public.user_history_dedupe();

-- 1人あたり新しい500件まで。超えた古い行は消す
create or replace function public.user_history_trim() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from user_history where id in (
    select id from user_history where user_id = new.user_id order by created_at desc, id desc offset 500);
  return null;
end $$;
drop trigger if exists user_history_trim on public.user_history;
create trigger user_history_trim after insert on public.user_history
  for each row execute function public.user_history_trim();

-- ---------- 公開の設定 ----------
alter table public.profiles add column if not exists likes_public boolean not null default false;

-- 自分のプロフィール（likes_public を足す。ほかは 009 のまま）
create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select profile_json(p) || jsonb_build_object('hidden', p.hidden, 'likes_public', p.likes_public) from profiles p where p.user_id = auth.uid();
$$;

-- ログインした人：いいねの公開をオン・オフにする（BAN の人はオフにだけできる）
create or replace function public.likes_public_set(p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  if coalesce(p_on, false) and is_banned() then raise exception 'banned'; end if;
  update profiles set likes_public = coalesce(p_on, false) where user_id = auth.uid();
  if not found then raise exception 'no_profile'; end if;
  return coalesce(p_on, false);
end $$;

-- だれでも：いいねを公開している人の、いいねした作品（新しい順）。非公開・非表示・BAN の人は空
create or replace function public.public_likes(p_handle text)
returns table (game_slug text, liked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select l.game_slug, l.created_at
  from profiles p join user_likes l on l.user_id = p.user_id
  where p.handle = lower(btrim(coalesce(p_handle, ''))) and p.likes_public and not p.hidden
    and not exists (select 1 from banned_users b where b.user_id = p.user_id)
  order by l.created_at desc limit 200;
$$;

-- ---------- 端末の記録の引き継ぎ ----------
-- p_likes: ['slug', …]（200まで）
-- p_history: [{"slug":"…","kind":"view"|"play","seconds":12,"at":1732100000000(ミリ秒) または "2026-11-20T10:00:00Z"}, …]（200まで）
-- 日時が未来（5分までの端末の時計のずれは許す）のものは入れない。同じ記録は無視。返すのは入れた件数
create or replace function public.import_local(p_likes text[], p_history jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); nl int := 0; nh int := 0; r int;
  s text; it jsonb; slug text; k text; sec int; ts timestamptz; raw text;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if p_likes is not null then
    foreach s in array p_likes[1:200] loop
      if s is not null and s ~ '^[a-z0-9-]{1,40}$' then
        insert into user_likes (user_id, game_slug) values (uid, s) on conflict do nothing;
        get diagnostics r = row_count; nl := nl + r;
      end if;
    end loop;
  end if;
  if p_history is not null and jsonb_typeof(p_history) = 'array' then
    for it in select value from jsonb_array_elements(p_history) limit 200 loop
      begin
        if jsonb_typeof(it) <> 'object' then continue; end if;
        slug := it ->> 'slug'; k := it ->> 'kind'; raw := it ->> 'at';
        if slug is null or slug !~ '^[a-z0-9-]{1,40}$' or k not in ('view', 'play') or raw is null then continue; end if;
        if jsonb_typeof(it -> 'at') = 'number' then ts := to_timestamp((raw::numeric) / 1000.0); else ts := raw::timestamptz; end if;
        if ts > now() + interval '5 minutes' or ts < now() - interval '3650 days' then continue; end if;
        if ts > now() then ts := now(); end if;
        sec := case when jsonb_typeof(it -> 'seconds') = 'number' then least(greatest((it ->> 'seconds')::numeric, 0), 86400)::int end;
        insert into user_history (user_id, game_slug, kind, seconds, created_at) values (uid, slug, k, sec, ts) on conflict do nothing;
        get diagnostics r = row_count; nh := nh + r;
      exception when others then continue;
      end;
    end loop;
  end if;
  return jsonb_build_object('likes', nl, 'history', nh);
end $$;

-- ---------- 権限 ----------
revoke all on function public.user_history_dedupe(), public.user_history_trim(),
  public.likes_public_set(boolean), public.public_likes(text), public.import_local(text[], jsonb) from public, anon, authenticated;
grant execute on function public.likes_public_set(boolean), public.import_local(text[], jsonb) to authenticated;
grant execute on function public.public_likes(text) to anon, authenticated;
