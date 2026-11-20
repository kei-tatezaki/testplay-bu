-- ショートに出す動画・画像を、作者が応募のときに選んで送れるようにする
--   submission-media … 非公開のバケット。2MBまで。動画（mp4 / webm）か画像（jpg / png / webp）
--     置ける・見られる・消せるのは、自分のフォルダ（<user id>/…）だけ。管理者はすべて見られる・消せる
--     載せると決めたら、運営がサイト（GitHub Pages の clips/ や og/）にコピーして、ここからは消す（Supabase の転送量を使わないため）
--   submissions.data に media_kind（video / image / auto）と media_path を足せるようにする

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submission-media', 'submission-media', false, 2097152,
        array['video/mp4', 'video/webm', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "submission-media: 自分のフォルダを見られる" on storage.objects;
create policy "submission-media: 自分のフォルダを見られる" on storage.objects for select to authenticated
  using (bucket_id = 'submission-media' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "submission-media: 自分のフォルダに置ける" on storage.objects;
create policy "submission-media: 自分のフォルダに置ける" on storage.objects for insert to authenticated
  with check (bucket_id = 'submission-media' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned()
              and (select count(*) from storage.objects o where o.bucket_id = 'submission-media' and (storage.foldername(o.name))[1] = auth.uid()::text) < 10);
drop policy if exists "submission-media: 自分のフォルダを消せる" on storage.objects;
create policy "submission-media: 自分のフォルダを消せる" on storage.objects for delete to authenticated
  using (bucket_id = 'submission-media' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- 応募（013 の submission_send を置きかえる。media_kind / media_path を足しただけ）。無料のときは 'ok_free'、ポイントを引いたときは 'ok'
create or replace function public.submission_send(p_kind text, p_slug text, p_data jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d jsonb := coalesce(p_data, '{}'::jsonb);
  k text; val text; clean jsonb := '{}'::jsonb;
  cost int := setting_int('submit_cost', 30);
  sid uuid;
  use_free boolean := false;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if is_banned() then raise exception 'banned'; end if;
  if p_kind not in ('new', 'edit') then raise exception 'bad_kind'; end if;
  if p_kind = 'edit' and not can_see_game(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  if (select count(*) from submissions where user_id = uid and status = 'new') >= 5 then raise exception 'too_many'; end if;
  if jsonb_typeof(d) <> 'object' then raise exception 'bad_data'; end if;
  foreach k in array array['title', 'play_url', 'oneliner', 'platform', 'check', 'question', 'minutes', 'genre', 'stage', 'rating', 'controls', 'image_url', 'note', 'media_kind', 'media_path'] loop
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
  if has_banned_word(clean::text) then raise exception 'banned_word'; end if;
  -- 新しい応募だけ、ポイントが要る（直しの依頼・管理者は無料）。残高のチェックと引き算は同じトランザクションで
  -- 「最初の1本は投稿無料」：その人に、見送りになっていない新しい応募がまだ1本もなければ、ポイントを引かずに受け付ける。2本目からは cost（30pt）
  --   見送りになった応募は数えないので、見送りになれば、次の応募がまた無料になる
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



revoke all on function public.submission_send(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.submission_send(text, text, jsonb) to authenticated;

select 'ok 014' as result;
