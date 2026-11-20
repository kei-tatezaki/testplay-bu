-- 応募の動画・画像の上限を上げる（014 の続き）
--   作者がスマホで撮ったまま送れるように、動画は50MB・60秒まで（長さは画面側で確かめる）、iPhone の mov も受け付ける
--   サイトに出す版（2MB以下・8〜15秒・音なし）は、運営が scripts/fetch_submission_media.py で作る
--   バケットの上限は種類を問わず50MB（画像の10MBは画面側で確かめる）。無料プランの1ファイル上限も50MB
--   置きっぱなしを防ぐため、1人が置けるのは5個まで（載せた・見送ったら運営が消す）
update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = array['video/mp4', 'video/webm', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp']
 where id = 'submission-media';

drop policy if exists "submission-media: 自分のフォルダに置ける" on storage.objects;
create policy "submission-media: 自分のフォルダに置ける" on storage.objects for insert to authenticated
  with check (bucket_id = 'submission-media' and (storage.foldername(name))[1] = auth.uid()::text and not public.is_banned()
              and (select count(*) from storage.objects o where o.bucket_id = 'submission-media' and (storage.foldername(o.name))[1] = auth.uid()::text) < 5);

select id, file_size_limit, allowed_mime_types from storage.buckets where id = 'submission-media';
