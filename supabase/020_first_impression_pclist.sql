-- 020：第一印象・「PCで遊ぶ」リスト・応募の容量の目安（size_mb）
--   first_impressions … ショートの動画を見て「遊んでみたい？」を3段階（＋100字までのひとこと）で送る。遊んでいなくても送れる。
--                       未ログインでも送れる（端末の client_id）。同じ人（ログイン中は user_id、そうでなければ client_id）が同じ作品に送れるのは1日1回で、
--                       2回目は上書き。BAN（banned_clients／banned_users）と禁止ワードは断る。ポイント・ミッションには関係しない。
--                       表には直接さわらせず、送るのは first_impression_send() だけ。
--     level: 3 = 遊びたい ／ 2 = 少し気になる ／ 1 = 今はいいかな
--     first_impression_public(slug)  … だれでも：3段階の件数と、最近のひとこと（作品ページ用。5件たまるまでは件数だけ）
--     dev_first_impressions(slug)    … 作者（と運営）：自分の作品だけ。件数と最近のひとこと
--     admin_first_impressions(days)  … 運営：作品ごとの件数（管理ページの「作品の数字」に足す。game_stats の形は変えない）
--     admin_first_impression_hide(id, hidden) … 運営：ひとことを隠す
--   pc_list           … スマホで「PCで遊ぶ」に入れた作品（本人だけ見られる・入れる・消せる。BAN の人は入れられない。1人200本まで）
--     pclist_import(slugs) … 未ログインのとき端末に貯めたものを、ログインしたとき引き継ぐ（018 の import_local と同じ流れ。200本まで、重複は無視）
--   submission_send   … 016 のものを置きかえる。許可キーに size_mb（容量の目安・MB、数字だけ）・fb_style（gentle／honest／both）・goal（60字まで）を足しただけ。既存の確かめは同じ。

-- ---------- 第一印象 ----------
create table if not exists public.first_impressions (
  id uuid primary key default gen_random_uuid(),
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  user_id uuid default auth.uid() references auth.users (id) on delete cascade,
  client_id text not null check (char_length(client_id) between 8 and 64),
  level smallint not null check (level between 1 and 3),
  note text check (note is null or char_length(note) <= 100),
  hidden boolean not null default false,
  day date not null default ((now() at time zone 'Asia/Tokyo')::date),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists first_impressions_once_client on public.first_impressions (game_slug, client_id, day);
create unique index if not exists first_impressions_once_user on public.first_impressions (game_slug, user_id, day) where user_id is not null;
create index if not exists first_impressions_game on public.first_impressions (game_slug, created_at desc);
alter table public.first_impressions enable row level security;
revoke all on public.first_impressions from anon, authenticated;

-- 送る（未ログインでもよい）。返すのは {ok:true, updated:同じ日の上書きか}
--   エラー：bad_slug／bad_level／bad_client／too_long／banned／banned_word／too_many（1端末あたり1日40件まで）
create or replace function public.first_impression_send(p_slug text, p_client text, p_level int, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  today date := (now() at time zone 'Asia/Tokyo')::date;
  rid uuid; n int;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  if p_level is null or p_level not between 1 and 3 then raise exception 'bad_level'; end if;
  if p_client is null or char_length(p_client) not between 8 and 64 then raise exception 'bad_client'; end if;
  if v_note is not null and char_length(v_note) > 100 then raise exception 'too_long'; end if;
  if exists (select 1 from banned_clients where client_id = p_client) then raise exception 'banned'; end if;
  if uid is not null and is_banned() then raise exception 'banned'; end if;
  if v_note is not null and has_banned_word(v_note) then raise exception 'banned_word'; end if;
  perform pg_advisory_xact_lock(hashtext('fi:' || coalesce(uid::text, p_client)));
  select id into rid from first_impressions
    where game_slug = p_slug and day = today and ((uid is not null and user_id = uid) or client_id = p_client) limit 1;
  if rid is null then
    select count(*) into n from first_impressions where day = today and ((uid is not null and user_id = uid) or client_id = p_client);
    if n >= 40 then raise exception 'too_many'; end if;
    insert into first_impressions (game_slug, user_id, client_id, level, note) values (p_slug, uid, p_client, p_level, v_note);
    return jsonb_build_object('ok', true, 'updated', false);
  end if;
  update first_impressions set level = p_level, note = v_note, updated_at = now(), user_id = coalesce(user_id, uid)
    where id = rid;
  return jsonb_build_object('ok', true, 'updated', true);
end $$;

-- 3段階の件数（hidden は数えない。ひとことの隠しは件数に関係しない）と、最近のひとこと
create or replace function public.fi_summary(p_slug text, p_notes int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'want',  count(*) filter (where level = 3),
    'maybe', count(*) filter (where level = 2),
    'no',    count(*) filter (where level = 1),
    'total', count(*),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('level', x.level, 'note', x.note, 'at', x.created_at) order by x.created_at desc)
                        from (select level, note, created_at from first_impressions
                              where game_slug = p_slug and not hidden and note is not null and note <> ''
                              order by created_at desc limit greatest(0, p_notes)) x), '[]'::jsonb))
  from first_impressions where game_slug = p_slug;
