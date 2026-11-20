-- 作者の質問の答えを「はい／いいえ」の2択にする準備（画面の変更はこのあと）
--   これまでの「◎ できた／○ だいたい／△ いまいち」も残す（前の答えを消さないため）
alter table public.feedback drop constraint if exists feedback_answer_check;
alter table public.feedback add constraint feedback_answer_check
  check (answer is null or answer in ('はい', 'いいえ', '◎ できた', '○ だいたい', '△ いまいち'));
select 'ok 021' as result;
