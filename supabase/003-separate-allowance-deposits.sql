-- ════════════════════════════════════════════════════════════════════
--  Migration 003 — weekly allowance = three separate deposits.
--  Undoing one account's allowance (e.g. spending) no longer undoes the
--  other two. Run once in Supabase → SQL Editor (after 002). Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- Each account gets its own group id, so each can be undone on its own.
create or replace function public._pay_allowance(p_child text, p_auto boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare a allowance;
        d text := case when p_auto then '📅 דמי כיס שבועיים (אוטומטי)' else '📅 דמי כיס שבועיים' end;
begin
  insert into allowance (child_id) values (p_child) on conflict (child_id) do nothing;
  select * into a from allowance where child_id = p_child;
  if a.spending + a.savings + a.invest = 0 then return false; end if;
  if a.spending > 0 then perform _apply(gen_random_uuid(), p_child, 'בזבוזים', a.spending, 'דמי כיס', d, null, p_auto); end if;
  if a.savings  > 0 then perform _apply(gen_random_uuid(), p_child, 'חסכון',   a.savings,  'דמי כיס', d, null, p_auto); end if;
  if a.invest   > 0 then perform _apply(gen_random_uuid(), p_child, 'השקעה',   a.invest,   'דמי כיס', d, null, p_auto); end if;
  return true;
end $$;
revoke execute on function public._pay_allowance(text, boolean) from public, anon, authenticated;

-- Split allowance entries that were already recorded together, so they can
-- also be undone one at a time. Only the internal grouping id changes:
-- amounts, accounts, dates and who entered them are untouched.
-- Groups that were already undone are left exactly as they are.
update public.transactions t
   set group_id = gen_random_uuid()
 where t.type = 'דמי כיס'
   and t.reverses_group is null
   and not exists (select 1 from public.transactions r where r.reverses_group = t.group_id)
   and (select count(*) from public.transactions s where s.group_id = t.group_id) > 1;

-- Check: should return 0 (no allowance group with more than one entry left, except already-undone ones)
select count(*) as grouped_allowance_left
from (select group_id from public.transactions
      where type = 'דמי כיס' and reverses_group is null
      group by group_id having count(*) > 1) g
where not exists (select 1 from public.transactions r where r.reverses_group = g.group_id);