$$;

create or replace function public.first_impression_public(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare j jsonb;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  j := fi_summary(p_slug, 5);
  -- 5件たまるまでは、ひとことは出さない（少ない人数だと、だれの言葉か想像がついてしまうため）
  if (j ->> 'total')::int < 5 then j := j || jsonb_build_object('recent', '[]'::jsonb); end if;
  return j;
end $$;

create or replace function public.dev_first_impressions(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_game(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  return fi_summary(p_slug, 20);
end $$;

create or replace function public.admin_first_impressions(p_days int default 30)
returns table (game_slug text, want bigint, maybe bigint, no bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  return query
    select f.game_slug, count(*) filter (where f.level = 3), count(*) filter (where f.level = 2), count(*) filter (where f.level = 1)
    from first_impressions f
    where f.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 3650)))
    group by f.game_slug order by 2 desc, 1;
end $$;

create or replace function public.admin_first_impression_hide(p_id uuid, p_hidden boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  update first_impressions set hidden = coalesce(p_hidden, true) where id = p_id;
end $$;

-- ---------- PCで遊ぶリスト ----------
create table if not exists public.pc_list (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, game_slug)
);
create index if not exists pc_list_recent on public.pc_list (user_id, created_at desc);
alter table public.pc_list enable row level security;
revoke all on public.pc_list from anon, authenticated;
grant select, insert, delete on public.pc_list to authenticated;
drop policy if exists "pc_list: 本人だけ見られる" on public.pc_list;
create policy "pc_list: 本人だけ見られる" on public.pc_list for select to authenticated using (user_id = auth.uid());
drop policy if exists "pc_list: 本人だけ入れられる" on public.pc_list;
create policy "pc_list: 本人だけ入れられる" on public.pc_list for insert to authenticated with check (user_id = auth.uid() and not public.is_banned());
drop policy if exists "pc_list: 本人だけ消せる" on public.pc_list;
create policy "pc_list: 本人だけ消せる" on public.pc_list for delete to authenticated using (user_id = auth.uid());

-- 1人200本まで（超えるなら入れずに 'pc_list_full'）
create or replace function public.pc_list_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('pcl:' || new.user_id::text));
  if (select count(*) from pc_list where user_id = new.user_id) >= 200 then raise exception 'pc_list_full'; end if;
  return new;
end $$;
drop trigger if exists pc_list_limit on public.pc_list;
create trigger pc_list_limit before insert on public.pc_list for each row execute function public.pc_list_limit();

