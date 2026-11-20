-- 016：今日のミッション＋スタンプカード／応募の「遊び方」（ブラウザ・ダウンロード）
-- 012（ポイント）・013・014 のあとに流す。何度流しても同じ（create or replace・if not exists）。
--
-- 【1】応募の遊び方（submission_send を 014 版から置きかえる）
--   data に新しいキー：play_kind（'browser' | 'download'）、size（容量の目安・20字まで）、os（Windows / Mac / Windows・Mac）、embed_url
--   ・play_kind は browser か download だけ（なければ browser あつかい）
--   ・embed_url は itch.io の埋め込み（https://itch.io/embed-upload/数字 ではじまる）だけ。ブラウザのときだけ置ける
--   ・download のときの play_url は、itch.io・store.steampowered.com・booth.pm・github.com・*.github.io のページだけ
--     （ファイルへの直リンク：exe・zip などや、GitHub の releases/download・archive・raw は不可）。platform は pc に直す
--
-- 【2】今日のミッション（日本時間の朝5時に切りかわる「今日」）
--   (a) 作品を1本遊ぶ …… ポイントなし（ハンコだけ。端末で記録するので、ここでは付与しない）
--   (b) 一言が40字以上（空白は数えない）の感想を1件 …… +3pt   （settings: mission_b_pt）
--   (c) 感想が少ない作品（他の人の表示中の感想が tier1_max 件以内）に感想を1件 …… +5pt （mission_c_pt）
--   3つ全部（(b)(c) を満たし、かつ今日に本人の遊んだ記録が1件以上）…… +5pt （mission_all_pt）
--   ・ポイントの付与は、このデータベースの中だけ。端末から送る値は信用しない
--   ・(b)(c) に数える感想は、012 のポイント計算で「0pt の理由（短い・くり返し・自分の作品・遊んでいない）」がなく、表示中のもの
--   ・1日1回ずつ・何度呼んでも二重にならない（points_ledger の (user_id, reason, note=今日の日付) が1つだけ）
--   ・1日の上限（daily_cap・50pt）に、ミッションのポイントも含める。上限にかかった分は付けない（上限がゆるんだら、あとで付く）
--   ・BANされた人は対象外。感想が非表示になったら、その感想で付いたミッションのポイントを取り消す（表示に戻っても返さない）
--   ・「本人の遊んだ記録」は、game_events / play_sessions に user_id がないので、本人の感想に書かれた client_id で本人と結ぶ
--     （012 の「遊んでいない」判定と同じ考え方）
--   ・付与のしかた：感想の insert のあとに動くトリガー ＋ 画面が daily_missions_status() を呼んだとき（あとから届いた遊んだ記録でボーナスが付く場合のため）

-- ---------- 決まり ----------
insert into public.settings (key, value, label) values
  ('mission_b_pt',   3, 'ミッション：40字以上の感想を書いたときのポイント'),
  ('mission_c_pt',   5, 'ミッション：感想が少ない作品に感想を書いたときのポイント'),
  ('mission_all_pt', 5, 'ミッション：3つ全部そろえたときのボーナスポイント')
on conflict (key) do nothing;

alter table public.points_ledger drop constraint if exists points_ledger_reason_check;
alter table public.points_ledger add constraint points_ledger_reason_check check (reason in
  ('feedback', 'feedback_revoked', 'feedback_restored', 'submission', 'submission_refund', 'admin_adjust',
   'mission_feedback', 'mission_fresh', 'mission_all', 'mission_revoked'));
-- 同じ日に、同じミッションのポイントは1回だけ（note に「今日」の日付を入れる）
create unique index if not exists points_ledger_mission_once on public.points_ledger (user_id, reason, note)
  where reason in ('mission_feedback', 'mission_fresh', 'mission_all');

-- ---------- 「今日」（日本時間の朝5時はじまり） ----------
create or replace function public.mission_day(ts timestamptz default now()) returns date
language sql stable set search_path = public as $$
  select ((ts at time zone 'Asia/Tokyo') - interval '5 hours')::date;
