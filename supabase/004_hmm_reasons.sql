-- 🤔 に理由をつける
--   controls … 操作がわかりにくい
--   heavy    … 重い・動かない
--   fun      … おもしろさがわからなかった
--   genre    … 好みのジャンルじゃない（＝興味なし。作品の評価には入れない）
alter table public.game_events add column if not exists reason text;
alter table public.game_events drop constraint if exists game_events_reason_check;
alter table public.game_events add constraint game_events_reason_check check (
  reason is null or (kind = 'hmm' and reason in ('controls','heavy','fun','genre'))
);

-- 返す列が増えるので作り直す
drop function if exists public.game_stats(int);
create function public.game_stats(since_days int default 7)
returns table (
  game_slug text, plays bigint, likes bigint, hmms bigint,
  feedbacks bigint, again_much bigint, again_some bigint,
  hmm_controls bigint, hmm_heavy bigint, hmm_fun bigint, not_for_me bigint
)
language sql stable security definer set search_path = public as $$
  with w as (select now() - make_interval(days => greatest(1, least(coalesce(since_days, 7), 3650))) as t),
  e as (
    select game_slug,
           count(distinct client_id) filter (where kind = 'play') as plays,
           count(distinct client_id) filter (where kind = 'like') as likes,
           -- 「好みのジャンルじゃない」は作品の評価に入れない
           count(distinct client_id) filter (where kind = 'hmm' and coalesce(reason, '') <> 'genre') as hmms,
           count(distinct client_id) filter (where kind = 'hmm' and reason = 'controls') as hmm_controls,
           count(distinct client_id) filter (where kind = 'hmm' and reason = 'heavy')    as hmm_heavy,
           count(distinct client_id) filter (where kind = 'hmm' and reason = 'fun')      as hmm_fun,
           count(distinct client_id) filter (where kind = 'hmm' and reason = 'genre')    as not_for_me
    from game_events, w where created_at >= w.t group by game_slug
  ),
  f as (
    select game_slug,
           count(*) as feedbacks,
           count(*) filter (where again = 'すごく遊びたい')   as again_much,
           count(*) filter (where again = 'ちょっと遊びたい') as again_some
    from feedback, w where hidden = false and created_at >= w.t group by game_slug
  )
  select coalesce(e.game_slug, f.game_slug),
         coalesce(e.plays, 0), coalesce(e.likes, 0), coalesce(e.hmms, 0),
         coalesce(f.feedbacks, 0), coalesce(f.again_much, 0), coalesce(f.again_some, 0),
         coalesce(e.hmm_controls, 0), coalesce(e.hmm_heavy, 0), coalesce(e.hmm_fun, 0), coalesce(e.not_for_me, 0)
  from e full join f on e.game_slug = f.game_slug;
$$;
revoke all on function public.game_stats(int) from public;
grant execute on function public.game_stats(int) to anon, authenticated;
