-- 024 3Dモデルの応募と、AIが中を見た記録
--   ・応募に type = game / model。model は「用途」「目的」が必須で、ファイル（.glb / .vrm、50MBまで）か見られるページのURLが要る
--   ・バケット submission-media に model/gltf-binary を足す（置き場は今までどおり非公開・自分のフォルダ・5個まで）
--   ・model_reviews：運営が「AIで中を見る」をしたときの数字（ポリゴン数など）とAIの答え。運営だけが読める
--   ・admin_submission_note：状態は変えずに、作者へのコメント（1500字まで）だけ送る。作者はマイページで読める
-- 何度流しても同じ結果になる。

update storage.buckets
   set allowed_mime_types = array['video/mp4', 'video/webm', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp', 'model/gltf-binary']
 where id = 'submission-media';

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
                           'play_kind', 'size', 'os', 'embed_url', 'size_mb', 'fb_style', 'goal',
                           'type', 'model_use', 'model_target', 'model_purpose', 'model_check', 'model_tools', 'model_style', 'model_rig', 'model_anim', 'model_budget', 'model_hours', 'model_path', 'model_url'] loop
    if jsonb_typeof(d -> k) = 'string' then
      val := btrim(d ->> k);
      if char_length(val) > 400 then raise exception 'too_long'; end if;
      if val <> '' then clean := clean || jsonb_build_object(k, val); end if;
    end if;
  end loop;
  if clean ? 'type' and (clean ->> 'type') not in ('game', 'model') then raise exception 'bad_type'; end if;
  if p_kind = 'new' then
    if coalesce(clean ->> 'title', '') = '' or coalesce(clean ->> 'oneliner', '') = '' then raise exception 'need_title'; end if;
    if coalesce(clean ->> 'type', 'game') = 'model' then
      -- 3Dモデル（024）：用途と目的が必須。ファイル（.glb / .vrm）か、見られるページの URL のどちらかが要る
      if coalesce(clean ->> 'model_use', '') = '' or coalesce(clean ->> 'model_purpose', '') = '' then raise exception 'need_model_purpose'; end if;
      if not (clean ? 'model_path') and coalesce(clean ->> 'model_url', '') = '' then raise exception 'need_model_file'; end if;
      clean := clean - 'play_kind' - 'embed_url' - 'size' - 'os';
    elsif coalesce(clean ->> 'play_url', '') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url';
    end if;
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
  -- 3Dモデルの欄（024）
  if clean ? 'model_use' and (clean ->> 'model_use') not in ('game_char', 'game_prop', 'game_env', 'vrc_avatar', 'vtuber', 'portfolio', 'practice', 'other') then raise exception 'bad_model'; end if;
  if clean ? 'model_target' and (clean ->> 'model_target') not in ('sp', 'pc', 'vr', 'console', 'render', 'none') then raise exception 'bad_model'; end if;
  if clean ? 'model_rig' and (clean ->> 'model_rig') not in ('yes', 'no', 'planned') then raise exception 'bad_model'; end if;
  if clean ? 'model_anim' and (clean ->> 'model_anim') not in ('yes', 'no') then raise exception 'bad_model'; end if;
  if clean ? 'model_budget' and (clean ->> 'model_budget') !~ '^[0-9]{1,7}$' then raise exception 'bad_model'; end if;
  if char_length(coalesce(clean ->> 'model_purpose', '')) > 200 or char_length(coalesce(clean ->> 'model_check', '')) > 120
     or char_length(coalesce(clean ->> 'model_tools', '')) > 60 or char_length(coalesce(clean ->> 'model_style', '')) > 40
     or char_length(coalesce(clean ->> 'model_hours', '')) > 20 then raise exception 'too_long'; end if;
  if clean ? 'model_url' and (clean ->> 'model_url') !~ '^https://[^\s<>"'']+$' then raise exception 'bad_url'; end if;
  if clean ? 'model_path' then
    if (clean ->> 'model_path') !~ ('^' || uid::text || '/[A-Za-z0-9._-]{1,80}\.(glb|vrm)$') then raise exception 'bad_model'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'submission-media' and o.name = clean ->> 'model_path') then raise exception 'media_missing'; end if;
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

-- ---------- AIが中を見た記録 ----------
create table if not exists public.model_reviews (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions (id) on delete cascade,
  stats jsonb not null,
  ai jsonb,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists model_reviews_sub on public.model_reviews (submission_id, created_at desc);
alter table public.model_reviews enable row level security;
revoke all on public.model_reviews from anon, authenticated;

create or replace function public.admin_model_review_save(p_sid uuid, p_stats jsonb, p_ai jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if not exists (select 1 from submissions where id = p_sid) then raise exception 'not_found'; end if;
  if p_stats is null or jsonb_typeof(p_stats) <> 'object' or octet_length(p_stats::text) > 60000 then raise exception 'bad_stats'; end if;
  if p_ai is not null and (jsonb_typeof(p_ai) <> 'object' or octet_length(p_ai::text) > 30000) then raise exception 'bad_ai'; end if;
  insert into model_reviews (submission_id, stats, ai, created_by) values (p_sid, p_stats, p_ai, auth.uid()) returning id into rid;
  delete from model_reviews where submission_id = p_sid and id not in (select id from model_reviews where submission_id = p_sid order by created_at desc limit 5);
  return rid;
end $$;

create or replace function public.admin_model_review_latest(p_sid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return (select jsonb_build_object('id', r.id, 'stats', r.stats, 'ai', r.ai, 'created_at', r.created_at)
            from model_reviews r where r.submission_id = p_sid order by r.created_at desc limit 1);
end $$;

-- 状態は変えずに、作者へのコメントだけ送る（マイページの「運営から」に出る）
create or replace function public.admin_submission_note(p_sid uuid, p_note text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update submissions set admin_note = left(btrim(coalesce(p_note, '')), 1500) where id = p_sid;
  if not found then raise exception 'not_found'; end if;
  return '作者に送りました';
end $$;

revoke all on function public.admin_model_review_save(uuid, jsonb, jsonb), public.admin_model_review_latest(uuid), public.admin_submission_note(uuid, text) from public, anon;
grant execute on function public.admin_model_review_save(uuid, jsonb, jsonb), public.admin_model_review_latest(uuid), public.admin_submission_note(uuid, text) to authenticated;