$$;
create or replace function public.mission_start(d date) returns timestamptz
language sql stable set search_path = public as $$
  select (d::timestamp + interval '5 hours') at time zone 'Asia/Tokyo';
$$;

-- 1日の上限は、ミッションでもらった分も数える（012 の points_today を置きかえる。日付は今までどおり日本時間の0時はじまり）
create or replace function public.points_today(uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from points_ledger
  where user_id = uid and reason in ('feedback', 'mission_feedback', 'mission_fresh', 'mission_all')
    and (created_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date;
$$;

-- ---------- 部品（外からは呼べない） ----------
-- その日（ミッションの日 d）に、本人が書いた感想のうち、ミッションに数えられるもの
--   few = その作品で、この感想より前に書かれた他の人の表示中の感想が tier1_max 件以内
create or replace function public.mission_feedbacks(uid uuid, d date)
returns table (id uuid, game_slug text, created_at timestamptz, few boolean)
language sql stable security definer set search_path = public as $$
  select f.id, f.game_slug, f.created_at,
         (select count(*) from feedback o
            where o.game_slug = f.game_slug and o.hidden = false and o.user_id is distinct from uid and o.created_at < f.created_at
         ) <= setting_int('tier1_max', 2)
  from feedback f
  join points_ledger l on l.ref = f.id and l.reason = 'feedback' and l.note in ('', 'cap')
  where f.user_id = uid and f.hidden = false
    and f.created_at >= mission_start(d) and f.created_at < mission_start(d) + interval '1 day'
    and char_length(regexp_replace(coalesce(f.free, ''), '[\s　]', '', 'g')) >= setting_int('min_chars', 40)
  order by f.created_at;
$$;

-- その日に、本人の遊んだ記録があるか（本人の感想の client_id で結ぶ）
create or replace function public.mission_played(uid uuid, d date) returns boolean
language sql stable security definer set search_path = public as $$
  with mine as (select distinct client_id from feedback where user_id = uid and hidden = false)
  select exists (select 1 from game_events e where e.kind = 'play' and e.client_id in (select client_id from mine)
                   and e.created_at >= mission_start(d) and e.created_at < mission_start(d) + interval '1 day')
      or exists (select 1 from play_sessions s where s.client_id in (select client_id from mine)
                   and s.created_at >= mission_start(d) and s.created_at < mission_start(d) + interval '1 day');
$$;

-- そのミッションで、いま付いているポイント（付与 − 取り消し）
create or replace function public.mission_net(uid uuid, kind text, dk text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from points_ledger
  where user_id = uid and ((reason = kind and note = dk) or (reason = 'mission_revoked' and note = kind || '@' || dk));
$$;

-- 取り消す（付いている分だけ。何度呼んでも二重にならない）
create or replace function public.mission_revoke(uid uuid, kind text, dk text) returns void
language plpgsql security definer set search_path = public as $$
declare net int := mission_net(uid, kind, dk);
begin
  if net > 0 then
    insert into points_ledger (user_id, delta, reason, note) values (uid, -net, 'mission_revoked', kind || '@' || dk);
  end if;
end $$;

-- 付ける（1日1回。上限にかかる分は付けない）
create or replace function public.mission_grant(uid uuid, kind text, pt int, src uuid, dk text) returns void
language plpgsql security definer set search_path = public as $$
declare give int;
begin
  if pt <= 0 then return; end if;
  if exists (select 1 from points_ledger where user_id = uid and reason = kind and note = dk) then return; end if;
  give := least(pt, setting_int('daily_cap', 50) - points_today(uid));
  if give <= 0 then return; end if;
  insert into points_ledger (user_id, delta, reason, ref, note) values (uid, give, kind, src, dk);
end $$;

-- 今日のミッションの達成を調べて、まだ付いていないポイントを付ける（何度呼んでも同じ）
create or replace function public.missions_award(uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d date := mission_day(); dk text := mission_day()::text; fb uuid; fc uuid;
begin
  if uid is null then return; end if;
  if exists (select 1 from banned_users where user_id = uid) then return; end if;
  perform points_lock(uid);
  select m.id into fb from mission_feedbacks(uid, d) m order by m.created_at limit 1;
  select m.id into fc from mission_feedbacks(uid, d) m where m.few order by m.created_at limit 1;
  if fb is not null then perform mission_grant(uid, 'mission_feedback', setting_int('mission_b_pt', 3), fb, dk); end if;
  if fc is not null then perform mission_grant(uid, 'mission_fresh', setting_int('mission_c_pt', 5), fc, dk); end if;
  if fb is not null and fc is not null and mission_played(uid, d) then
    perform mission_grant(uid, 'mission_all', setting_int('mission_all_pt', 5), fb, dk);
  end if;
end $$;

-- ---------- 感想を送ったとき ----------
-- トリガーは名前の順に動く。feedback_points_award（012）のあとに動くよう、名前を feedback_points_mission にしている
create or replace function public.feedback_points_mission() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null then return new; end if;
  begin
    perform missions_award(new.user_id);
  exception when others then
    raise warning 'feedback_points_mission: %', sqlerrm;   -- つまずいても、感想は受け付ける
  end;
  return new;
end $$;
drop trigger if exists feedback_points_mission on public.feedback;
create trigger feedback_points_mission after insert on public.feedback
  for each row execute function public.feedback_points_mission();

-- ---------- 感想が非表示／表示に戻ったとき（012 の feedback_points_hidden を置きかえる：ミッションの取り消しを足しただけ） ----------
create or replace function public.feedback_points_hidden() returns trigger
language plpgsql security definer set search_path = public as $$
declare orig int; net int; r record;
begin
  if new.user_id is null then return new; end if;
  perform points_lock(new.user_id);
  -- ミッション：この感想で付いた分を取り消す。3つ全部のボーナスは、(b)(c) のどちらかがなくなれば取り消す（表示に戻っても返さない）
  if new.hidden then
    for r in select l.reason, l.note from points_ledger l
             where l.user_id = new.user_id and l.ref = new.id and l.reason in ('mission_feedback', 'mission_fresh') loop
      perform mission_revoke(new.user_id, r.reason, r.note);
      perform mission_revoke(new.user_id, 'mission_all', r.note);
    end loop;
  end if;
  select delta into orig from points_ledger where reason = 'feedback' and ref = new.id;
  if coalesce(orig, 0) <= 0 then return new; end if;   -- 0pt だった感想・さかのぼり前の感想は何もしない
  select coalesce(sum(delta), 0) into net from points_ledger
    where ref = new.id and reason in ('feedback', 'feedback_revoked', 'feedback_restored');
  if new.hidden and net > 0 then
    insert into points_ledger (user_id, delta, reason, ref) values (new.user_id, -net, 'feedback_revoked', new.id);
  elsif not new.hidden and net = 0 then
    insert into points_ledger (user_id, delta, reason, ref) values (new.user_id, orig, 'feedback_restored', new.id);
  end if;
  return new;
end $$;

-- ---------- ログインした人：今日のミッション ----------
-- 返すもの：day（今日・朝5時はじまり）、b / c / all それぞれ { done, pt, granted }、played_today、points_today、daily_cap、balance、banned
--   done … 達成したか　pt … 決まりのポイント　granted … いま実際に付いている分（上限で減ることがある・取り消されたら0）
--   all.need_play … (b)(c) はできたが、今日の遊んだ記録がまだ
-- 呼ぶたびに、付いていない分があれば付ける（遅れて届いた遊んだ記録でボーナスが付くため）。同じ日に何度呼んでも二重にならない
create or replace function public.daily_missions_status() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); d date := mission_day(); dk text := mission_day()::text;
  bn boolean; fb boolean; fc boolean; pl boolean;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  bn := exists (select 1 from banned_users where user_id = uid);
  if not bn then perform missions_award(uid); end if;
  select exists (select 1 from mission_feedbacks(uid, d)), exists (select 1 from mission_feedbacks(uid, d) where few)
    into fb, fc;
  pl := mission_played(uid, d);
  return jsonb_build_object(
    'day', dk, 'banned', bn,
    'b',   jsonb_build_object('done', not bn and fb, 'pt', setting_int('mission_b_pt', 3),   'granted', mission_net(uid, 'mission_feedback', dk)),
    'c',   jsonb_build_object('done', not bn and fc, 'pt', setting_int('mission_c_pt', 5),   'granted', mission_net(uid, 'mission_fresh', dk)),
    'all', jsonb_build_object('done', not bn and fb and fc and pl, 'pt', setting_int('mission_all_pt', 5), 'granted', mission_net(uid, 'mission_all', dk),
                              'need_play', not bn and fb and fc and not pl),
    'played_today', pl,
    'points_today', points_today(uid), 'daily_cap', setting_int('daily_cap', 50), 'balance', points_balance(uid));
end $$;

-- ---------- 運営の画面：設定にミッションのポイントを足す・もらった合計にミッションを含める ----------
create or replace function public.admin_settings_get()
returns table (key text, value int, label text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select s.key, s.value, s.label from settings s
    order by array_position(array['min_chars','daily_cap','tier1_max','tier1_pt','tier2_max','tier2_pt','tier3_pt','submit_cost','mission_b_pt','mission_c_pt','mission_all_pt'], s.key), s.key;
end $$;

create or replace function public.admin_points_users()
returns table (user_id uuid, name text, email text, handle text, balance int, earned int, spent int, adjusted int, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
    select u.id,
           coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))::text,
           u.email::text, p.handle,
           coalesce(sum(l.delta), 0)::int,
           coalesce(sum(l.delta) filter (where l.reason in ('feedback', 'feedback_revoked', 'feedback_restored', 'mission_feedback', 'mission_fresh', 'mission_all', 'mission_revoked')), 0)::int,
           coalesce(-sum(l.delta) filter (where l.reason in ('submission', 'submission_refund')), 0)::int,
           coalesce(sum(l.delta) filter (where l.reason = 'admin_adjust'), 0)::int,
           max(l.created_at)
    from auth.users u
    left join points_ledger l on l.user_id = u.id
    left join profiles p on p.user_id = u.id
    where exists (select 1 from points_ledger x where x.user_id = u.id) or p.user_id is not null
    group by u.id, u.raw_user_meta_data, u.email, p.handle
    order by 5 desc, 9 desc nulls last
    limit 500;
end $$;

-- 概要の「配ったポイント」にミッション分を含める（012 の admin_overview を置きかえる：points の granted・revoked の2行だけ変えた）
create or replace function public.admin_overview(since_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_n     int  := greatest(1, least(coalesce(since_days, 7), 3650));
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_d0    date := (now() at time zone 'Asia/Tokyo')::date - (greatest(1, least(coalesce(since_days, 7), 3650)) - 1);
  v_t0    timestamptz;
  v_g     int  := case when greatest(1, least(coalesce(since_days, 7), 3650)) <= 7 then 7
                       else least(greatest(1, least(coalesce(since_days, 7), 3650)), 30) end;
  res     jsonb;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  v_t0 := v_d0::timestamp at time zone 'Asia/Tokyo';
  with
  sv as (select * from site_visits  where day >= v_d0),
  ev as (select * from game_events  where day >= v_d0),
  ps as (select * from play_sessions where created_at >= v_t0),
  fb as (select * from feedback      where created_at >= v_t0),
  sb as (select * from submissions   where created_at >= v_t0),
  pl as (select * from points_ledger where created_at >= v_t0)
  select jsonb_build_object(
    'since_days',  v_n,
    'from',        to_char(v_d0, 'YYYY-MM-DD'),
    'visitors',    (select count(distinct client_id) from sv),
    'visits',      (select count(*) from sv),
    'plays',       (select count(*) from ev where kind = 'play'),
    'players',     (select count(distinct client_id) from ev where kind = 'play'),
    'play_seconds_total', (select coalesce(sum(seconds), 0) from ps),
    'sessions',    (select count(*) from ps),
    'feedbacks',   jsonb_build_object(
                     'visible', (select count(*) from fb where hidden = false),
                     'hidden',  (select count(*) from fb where hidden = true)),
    'likes',       (select count(*) from ev where kind = 'like'),
    'hmms',        (select count(*) from ev where kind = 'hmm'),
    'submissions', jsonb_build_object(
                     'new', (select count(*) from sb where status = 'new'),
                     'ok',  (select count(*) from sb where status = 'ok'),
                     'ng',  (select count(*) from sb where status = 'ng')),
    'submissions_open', (select count(*) from submissions where status = 'new'),
    'reports_open',     (select count(*) from reports where done = false),
    'bans',        jsonb_build_object(
                     'client', (select count(*) from banned_clients),
                     'user',   (select count(*) from banned_users)),
    'points',      jsonb_build_object(
                     'granted',     (select coalesce(sum(delta), 0) from pl where reason in ('feedback', 'mission_feedback', 'mission_fresh', 'mission_all')),
                     'revoked',     (select coalesce(-sum(delta), 0) from pl where reason in ('feedback_revoked', 'feedback_restored', 'mission_revoked')),
                     'spent',       (select coalesce(-sum(delta), 0) from pl where reason = 'submission'),
                     'refunded',    (select coalesce(sum(delta), 0) from pl where reason = 'submission_refund'),
                     'adjusted',    (select coalesce(sum(delta), 0) from pl where reason = 'admin_adjust'),
                     'outstanding', (select coalesce(sum(delta), 0) from points_ledger)),
    'new_users',   (select count(*) from auth.users u where u.created_at >= v_t0),
    'daily',       (select coalesce(jsonb_agg(jsonb_build_object(
                       'day', to_char(g.d, 'YYYY-MM-DD'),
                       'visits',    (select count(*) from site_visits x where x.day = g.d),
                       'plays',     (select count(*) from game_events e where e.kind = 'play' and e.day = g.d),
                       'feedbacks', (select count(*) from feedback f where (f.created_at at time zone 'Asia/Tokyo')::date = g.d)
                     ) order by g.d), '[]'::jsonb)
                    from (select (v_today - i)::date as d from generate_series(0, v_g - 1) i) g),
    'top_games',   (select coalesce(jsonb_agg(jsonb_build_object('slug', t.game_slug, 'plays', t.plays, 'feedbacks', t.feedbacks)
                                              order by t.plays desc, t.feedbacks desc, t.game_slug), '[]'::jsonb)
                    from (select p.game_slug, p.plays,
                                 (select count(*) from fb where fb.game_slug = p.game_slug and fb.hidden = false) as feedbacks
                          from (select game_slug, count(*) as plays from ev where kind = 'play' group by game_slug) p
                          order by p.plays desc, 3 desc, p.game_slug limit 5) t)
  ) into res;
  return res;
end $$;

-- ---------- 応募（014 の submission_send を置きかえる。play_kind・size・os・embed_url を足しただけ） ----------
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
  foreach k in array array['title', 'play_url', 'oneliner', 'platform', 'check', 'question', 'minutes', 'genre', 'stage', 'rating', 'controls', 'image_url', 'note', 'media_kind', 'media_path',
                           'play_kind', 'size', 'os', 'embed_url'] loop
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

-- ---------- 権限 ----------
revoke all on function
  public.mission_day(timestamptz), public.mission_start(date), public.points_today(uuid),
  public.mission_feedbacks(uuid, date), public.mission_played(uuid, date), public.mission_net(uuid, text, text),
  public.mission_revoke(uuid, text, text), public.mission_grant(uuid, text, int, uuid, text), public.missions_award(uuid),
  public.feedback_points_mission(), public.feedback_points_hidden(),
  public.daily_missions_status(), public.admin_settings_get(), public.admin_points_users(), public.admin_overview(int),
  public.submission_send(text, text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.daily_missions_status(), public.admin_settings_get(), public.admin_points_users(), public.admin_overview(int), public.submission_send(text, text, jsonb)
  to authenticated;

select 'ok 016' as result;
