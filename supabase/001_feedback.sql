-- テストプレイ部：感想を保存するテーブル（LTまでの版）
-- ログインなしで誰でも感想を書ける。読むのは誰でも。消す・直すのは運営だけ（ダッシュボードから）。

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  again text not null check (again in ('すごく遊びたい','ちょっと遊びたい','もういいかな')),
  reach text not null check (reach in ('最後まで','途中でやめた')),
  stop_at text check (char_length(stop_at) <= 60),
  good text[] not null default '{}' check (cardinality(good) <= 6),
  bad text[] not null default '{}' check (cardinality(bad) <= 6),
  answer text check (answer in ('◎ できた','○ だいたい','△ いまいち')),
  free text not null default '' check (char_length(free) <= 400),
  is_dev boolean not null default false,
  client_id text not null check (char_length(client_id) between 8 and 64),
  hidden boolean not null default false,
  liked_by_dev boolean not null default false,
  created_at timestamptz not null default now(),
  -- 開発者は一言を40文字以上
  constraint dev_min_length check (not is_dev or char_length(free) >= 40)
);

-- 同じブラウザから同じ作品への感想は1件まで（書き直しは運営に相談）
create unique index if not exists feedback_one_per_client on public.feedback (game_slug, client_id);
create index if not exists feedback_game_created on public.feedback (game_slug, created_at desc);

-- 禁句：運営が後から足せるようにテーブルで持つ
create table if not exists public.banned_words (word text primary key);
insert into public.banned_words (word) values
  ('死ね'),('しね'),('殺す'),('ころす'),('消えろ'),('きえろ'),('ゴミ'),('カス'),('クズ'),
  ('きもい'),('キモい'),('キモイ'),('うざい'),('ウザい'),('才能ない'),('才能がない'),('やめちまえ'),('下手くそ'),('へたくそ')
on conflict do nothing;

create or replace function public.reject_banned_words() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text; body text;
begin
  body := coalesce(new.free,'') || ' ' || coalesce(new.stop_at,'');
  for w in select word from public.banned_words loop
    if position(w in body) > 0 then
      raise exception 'banned_word' using errcode = 'P0001', hint = 'この言葉は使えません';
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists feedback_banned on public.feedback;
create trigger feedback_banned before insert or update on public.feedback
  for each row execute function public.reject_banned_words();

-- 行レベルのルール
alter table public.feedback enable row level security;
alter table public.banned_words enable row level security;

drop policy if exists "誰でも表示中の感想を読める" on public.feedback;
create policy "誰でも表示中の感想を読める" on public.feedback
  for select to anon, authenticated using (hidden = false);

drop policy if exists "誰でも感想を書ける" on public.feedback;
create policy "誰でも感想を書ける" on public.feedback
  for insert to anon, authenticated with check (hidden = false and liked_by_dev = false);

-- APIから触れる範囲（読む・書くだけ。更新と削除はできない）
grant usage on schema public to anon, authenticated;
grant select, insert on public.feedback to anon, authenticated;
revoke update, delete on public.feedback from anon, authenticated;
revoke all on public.banned_words from anon, authenticated;

-- 作品ごとの集計（作品ページとフィードで使う）
create or replace view public.feedback_stats with (security_invoker = true) as
  select game_slug,
         count(*) as total,
         count(*) filter (where again = 'すごく遊びたい') as again_much,
         count(*) filter (where reach = '最後まで') as reached_end
  from public.feedback where hidden = false group by game_slug;
grant select on public.feedback_stats to anon, authenticated;
