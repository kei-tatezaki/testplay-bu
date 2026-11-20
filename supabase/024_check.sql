-- 024 の確認（024_models.sql まで流したあとに流す）。最後にわざとエラーを出して取り消す（データは残らない）
--   CHECK_OK 024: N件ぜんぶ合格 ／ CHECK_FAILED 024: …
do $chk$
declare
  n int := 0; bad text := ''; r text; j jsonb; sid uuid; rid uuid;
  uu uuid := gen_random_uuid(); ua uuid := gen_random_uuid();
  base jsonb := '{"type":"model","title":"テスト剣士","oneliner":"ゲーム用の剣士キャラ","model_use":"game_char","model_target":"sp","model_purpose":"スマホのアクションゲームで動かすキャラ。軽さと見た目のバランスを見てほしい","model_rig":"yes","model_anim":"no","model_budget":"15000"}';
begin
  insert into auth.users (id, email) select x, 'c-' || x || '@example.com' from unnest(array[uu, ua]) x;
  insert into admins (user_id) values (ua);
  perform set_config('request.jwt.claims', json_build_object('sub', uu, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uu::text, true);

  -- ファイルもURLもない → need_model_file
  begin r := submission_send('new', null, base); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'need_model_file' then bad := bad || E'\n  x ファイルもURLもないと止まる（' || r || '）'; end if;
  -- 目的がない → need_model_purpose
  begin r := submission_send('new', null, (base - 'model_purpose') || '{"model_url":"https://sketchfab.com/3d-models/x"}'); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'need_model_purpose' then bad := bad || E'\n  x 目的がないと止まる（' || r || '）'; end if;
  -- 用途が決まった中にない → bad_model
  begin r := submission_send('new', null, base || '{"model_use":"hack","model_url":"https://sketchfab.com/3d-models/x"}'); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'bad_model' then bad := bad || E'\n  x 用途は決まった中から（' || r || '）'; end if;
  -- ほかの人のフォルダのファイル → bad_model
  begin r := submission_send('new', null, base || jsonb_build_object('model_path', ua::text || '/a.glb')); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'bad_model' then bad := bad || E'\n  x ほかの人のフォルダは使えない（' || r || '）'; end if;
  -- 拡張子が glb / vrm 以外 → bad_model
  begin r := submission_send('new', null, base || jsonb_build_object('model_path', uu::text || '/a.fbx')); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'bad_model' then bad := bad || E'\n  x glb / vrm だけ（' || r || '）'; end if;
  -- まだ置いていないファイル → media_missing
  begin r := submission_send('new', null, base || jsonb_build_object('model_path', uu::text || '/kenshi.glb')); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'media_missing' then bad := bad || E'\n  x 置いていないファイルは止まる（' || r || '）'; end if;
  -- 置いたファイルなら通る（最初の1本は無料）。play_url はいらない
  insert into storage.objects (bucket_id, name, owner) values ('submission-media', uu::text || '/kenshi.glb', uu);
  begin r := submission_send('new', null, base || jsonb_build_object('model_path', uu::text || '/kenshi.glb', 'play_kind', 'download')); exception when others then r := 'ERR ' || sqlerrm; end;
  n := n + 1; if r <> 'ok_free' then bad := bad || E'\n  x モデルの応募が通る（' || r || '）'; end if;
  select id, data into sid, j from submissions where user_id = uu order by created_at desc limit 1;
  n := n + 1; if j ->> 'type' <> 'model' or j ->> 'model_purpose' is null or j ? 'play_kind' or j ->> 'model_budget' <> '15000' then bad := bad || E'\n  x 保存された中身（' || j || '）'; end if;
  -- ゲームの応募は今までどおり play_url が要る
  begin r := submission_send('new', null, '{"title":"t","oneliner":"o"}'); exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'bad_url' then bad := bad || E'\n  x ゲームは今までどおり URL が要る（' || r || '）'; end if;

  -- ---------- 運営でない人は記録を読めない・書けない ----------
  begin perform admin_model_review_save(sid, '{"tris":1}', null); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'not_admin' then bad := bad || E'\n  x 運営以外は記録できない（' || r || '）'; end if;
  begin perform admin_submission_note(sid, 'x'); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'not_admin' then bad := bad || E'\n  x 運営以外はコメントを送れない（' || r || '）'; end if;

  -- ---------- 運営 ----------
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', ua::text, true);
  for i in 1..7 loop rid := admin_model_review_save(sid, jsonb_build_object('tris', 1000 * i), jsonb_build_object('summary', 'v' || i)); end loop;
  j := admin_model_review_latest(sid);
  n := n + 1; if (j -> 'stats' ->> 'tris')::int <> 7000 or j -> 'ai' ->> 'summary' <> 'v7' then bad := bad || E'\n  x いちばん新しい記録が読める（' || j || '）'; end if;
  n := n + 1; if (select count(*) from model_reviews where submission_id = sid) <> 5 then bad := bad || E'\n  x 記録は5件まで残す'; end if;
  begin perform admin_model_review_save(sid, to_jsonb(repeat('x', 70000)), null); r := 'ok'; exception when others then r := sqlerrm; end;
  n := n + 1; if r <> 'bad_stats' then bad := bad || E'\n  x 大きすぎる・形のちがう記録は止まる（' || r || '）'; end if;
  r := admin_submission_note(sid, repeat('あ', 1600));
  n := n + 1; if (select char_length(admin_note) from submissions where id = sid) <> 1500 or (select status from submissions where id = sid) <> 'new' then bad := bad || E'\n  x コメントは1500字まで・状態は変えない'; end if;
  n := n + 1; if has_table_privilege('authenticated', 'public.model_reviews', 'select') then bad := bad || E'\n  x 記録の表はだれも直接読めない'; end if;

  if bad = '' then raise exception 'CHECK_OK 024: %件ぜんぶ合格', n;
  else raise exception 'CHECK_FAILED 024: %', bad; end if;
end $chk$;
