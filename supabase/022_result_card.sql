-- 022：テスト結果カード（result.html?g=<slug>）
--   public_result(slug)      … だれでも：作品ごとの公開してよい数字だけ（遊んだ人数・回数・遊んだ時間の真ん中・「もう一回遊びたい」の割合・
--                              作者の質問の「はい」の割合・第一印象の「遊びたい」の割合・感想の件数・いいね・集計期間・集計した日時・作者が選んだ感想）
--   result_quotes            … 作者が「カードに載せる」と選んだ感想（作品ごとに最大3件。位置 1〜3）。表には直接さわらせない
--   dev_result_quote_set / dev_result_quote_clear / dev_result_quotes … 作者（game_owners の本人）だけ
--   game_ratings             … 年齢制限の印（r15／r18）。R18 の作品は public_result が数字を返さない（blocked）。運営が admin_set_game_rating で入れる
--
-- 数え方
--   ・hidden の感想、BAN された端末・アカウントのもの、作者本人の感想、ポイントの記録で「lazy（同じ文字のくり返し）」とされた感想は数えない
--   ・遊んだ人数・いいね：game_events の play／like を端末ごとに1人。遊んだ回数・時間：play_sessions（BAN の端末は除く）
--   ・母数が5未満の項目は、割合を null で返す（画面は「まだ少ない」）。遊んだ時間の真ん中も、遊んだ回数が5未満なら null
--   ・日付は日本時間
--   ・選ばれた感想は、本文の先頭120字と日付だけ（名前・端末ID・アカウントは返さない）。表示中でなくなった（hidden など）感想は出ない

create table if not exists public.game_ratings (
  game_slug text primary key check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  rating text not null check (rating in ('r15', 'r18')),
  created_at timestamptz not null default now()
);
alter table public.game_ratings enable row level security;
revoke all on public.game_ratings from anon, authenticated;

