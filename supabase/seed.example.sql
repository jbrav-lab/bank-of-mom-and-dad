-- ════════════════════════════════════════════════════════════════════
--  Family data seed — TEMPLATE.
--  Copy to seed.local.sql (git-ignored), fill in real names, then run it in the
--  Supabase SQL Editor AFTER schema.sql and AFTER creating the Auth users
--  (Authentication → Users → Add user → "Create new user", tick Auto Confirm):
--     <username>@bomd.local  /  <password you choose>
--  Re-running is safe: it updates names and never touches balances that exist.
-- ════════════════════════════════════════════════════════════════════

-- Children (id = login username, latin letters)
insert into public.children (id, name, avatar, sort) values
  ('kid1', 'Child One', '👦', 1),
  ('kid2', 'Child Two', '👧', 2)
on conflict (id) do update set name = excluded.name, avatar = excluded.avatar, sort = excluded.sort;

-- Every child starts at zero
insert into public.balances (child_id) select id from public.children
on conflict (child_id) do nothing;

-- Link Auth users → profiles (role, display name, which child)
insert into public.profiles (id, username, display_name, role, child_id)
select u.id, v.username, v.display_name, v.role, v.child_id
from (values
  ('parent1', 'Parent One', 'admin', null),
  ('parent2', 'Parent Two', 'admin', null),
  ('kid1',    'Child One',  'child', 'kid1'),
  ('kid2',    'Child Two',  'child', 'kid2')
) as v(username, display_name, role, child_id)
join auth.users u on lower(u.email) = v.username || '@bomd.local'
on conflict (id) do update set
  username = excluded.username, display_name = excluded.display_name,
  role = excluded.role, child_id = excluded.child_id;

-- Check: every row below should have a non-null profile_id
select v.username, p.id as profile_id
from (values ('parent1'), ('parent2'), ('kid1'), ('kid2')) v(username)
left join public.profiles p using (username);
