-- いろタッチ30 のスコアランキング
create table if not exists public.color_scores (
  id uuid primary key default gen_random_uuid(),
  mode text not null check (mode in ('ink','word')),
  name text not null check (char_length(name) between 1 and 12),
  score int not null check (score between 0 and 120),
  client_id text not null check (char_length(client_id) between 8 and 64),
  created_at timestamptz not null default now()
);
create index if not exists color_scores_rank on public.color_scores (mode, score desc, created_at);

create or replace function public.reject_banned_names() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text;
begin
  for w in select word from public.banned_words loop
    if position(w in new.name) > 0 then
      raise exception 'banned_word' using errcode = 'P0001', hint = 'この言葉は使えません';
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists color_scores_banned on public.color_scores;
create trigger color_scores_banned before insert on public.color_scores
  for each row execute function public.reject_banned_names();

alter table public.color_scores enable row level security;
drop policy if exists "read_scores" on public.color_scores;
create policy "read_scores" on public.color_scores for select to anon, authenticated using (true);
drop policy if exists "insert_scores" on public.color_scores;
create policy "insert_scores" on public.color_scores for insert to anon, authenticated with check (true);
grant select, insert on public.color_scores to anon, authenticated;
revoke update, delete on public.color_scores from anon, authenticated;
