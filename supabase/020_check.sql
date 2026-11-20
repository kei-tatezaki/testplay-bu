-- 020 の確認（020_first_impression_pclist.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 020: N件ぜんぶ合格 ／ CHECK_FAILED 020: …
do $chk$
declare
  n int := 0; bad text := '';
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); ua uuid := gen_random_uuid();
  c int; ok boolean; j jsonb; r text; d jsonb; rec record; fid uuid;
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[u1,u2,u3,ub,ua]) x;
  insert into banned_users (user_id) values (ub);
  insert into admins (user_id) values (ua);
  insert into game_owners (game_slug, user_id) values ('gx', u1);
  insert into banned_words (word) values ('わるいことば') on conflict do nothing;
  insert into banned_clients (client_id) values ('banned-client-1');

  -- ================= 第一印象 =================
  -- ---- 未ログイン（anon）で送れる ----
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  j := first_impression_send('gx', 'client-aaaa-0001', 3, '  やってみたい  ');
  n := n + 1; if j ->> 'ok' <> 'true' or (j ->> 'updated')::boolean then bad := bad || E'\n  x 未ログインで送れる（' || j || '）'; end if;
  -- 同じ端末・同じ作品・同じ日は1日1回（上書き）
  j := first_impression_send('gx', 'client-aaaa-0001', 1, null);
  n := n + 1; if (j ->> 'updated')::boolean is not true then bad := bad || E'\n  x 2回目は上書き（' || j || '）'; end if;
  reset role;
  select count(*) into c from first_impressions where game_slug = 'gx'; n := n + 1; if c <> 1 then bad := bad || E'\n  x 1日1回なので行は1つ（' || c || '）'; end if;
  select level, note into rec from first_impressions where game_slug = 'gx';
  n := n + 1; if rec.level <> 1 or rec.note is not null then bad := bad || E'\n  x 上書きで段階とひとことが新しくなる（' || rec.level || '／' || coalesce(rec.note, 'null') || '）'; end if;
  -- ほかの作品・ほかの端末は別に送れる
  set local role anon;
  perform first_impression_send('gy', 'client-aaaa-0001', 2, 'ひとこと');
  perform first_impression_send('gx', 'client-bbbb-0002', 3, '  やってみたい  ');
  reset role;
  select count(*) into c from first_impressions; n := n + 1; if c <> 3 then bad := bad || E'\n  x 作品や端末がちがえば別（' || c || '）'; end if;
  select note into r from first_impressions where client_id = 'client-bbbb-0002'; n := n + 1; if r <> 'やってみたい' then bad := bad || E'\n  x ひとことの前後の空白は取る（' || coalesce(r, 'null') || '）'; end if;
  -- 日がちがえば別の行
  update first_impressions set day = day - 1 where client_id = 'client-bbbb-0002';
  set local role anon; j := first_impression_send('gx', 'client-bbbb-0002', 2, null); reset role;
  n := n + 1; if (j ->> 'updated')::boolean then bad := bad || E'\n  x 次の日は新しく入る'; end if;
  select count(*) into c from first_impressions where client_id = 'client-bbbb-0002'; n := n + 1; if c <> 2 then bad := bad || E'\n  x 次の日の行（' || c || '）'; end if;

  -- ---- 断るもの ----
  set local role anon;
  ok := false; begin perform first_impression_send('gx', 'client-cccc-0003', 4, null); exception when others then ok := (sqlerrm = 'bad_level'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 段階は1〜3（4は bad_level）'; end if;
  ok := false; begin perform first_impression_send('gx', 'client-cccc-0003', 0, null); exception when others then ok := (sqlerrm = 'bad_level'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 0は bad_level'; end if;
  ok := false; begin perform first_impression_send('GX!', 'client-cccc-0003', 2, null); exception when others then ok := (sqlerrm = 'bad_slug'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作品IDの形が違う（bad_slug）'; end if;
  ok := false; begin perform first_impression_send('gx', 'short', 2, null); exception when others then ok := (sqlerrm = 'bad_client'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 端末IDが短い（bad_client）'; end if;
  ok := false; begin perform first_impression_send('gx', 'client-cccc-0003', 2, repeat('a', 101)); exception when others then ok := (sqlerrm = 'too_long'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 101字は too_long'; end if;
  ok := true; begin perform first_impression_send('gx', 'client-cccc-0003', 2, repeat('a', 100)); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 100字ちょうどは送れる'; end if;
  ok := false; begin perform first_impression_send('gx', 'client-dddd-0004', 2, 'これはわるいことばです'); exception when others then ok := (sqlerrm = 'banned_word'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 禁止ワードは banned_word'; end if;
  ok := false; begin perform first_impression_send('gx', 'banned-client-1', 3, null); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x banned_clients の端末は banned'; end if;
  -- 表への直接の読み書きはできない
  ok := false; begin insert into first_impressions (game_slug, client_id, level) values ('gx', 'client-eeee-0005', 3); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は表に直接入れられない'; end if;
  ok := false; begin perform count(*) from first_impressions; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は表を直接読めない'; end if;
  reset role;

  -- ---- ログイン中：user_id で1日1回（端末が変わっても上書き）・BAN ----
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  j := first_impression_send('gx', 'client-ffff-0006', 3, 'ログイン中');
  j := first_impression_send('gx', 'client-gggg-0007', 2, 'べつの端末');
  n := n + 1; if (j ->> 'updated')::boolean is not true then bad := bad || E'\n  x ログイン中は端末がちがっても同じ人は1日1回（' || j || '）'; end if;
  reset role;
  select count(*) into c from first_impressions where user_id = u2 and game_slug = 'gx'; n := n + 1; if c <> 1 then bad := bad || E'\n  x user_id の行は1つ（' || c || '）'; end if;
  perform set_config('request.jwt.claim.sub', ub::text, true);
  set local role authenticated;
  ok := false; begin perform first_impression_send('gx', 'client-hhhh-0008', 3, null); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN されたアカウントは送れない'; end if;
  reset role;
  -- 1端末あたり1日40件まで
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  for i in 1..40 loop perform first_impression_send('g' || i, 'client-many-0001', 2, null); end loop;
  ok := false; begin perform first_impression_send('g41', 'client-many-0001', 2, null); exception when others then ok := (sqlerrm = 'too_many'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 41件目は too_many'; end if;
  ok := true; begin perform first_impression_send('g1', 'client-many-0001', 3, null); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 上限でも、すでに送った作品の上書きはできる'; end if;
  reset role;
  delete from first_impressions where game_slug like 'g%' and game_slug <> 'gx' and game_slug <> 'gy';

  -- ---- 集計：作者だけ ----
  -- gx の現在：client-aaaa-0001(1,null) / client-bbbb-0002(3 昨日,2 今日) / cccc(2, 100字) / u2(2,'べつの端末')
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  j := dev_first_impressions('gx');
  n := n + 1; if (j ->> 'total')::int <> 5 or (j ->> 'want')::int <> 1 or (j ->> 'maybe')::int <> 3 or (j ->> 'no')::int <> 1 then bad := bad || E'\n  x 作者の集計（' || j || '）'; end if;
  n := n + 1; if jsonb_array_length(j -> 'recent') <> 3 then bad := bad || E'\n  x 最近のひとこと（ひとこと入りだけ）（' || jsonb_array_length(j -> 'recent') || '）'; end if;
  n := n + 1; if j::text like '%client%' or j::text like '%user_id%' then bad := bad || E'\n  x 集計に端末ID・user_id を含めない'; end if;
  ok := false; begin perform dev_first_impressions('gy'); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者でない作品は not_allowed'; end if;
  ok := false; begin perform admin_first_impressions(30); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者でも admin_first_impressions は不可'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  ok := false; begin perform dev_first_impressions('gx'); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x ほかの人は自分の作品でなければ not_allowed'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  ok := false; begin perform dev_first_impressions('gx'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 未ログインは dev_first_impressions を呼べない'; end if;
  -- 作品ページ用（だれでも）：5件たまっているのでひとことも出る
  j := first_impression_public('gx');
  n := n + 1; if (j ->> 'total')::int <> 5 or jsonb_array_length(j -> 'recent') <> 3 then bad := bad || E'\n  x 公開の集計（' || j || '）'; end if;
  j := first_impression_public('gy');
  n := n + 1; if (j ->> 'total')::int <> 1 or jsonb_array_length(j -> 'recent') <> 0 then bad := bad || E'\n  x 5件たまるまでは件数だけ（' || j || '）'; end if;
  reset role;
  -- 運営
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated;
  select count(*) into c from admin_first_impressions(30) where game_slug = 'gx' and want = 1 and maybe = 3 and no = 1; n := n + 1; if c <> 1 then bad := bad || E'\n  x 運営の作品ごとの件数'; end if;
  j := dev_first_impressions('gx'); n := n + 1; if (j ->> 'total')::int <> 5 then bad := bad || E'\n  x 運営はどの作品も見られる'; end if;
  reset role;
  select id into fid from first_impressions where note = 'べつの端末' limit 1;
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated; perform admin_first_impression_hide(fid, true); reset role;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated; j := dev_first_impressions('gx'); reset role;
  n := n + 1; if jsonb_array_length(j -> 'recent') <> 2 or (j ->> 'total')::int <> 5 then bad := bad || E'\n  x 隠したひとことは出ない（件数は変わらない）'; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  ok := false; begin perform admin_first_impression_hide(fid, false); exception when others then ok := (sqlerrm = 'not_allowed'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作者は隠せない'; end if;
  reset role;

  -- ポイント・ミッションには関係しない
  select count(*) into c from points_ledger; n := n + 1; if c <> 0 then bad := bad || E'\n  x 第一印象でポイントが動かない（' || c || '）'; end if;

  -- ================= PCで遊ぶリスト =================
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  insert into pc_list (game_slug) values ('gx');
  insert into pc_list (user_id, game_slug) values (u1, 'gy');
  select count(*) into c from pc_list; n := n + 1; if c <> 2 then bad := bad || E'\n  x 自分の行が見える（' || c || '）'; end if;
  ok := false; begin insert into pc_list (game_slug) values ('gx'); exception when unique_violation then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 同じ作品は二重に入らない'; end if;
  ok := false; begin insert into pc_list (user_id, game_slug) values (u2, 'gx'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 他人になりすまして入れられない'; end if;
  ok := false; begin insert into pc_list (game_slug) values ('BAD SLUG'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 作品IDの形（check）'; end if;
  ok := false; begin update pc_list set game_slug = 'zz'; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x update は権限がない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', u2::text, true);
  set local role authenticated;
  select count(*) into c from pc_list; n := n + 1; if c <> 0 then bad := bad || E'\n  x 他人の行は見えない（' || c || '）'; end if;
  delete from pc_list; reset role;
  select count(*) into c from pc_list where user_id = u1; n := n + 1; if c <> 2 then bad := bad || E'\n  x 他人の行は消せない（' || c || '）'; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  set local role authenticated;
  delete from pc_list where game_slug = 'gy'; reset role;
  select count(*) into c from pc_list where user_id = u1; n := n + 1; if c <> 1 then bad := bad || E'\n  x 自分の行は消せる（' || c || '）'; end if;
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  ok := false; begin perform count(*) from pc_list; exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は pc_list を読めない'; end if;
  ok := false; begin perform pclist_import(array['a-b']); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x anon は pclist_import を呼べない'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', ub::text, true);
  set local role authenticated;
  ok := false; begin insert into pc_list (game_slug) values ('gx'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN された人は入れられない'; end if;
  ok := false; begin perform pclist_import(array['gx']); exception when others then ok := (sqlerrm = 'banned'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x BAN された人は pclist_import 不可'; end if;
  reset role;

  -- ---- 上限200・引き継ぎ ----
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  j := pclist_import(array['a-1', 'a-2', 'a-1', 'BAD SLUG', null, 'a-3']);
  n := n + 1; if (j ->> 'added')::int <> 3 or (j ->> 'total')::int <> 3 then bad := bad || E'\n  x 引き継ぎ：重複と形のちがうものは無視（' || j || '）'; end if;
  j := pclist_import(array['a-1', 'a-4']);
  n := n + 1; if (j ->> 'added')::int <> 1 or (j ->> 'total')::int <> 4 then bad := bad || E'\n  x 引き継ぎ：すでにあるものは数えない（' || j || '）'; end if;
  j := pclist_import((select array_agg('b-' || g) from generate_series(1, 300) g));
  n := n + 1; if (j ->> 'total')::int <> 200 then bad := bad || E'\n  x 引き継ぎは合計200本まで（' || j || '）'; end if;
  ok := false; begin insert into pc_list (game_slug) values ('over-limit'); exception when others then ok := (sqlerrm = 'pc_list_full'); end;
  n := n + 1; if not ok then bad := bad || E'\n  x 201本目は pc_list_full'; end if;
  delete from pc_list where game_slug = 'a-1';
  ok := true; begin insert into pc_list (game_slug) values ('over-limit'); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 1本消せばまた入れられる'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  delete from pc_list where user_id = u3;
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  j := pclist_import((select array_agg('c-' || g) from generate_series(1, 250) g));
  n := n + 1; if (j ->> 'added')::int <> 200 then bad := bad || E'\n  x 1回の引き継ぎは200本まで（' || j || '）'; end if;
  reset role;

  -- ================= 応募の size_mb =================
  perform set_config('request.jwt.claim.sub', u2::text, true);
  declare
    cases jsonb; cs jsonb;
  begin
    cases := jsonb_build_array(
      jsonb_build_array('size_mb 25', 'ok', jsonb_build_object('size_mb', '25')),
      jsonb_build_array('size_mb 数字（number）', 'ok', jsonb_build_object('size_mb', 25)),
      jsonb_build_array('size_mb 小数', 'ok', jsonb_build_object('size_mb', '0.5')),
      jsonb_build_array('size_mb 小数2けた', 'ok', jsonb_build_object('size_mb', '12.25')),
      jsonb_build_array('size_mb 空は無視', 'ok', jsonb_build_object('size_mb', '')),
      jsonb_build_array('size_mb 0', 'bad_size_mb', jsonb_build_object('size_mb', '0')),
      jsonb_build_array('size_mb 負', 'bad_size_mb', jsonb_build_object('size_mb', '-5')),
      jsonb_build_array('size_mb 単位つき', 'bad_size_mb', jsonb_build_object('size_mb', '25MB')),
      jsonb_build_array('size_mb 文字', 'bad_size_mb', jsonb_build_object('size_mb', 'おもい')),
      jsonb_build_array('size_mb 大きすぎ', 'bad_size_mb', jsonb_build_object('size_mb', '999999')),
      jsonb_build_array('size_mb 小数3けた', 'bad_size_mb', jsonb_build_object('size_mb', '1.234')),
      jsonb_build_array('size_mb 数字・負', 'bad_size_mb', jsonb_build_object('size_mb', -1)),
      jsonb_build_array('fb_style gentle', 'ok', jsonb_build_object('fb_style', 'gentle')),
      jsonb_build_array('fb_style honest', 'ok', jsonb_build_object('fb_style', 'honest')),
      jsonb_build_array('fb_style both', 'ok', jsonb_build_object('fb_style', 'both')),
      jsonb_build_array('fb_style 不正', 'bad_fb_style', jsonb_build_object('fb_style', 'rough')),
      jsonb_build_array('goal 60字', 'ok', jsonb_build_object('goal', repeat('a', 60))),
      jsonb_build_array('goal 61字', 'bad_goal', jsonb_build_object('goal', repeat('a', 61))),
      -- 既存の確かめは変わらない
      jsonb_build_array('既存：embed 別ホスト', 'bad_embed', jsonb_build_object('embed_url', 'https://evil.com/embed-upload/1')),
      jsonb_build_array('既存：DL exe 直リンク', 'bad_download_url', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x/file.exe')),
      jsonb_build_array('既存：os 不正', 'bad_os', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x', 'os', 'Linux')),
      jsonb_build_array('既存：size 長すぎ', 'too_long', jsonb_build_object('play_kind', 'download', 'play_url', 'https://a.itch.io/x', 'size', repeat('9', 21))),
      jsonb_build_array('既存：play_kind 不正', 'bad_play_kind', jsonb_build_object('play_kind', 'foo')));
    for cs in select * from jsonb_array_elements(cases) loop
      delete from submissions where user_id = u2;
      d := jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://x.itch.io/game') || (cs -> 2);
      begin r := submission_send('new', null, d); if r like 'ok%' then r := 'ok'; end if; exception when others then r := sqlerrm; end;
      n := n + 1; if r <> cs ->> 1 then bad := bad || E'\n  x 応募「' || (cs ->> 0) || '」：期待 ' || (cs ->> 1) || '／いま ' || r; end if;
    end loop;
  end;
  delete from submissions where user_id = u2;
  r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://x.itch.io/game', 'size_mb', 25, 'evil', 'x'));
  select data into d from submissions where user_id = u2;
  n := n + 1; if d ->> 'size_mb' <> '25' or d ? 'evil' then bad := bad || E'\n  x size_mb は保存・許可のないキーは捨てる（' || d || '）'; end if;
  delete from submissions where user_id = u2;
  r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://x.itch.io/game', 'fb_style', 'honest', 'goal', '1面で操作を覚えてもらう'));
  select data into d from submissions where user_id = u2;
  n := n + 1; if d ->> 'fb_style' <> 'honest' or d ->> 'goal' <> '1面で操作を覚えてもらう' then bad := bad || E'\n  x fb_style・goal は保存される（' || d || '）'; end if;
  delete from submissions where user_id = u2;
  begin r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://x.itch.io/game', 'size_mb', '25', 'note', 'これはわるいことばです')); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'banned_word' then bad := bad || E'\n  x 禁止ワードは今までどおり（' || r || '）'; end if;
  -- 最初の1本は無料（今までどおり）
  delete from submissions where user_id = u2;
  r := submission_send('new', null, jsonb_build_object('title', 't', 'oneliner', 'o', 'play_url', 'https://x.itch.io/game', 'size_mb', '5'));
  n := n + 1; if r <> 'ok_free' then bad := bad || E'\n  x 最初の1本は ok_free（' || r || '）'; end if;
  delete from submissions where user_id = u2;

  -- 作者の質問の答え「はい／いいえ」だけの感想も入る（021）
  perform set_config('request.jwt.claim.sub', u3::text, true);
  set local role authenticated;
  ok := true; begin insert into feedback (game_slug, again, reach, answer, client_id) values ('gx', 'すごく遊びたい', '最後まで', 'はい', 'client-ans-0001'); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 答えだけ（はい）の感想が入る'; end if;
  ok := true; begin insert into feedback (game_slug, again, reach, answer, client_id) values ('gy', 'すごく遊びたい', '最後まで', 'いいえ', 'client-ans-0001'); exception when others then ok := false; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 答えだけ（いいえ）の感想が入る'; end if;
  ok := false; begin insert into feedback (game_slug, again, reach, answer, client_id) values ('gz', 'すごく遊びたい', '最後まで', 'まあまあ', 'client-ans-0001'); exception when others then ok := true; end;
  n := n + 1; if not ok then bad := bad || E'\n  x 「まあまあ」は入らない'; end if;
  reset role;

  -- ---- 権限 ----
  n := n + 1; if not has_function_privilege('anon', 'public.first_impression_send(text,text,integer,text)', 'execute') or not has_function_privilege('anon', 'public.first_impression_public(text)', 'execute') then bad := bad || E'\n  x anon は送信と公開集計を呼べる'; end if;
  n := n + 1; if has_function_privilege('anon', 'public.dev_first_impressions(text)', 'execute') or has_function_privilege('anon', 'public.admin_first_impressions(integer)', 'execute') or has_function_privilege('anon', 'public.fi_summary(text,integer)', 'execute') or has_function_privilege('authenticated', 'public.fi_summary(text,integer)', 'execute') then bad := bad || E'\n  x 集計の部品は外から呼べない'; end if;
  n := n + 1; if has_table_privilege('anon', 'public.first_impressions', 'insert') or has_table_privilege('authenticated', 'public.first_impressions', 'select') or has_table_privilege('anon', 'public.pc_list', 'select') or has_table_privilege('authenticated', 'public.pc_list', 'update') then bad := bad || E'\n  x 表の権限'; end if;
  -- 利用者が消えたら、行も消える
  delete from auth.users where id = u3;
  select count(*) into c from pc_list where user_id = u3; n := n + 1; if c <> 0 then bad := bad || E'\n  x アカウントを消したら pc_list も消える'; end if;
  delete from auth.users where id = u2;
  select count(*) into c from first_impressions where user_id = u2; n := n + 1; if c <> 0 then bad := bad || E'\n  x アカウントを消したら第一印象も消える'; end if;

  if bad = '' then raise exception 'CHECK_OK 020: %件ぜんぶ合格（この「エラー」は、テスト用のデータを取り消すためにわざと出しています）', n;
  else raise exception 'CHECK_FAILED 020: %件中 % 件が不合格%', n, array_length(string_to_array(trim(both E'\n' from bad), E'\n'), 1), bad; end if;
end
$chk$;
