-- ════════════════════════════════════════════════════════════════════
--  Migration 004 — cancellation note + "show to child" choice.
--  Run once in Supabase → SQL Editor (after 003). Safe to re-run.
--
--  • A cancellation (reverse_entry) can carry a note explaining why.
--  • A parent can hide a cancellation from the child. Then the child sees
--    neither the original entry nor its cancellation (the balance is
--    correct either way). Parents always see everything.
-- ════════════════════════════════════════════════════════════════════

alter table public.transactions add column if not exists note text;
alter table public.transactions drop constraint if exists transactions_note_check;
alter table public.transactions add constraint transactions_note_check check (note is null or length(note) <= 200);
alter table public.transactions add column if not exists hidden_from_child boolean not null default false;

-- Was this group cancelled with "hide from child"?
create or replace function public._group_hidden(p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from transactions where reverses_group = p_group and hidden_from_child);
$$;

drop policy if exists transactions_read on public.transactions;
create policy transactions_read on public.transactions for select to authenticated
  using (
    public.is_admin()
    or (child_id = public.my_child_id()
        and not hidden_from_child
        and not public._group_hidden(group_id))
  );

-- ↩️ Undo with optional note and visibility choice
drop function if exists public.reverse_entry(uuid);
create or replace function public.reverse_entry(
  p_group uuid, p_note text default null, p_show_child boolean default true
) returns void
language plpgsql security definer set search_path = public as $$
declare r transactions; g uuid := gen_random_uuid(); n int := 0;
        v_note text := nullif(_txt(p_note, 200), '');
begin
  perform _require_admin();
  perform pg_advisory_xact_lock(hashtext(p_group::text));
  if exists (select 1 from transactions where reverses_group = p_group) then
    raise exception 'הפעולה כבר בוטלה';
  end if;
  if exists (select 1 from transactions where group_id = p_group and reverses_group is not null) then
    raise exception 'אי אפשר לבטל ביטול';
  end if;
  for r in select * from transactions where group_id = p_group order by id loop
    perform _apply(g, r.child_id, r.account, -r.amount, 'ביטול',
                   '↩️ ביטול: ' || r.description, p_group);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'פעולה לא נמצאה'; end if;
  -- Attach note/visibility to the cancellation rows created just above
  update transactions
     set note = v_note, hidden_from_child = not coalesce(p_show_child, true)
   where group_id = g;
end $$;

revoke execute on function public._group_hidden(uuid) from public, anon;
grant  execute on function public._group_hidden(uuid) to authenticated;   -- used by the RLS policy
revoke execute on function public.reverse_entry(uuid, text, boolean) from public, anon;
grant  execute on function public.reverse_entry(uuid, text, boolean) to authenticated;
