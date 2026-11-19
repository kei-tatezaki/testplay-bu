-- 010: 管理者がいるかどうかだけを、だれでも確かめられるようにする
-- （admin.html で、管理者ではない人に「このアカウントを管理者にする」を出さないため）
-- 返すのは true / false だけ。だれが管理者かは分からない。

create or replace function public.admin_exists() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins);
$$;

revoke all on function public.admin_exists() from public;
grant execute on function public.admin_exists() to anon, authenticated;