create or replace function public.admin_set_game_rating(p_slug text, p_rating text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  if p_rating is null or p_rating = '' or p_rating = 'all' then
    delete from game_ratings where game_slug = p_slug;
  elsif p_rating in ('r15', 'r18') then
    insert into game_ratings (game_slug, rating) values (p_slug, p_rating) on conflict (game_slug) do update set rating = excluded.rating;
  else raise exception 'bad_rating'; end if;
end $$;

create table if not exists public.result_quotes (
  game_slug text not null check (game_slug ~ '^[a-z0-9-]{1,40}$'),
  feedback_id uuid not null references public.feedback (id) on delete cascade,
  position smallint not null check (position between 1 and 3),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (game_slug, position),
  unique (game_slug, feedback_id)
);
alter table public.result_quotes enable row level security;
revoke all on public.result_quotes from anon, authenticated;

-- 作者本人だけ（運営は作者として登録されていれば同じ。登録がなければ選べない）
create or replace function public.is_game_owner(p_slug text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from game_owners where game_slug = p_slug and user_id = auth.uid());
$$;

create or replace function public.dev_result_quote_set(p_slug text, p_feedback_id uuid, p_position int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  if not is_game_owner(p_slug) then raise exception 'not_allowed'; end if;
  if p_position is null or p_position not between 1 and 3 then raise exception 'bad_position'; end if;
  if not exists (select 1 from feedback f where f.id = p_feedback_id and f.game_slug = p_slug and f.hidden = false and btrim(f.free) <> ''
                   and not exists (select 1 from banned_clients b where b.client_id = f.client_id)
                   and (f.user_id is null or not exists (select 1 from banned_users bu where bu.user_id = f.user_id))) then
    raise exception 'bad_feedback';
  end if;
  perform pg_advisory_xact_lock(hashtext('rq:' || p_slug));
  delete from result_quotes where game_slug = p_slug and (feedback_id = p_feedback_id or position = p_position);
  insert into result_quotes (game_slug, feedback_id, position) values (p_slug, p_feedback_id, p_position);
end $$;

create or replace function public.dev_result_quote_clear(p_slug text, p_position int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  if not is_game_owner(p_slug) then raise exception 'not_allowed'; end if;
  delete from result_quotes where game_slug = p_slug and position = p_position;
end $$;

-- 作者の画面用：いま選んでいる感想（位置と感想のID）
create or replace function public.dev_result_quotes(p_slug text) returns table (pos int, feedback_id uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_game_owner(coalesce(p_slug, '')) then raise exception 'not_allowed'; end if;
  return query select q.position::int, q.feedback_id from result_quotes q where q.game_slug = p_slug order by q.position;
end $$;

-- ---------- 公開の集計 ----------
create or replace function public.public_result(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  min_n constant int := 5;
  v_plays int; v_sessions int; v_median numeric; v_likes int;
  v_fb int; v_again_n int; v_again_y int; v_ans_n int; v_ans_y int; v_fi_n int; v_fi_y int;
  v_first timestamptz; v_last timestamptz; v_quotes jsonb;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9-]{1,40}$' then raise exception 'bad_slug'; end if;
  if exists (select 1 from game_ratings where game_slug = p_slug and rating = 'r18') then
    return jsonb_build_object('slug', p_slug, 'blocked', true);
  end if;

  select count(distinct e.client_id) filter (where e.kind = 'play'), count(distinct e.client_id) filter (where e.kind = 'like')
    into v_plays, v_likes
    from game_events e
    where e.game_slug = p_slug and not exists (select 1 from banned_clients b where b.client_id = e.client_id);

  select count(*), percentile_cont(0.5) within group (order by s.seconds)
    into v_sessions, v_median
    from play_sessions s
    where s.game_slug = p_slug and not exists (select 1 from banned_clients b where b.client_id = s.client_id);

  with vf as (
    select f.* from feedback f
    where f.game_slug = p_slug and f.hidden = false
      and not exists (select 1 from banned_clients b where b.client_id = f.client_id)
      and (f.user_id is null or not exists (select 1 from banned_users bu where bu.user_id = f.user_id))
      and (f.user_id is null or not exists (select 1 from game_owners o where o.game_slug = f.game_slug and o.user_id = f.user_id))
      and not exists (select 1 from points_ledger pl where pl.ref = f.id and pl.reason = 'feedback' and pl.note = 'lazy')
  )
  select count(*), count(*) filter (where again in ('すごく遊びたい', 'ちょっと遊びたい')),
         count(*) filter (where answer in ('はい', 'いいえ')), count(*) filter (where answer = 'はい')
    into v_fb, v_again_y, v_ans_n, v_ans_y
    from vf;
  v_again_n := v_fb;

  select count(*), count(*) filter (where level = 3) into v_fi_n, v_fi_y
    from first_impressions i
    where i.game_slug = p_slug
      and not exists (select 1 from banned_clients b where b.client_id = i.client_id)
      and (i.user_id is null or not exists (select 1 from banned_users bu where bu.user_id = i.user_id));

  -- 集計期間：遊んだ記録・感想の最初と最後（日本時間の日付）
  select min(t), max(t) into v_first, v_last from (
    select created_at t from game_events e where e.game_slug = p_slug and e.kind = 'play' and not exists (select 1 from banned_clients b where b.client_id = e.client_id)
    union all select created_at from play_sessions ps where ps.game_slug = p_slug and not exists (select 1 from banned_clients b where b.client_id = ps.client_id)
    union all select f.created_at from feedback f where f.game_slug = p_slug and f.hidden = false
      and not exists (select 1 from banned_clients b where b.client_id = f.client_id)
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object('pos', q.position, 'text', left(f.free, 120), 'truncated', char_length(f.free) > 120,
                                               'at', (f.created_at at time zone 'Asia/Tokyo')::date) order by q.position), '[]'::jsonb)
    into v_quotes
    from result_quotes q join feedback f on f.id = q.feedback_id
    where q.game_slug = p_slug and f.hidden = false and btrim(f.free) <> ''
      and not exists (select 1 from banned_clients b where b.client_id = f.client_id)
      and (f.user_id is null or not exists (select 1 from banned_users bu where bu.user_id = f.user_id));

  return jsonb_build_object(
    'slug', p_slug, 'blocked', false, 'min_n', min_n,
    'plays', coalesce(v_plays, 0), 'sessions', coalesce(v_sessions, 0),
    'median_seconds', case when v_sessions >= min_n then round(v_median) end,
    'feedbacks', coalesce(v_fb, 0), 'likes', coalesce(v_likes, 0),
    'again_n', coalesce(v_again_n, 0), 'again_pct', case when v_again_n >= min_n then round(v_again_y * 100.0 / v_again_n) end,
    'answer_n', coalesce(v_ans_n, 0), 'answer_pct', case when v_ans_n >= min_n then round(v_ans_y * 100.0 / v_ans_n) end,
    'fi_n', coalesce(v_fi_n, 0), 'fi_pct', case when v_fi_n >= min_n then round(v_fi_y * 100.0 / v_fi_n) end,
    'first_day', (v_first at time zone 'Asia/Tokyo')::date, 'last_day', (v_last at time zone 'Asia/Tokyo')::date,
    'generated_at', now(), 'quotes', v_quotes);
end $$;

-- ---------- 権限 ----------
revoke all on function public.admin_set_game_rating(text, text), public.is_game_owner(text), public.dev_result_quote_set(text, uuid, int),
  public.dev_result_quote_clear(text, int), public.dev_result_quotes(text), public.public_result(text) from public, anon, authenticated;
grant execute on function public.public_result(text) to anon, authenticated;
grant execute on function public.admin_set_game_rating(text, text), public.dev_result_quote_set(text, uuid, int),
  public.dev_result_quote_clear(text, int), public.dev_result_quotes(text) to authenticated;

select 'ok 022' as result;