-- 端末に貯めた分の引き継ぎ（p_slugs は新しく入れたい順ではなく、端末に入れた順。200本まで。重複・形のちがうものは無視、枠がいっぱいなら残りは捨てる）
create or replace function public.pclist_import(p_slugs text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s text; added int := 0; r int; total int;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  perform pg_advisory_xact_lock(hashtext('pcl:' || uid::text));
  if p_slugs is not null then
    foreach s in array p_slugs[1:200] loop
      exit when (select count(*) from pc_list where user_id = uid) >= 200;
      if s is not null and s ~ '^[a-z0-9-]{1,40}$' then
        insert into pc_list (user_id, game_slug) values (uid, s) on conflict do nothing;
        get diagnostics r = row_count; added := added + r;
      end if;
    end loop;
  end if;
  select count(*) into total from pc_list where user_id = uid;
  return jsonb_build_object('added', added, 'total', total);
end $$;

-- ---------- 応募（016 の submission_send を置きかえる。size_mb を足しただけ） ----------
create or replace function public.submission_send(p_kind text, p_slug text, p_data jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d jsonb := coalesce(p_data, '{}'::jsonb);
  k text; val text; clean jsonb := '{}'::jsonb;
  cost int := setting_int('submit_cost', 30);
  sid uuid;
  use_free boolean := false;
  u text; host text; path text;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if p_kind not in ('new', 'edit') then raise exception 'bad_kind'; end if;
  if p_kind = 'edit' and not can_see_game(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  if (select count(*) from submissions where user_id = uid and status = 'new') >= 5 then raise exception 'too_many'; end if;
  if jsonb_typeof(d) <> 'object' then raise exception 'bad_data'; end if;
  -- size_mb は数字でも文字でも受ける（文字にそろえる）
  if jsonb_typeof(d -> 'size_mb') = 'number' then d := jsonb_set(d, '{size_mb}', to_jsonb(d ->> 'size_mb')); end if;
  foreach k in array array['title', 'play_url', 'oneliner', 'platform', 'check', 'question', 'minutes', 'genre', 'stage', 'rating', 'controls', 'image_url', 'note', 'media_kind', 'media_path',
                           'play_kind', 'size', 'os', 'embed_url', 'size_mb', 'fb_style', 'goal'] loop
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
  -- ショートに出すもの（014）：media_kind は video / image / auto、media_path は自分のフォルダのファイルだけ
  if clean ? 'media_kind' and (clean ->> 'media_kind') not in ('video', 'image', 'auto') then raise exception 'bad_media'; end if;
  if clean ? 'media_path' then
    if (clean ->> 'media_kind') not in ('video', 'image') then raise exception 'bad_media'; end if;
    if (clean ->> 'media_path') !~ ('^' || uid::text || '/[A-Za-z0-9._-]{1,80}$') then raise exception 'bad_media'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'submission-media' and o.name = clean ->> 'media_path') then raise exception 'media_missing'; end if;
  end if;
  -- 遊び方（016）：browser / download
  if clean ? 'play_kind' and (clean ->> 'play_kind') not in ('browser', 'download') then raise exception 'bad_play_kind'; end if;
  if clean ? 'size' and char_length(clean ->> 'size') > 20 then raise exception 'too_long'; end if;
  if clean ? 'os' and (clean ->> 'os') not in ('Windows', 'Mac', 'Windows・Mac') then raise exception 'bad_os'; end if;
  -- 容量の目安（020）：MB の数字だけ（0より大きく 100000 まで。小数は2けたまで）
  if clean ? 'size_mb' and ((clean ->> 'size_mb') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' or (clean ->> 'size_mb')::numeric <= 0 or (clean ->> 'size_mb')::numeric > 100000) then
    raise exception 'bad_size_mb';
  end if;
  -- 作者のお願い（020）：ほしい感想の言い方（gentle＝やさしめ／honest＝正直に／both＝両方）と、この作品で目指していること（60字まで）
  if clean ? 'fb_style' and (clean ->> 'fb_style') not in ('gentle', 'honest', 'both') then raise exception 'bad_fb_style'; end if;
  if clean ? 'goal' and char_length(clean ->> 'goal') > 60 then raise exception 'bad_goal'; end if;
  -- itch.io の埋め込み：https://itch.io/embed-upload/数字（あとに ?color=… などの安全な文字だけ）。ブラウザのときだけ
  if clean ? 'embed_url' then
    if (clean ->> 'embed_url') !~ '^https://itch\.io/embed-upload/[0-9]+([?#][A-Za-z0-9=&_.%#-]*)?$' then raise exception 'bad_embed'; end if;
    if coalesce(clean ->> 'play_kind', 'browser') <> 'browser' then raise exception 'bad_embed'; end if;
  end if;
  -- ダウンロード型：公開ページ（itch.io・Steam・BOOTH・GitHub）だけ。ファイルへの直リンクは不可。対応端末は pc
  if p_kind = 'new' and coalesce(clean ->> 'play_kind', 'browser') = 'download' then
    u := lower(clean ->> 'play_url');
    host := substring(u from '^https://([^/?#:@]+)(?:[/?#]|$)');
    path := regexp_replace(substring(u from '^https://[^/?#]+([^?#]*)'), '/+$', '');
    if host is null
       or not (host = 'itch.io' or host like '%.itch.io' or host = 'store.steampowered.com' or host = 'booth.pm' or host like '%.booth.pm'
               or host = 'github.com' or host = 'www.github.com' or host like '%.github.io') then raise exception 'bad_download_url'; end if;
    if coalesce(path, '') ~ '\.(exe|zip|7z|rar|msi|dmg|pkg|apk|ipa|app|tar|gz|tgz|bz2|xz|iso|jar|bat|sh|appimage|deb|rpm|cab)$' then raise exception 'bad_download_url'; end if;
    if host in ('github.com', 'www.github.com') and coalesce(path, '') ~ '/(releases/download|archive|raw)/' then raise exception 'bad_download_url'; end if;
    clean := clean || jsonb_build_object('platform', 'pc');
  end if;
  if has_banned_word(clean::text) then raise exception 'banned_word'; end if;
  -- 新しい応募だけ、ポイントが要る（直しの依頼・管理者は無料）。残高のチェックと引き算は同じトランザクションで
  -- 「最初の1本は投稿無料」：その人に、見送りになっていない新しい応募がまだ1本もなければ、ポイントを引かずに受け付ける。2本目からは cost（30pt）
  if p_kind = 'new' and not is_admin() then
    perform points_lock(uid);
    if not exists (select 1 from submissions where user_id = uid and kind = 'new' and status <> 'ng') then
      use_free := true;
    elsif cost > 0 and points_balance(uid) < cost then
      raise exception 'not_enough_points';
    end if;
  end if;
  insert into submissions (user_id, kind, game_slug, data, free_launch)
    values (uid, p_kind, case when p_kind = 'edit' then p_slug end, clean, use_free)
    returning id into sid;
  if p_kind = 'new' and not use_free and cost > 0 and not is_admin() then
    insert into points_ledger (user_id, delta, reason, ref) values (uid, -cost, 'submission', sid);
  end if;
  if use_free then return 'ok_free'; end if;
  return 'ok';
end $$;

-- ---------- 権限 ----------
revoke all on function
  public.first_impression_send(text, text, int, text), public.fi_summary(text, int), public.first_impression_public(text),
  public.dev_first_impressions(text), public.admin_first_impressions(int), public.admin_first_impression_hide(uuid, boolean),
  public.pc_list_limit(), public.pclist_import(text[]), public.submission_send(text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.first_impression_send(text, text, int, text), public.first_impression_public(text) to anon, authenticated;
grant execute on function public.dev_first_impressions(text), public.admin_first_impressions(int), public.admin_first_impression_hide(uuid, boolean),
  public.pclist_import(text[]), public.submission_send(text, text, jsonb) to authenticated;

select 'ok 020' as result;
