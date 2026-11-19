-- 009 の関数がルールどおり動くかを確かめる（何も残さない：最後にわざとエラーにして全部取り消す）
-- SQL Editor で実行すると、エラーの文に結果が出る。「ROLLBACK_OK」で始まっていれば、データは何も変わっていない。
do $$
declare uid uuid; r text; out text := '';
begin
  select u.id into uid from auth.users u where not exists (select 1 from public.profiles p where p.user_id = u.id) order by u.created_at desc limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  out := out || 'admin=' || public.is_admin() || E'\n';
  begin r := public.profile_save('Claude_Test_1','テスト太郎','ひとこと',null,'["https://x.com/a","https://a.itch.io"]'::jsonb,'https://youtu.be/dQw4w9WgXcQ')::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '1 save: ' || r || E'\n';
  begin r := public.profile_save('ab','x','',null,'[]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '2 short handle: ' || r || E'\n';
  begin r := public.profile_save('claude_test_1','x','',null,'["http://a.com"]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '3 http link: ' || r || E'\n';
  begin r := public.profile_save('claude_test_1','x','',null,'["javascript:alert(1)"]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '4 js link: ' || r || E'\n';
  begin r := public.profile_save('claude_test_1','x','',null,'[]'::jsonb,'https://evil.example/youtube.com/')::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '5 bad video: ' || r || E'\n';
  begin r := public.profile_save('claude_test_1','x','','https://jwrzqaxuvmdbroemenng.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-000000000000/a.jpg','[]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '6 other avatar: ' || r || E'\n';
  begin r := public.profile_save('claude_test_1','x','',format('https://jwrzqaxuvmdbroemenng.supabase.co/storage/v1/object/public/avatars/%s/a-1.jpg',uid),'[]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '7 own avatar: ' || left(r,60) || E'\n';
  begin r := public.profile_save('unei','x','',null,'[]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '8 reserved: ' || left(r,40) || E'\n';
  begin r := public.profile_save('claude_test_1',repeat('あ',31),'',null,'[]'::jsonb,null)::text; exception when others then r := 'ERR '||sqlerrm; end; out := out || '9 long name: ' || r || E'\n';
  out := out || '10 my_profile: ' || coalesce(left(public.my_profile()::text,80),'null') || E'\n';
  out := out || '11 profile_get: ' || coalesce(left(public.profile_get('CLAUDE_test_1')::text,60),'null') || E'\n';
  begin r := public.submission_send('new',null,'{"title":"t","oneliner":"o","play_url":"https://example.com/g","evil":"x"}'::jsonb); exception when others then r := 'ERR '||sqlerrm; end; out := out || '12 sub: ' || r || E'\n';
  begin r := public.submission_send('new',null,'{"title":"t","oneliner":"o","play_url":"javascript:1"}'::jsonb); exception when others then r := 'ERR '||sqlerrm; end; out := out || '13 sub bad url: ' || r || E'\n';
  begin r := public.submission_send('edit','jump','{"note":"n"}'::jsonb); exception when others then r := 'ERR '||sqlerrm; end; out := out || '14 edit: ' || r || E'\n';
  out := out || '15 my_subs: ' || coalesce((select string_agg(s.kind||':'||s.data::text, ' | ') from public.my_submissions() s),'none') || E'\n';
  begin out := out || '16 admin_subs: ' || (select count(*) from public.admin_submissions()) || ' reports: ' || (select count(*) from public.admin_reports()) || ' profiles: ' || (select count(*) from public.admin_profiles()) || E'\n'; exception when others then out := out || '16 ERR ' || sqlerrm || E'\n'; end;
  begin out := out || '17 hide: ' || public.admin_profile_hide('claude_test_1', true) || ' -> get: ' || coalesce(public.profile_get('claude_test_1')::text,'null') || E'\n'; exception when others then out := out || '17 ERR ' || sqlerrm || E'\n'; end;
  out := out || '18 my_feedback rows: ' || (select count(*) from public.my_feedback()) || E'\n';
  raise exception 'ROLLBACK_OK %', E'\n' || out;
end $$;
