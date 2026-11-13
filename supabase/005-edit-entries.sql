-- ════════════════════════════════════════════════════════════════════
--  Migration 005 — parents can edit an entry (not only cancel it).
--  Run once in Supabase → SQL Editor (after 004). Safe to re-run.
--
--  The audit log stays append-only:
--  • The original transactions row is never changed (keeps its original
--    date, type, amount and who created it).
--  • Every edit appends a row to transaction_edits with the previous and new
--    values, who edited, when, and an optional reason.
--  • transactions_current shows each entry with its latest values.
--  • Balances are corrected by the difference, in the same DB transaction.
-- ════════════════════════════════════════════════════════════════════

create table if not exists public.transaction_edits (
  id               bigint generated always as identity primary key,
  tx_id            bigint not null references public.transactions(id),
  edited_at        timestamptz not null default now(),
  edited_by        uuid not null references public.profiles(id),
  prev_account     text not null,
  prev_amount      numeric(10,2) not null,
  prev_type        text not null,
  prev_description text not null,
  account          text not null check (account in ('בזבוזים', 'חסכון', 'השקעה')),
  amount           numeric(10,2) not null check (amount <> 0),
  type             text not null check (length(type) between 1 and 40),
  description      text not null check (length(description) between 1 and 120),
  note             text check (note is null or length(note) <= 200)
);
create index if not exists transaction_edits_tx on public.transaction_edits (tx_id, id);

revoke all on public.transaction_edits from anon, authenticated, public;
grant select on public.transaction_edits to authenticated;
alter table public.transaction_edits enable row level security;
drop policy if exists transaction_edits_read on public.transaction_edits;
-- Parents: all. Child: edits of entries they are allowed to see (RLS on transactions applies in the subquery).
create policy transaction_edits_read on public.transaction_edits for select to authenticated
  using (public.is_admin() or exists (select 1 from public.transactions t where t.id = tx_id));

-- Each entry with its latest values. security_invoker → the caller's RLS applies.
drop view if exists public.transactions_current;
create view public.transactions_current with (security_invoker = true) as
select t.id, t.group_id, t.child_id,
       coalesce(e.account, t.account)         as account,
       coalesce(e.amount, t.amount)           as amount,
       coalesce(e.type, t.type)               as type,
       coalesce(e.description, t.description) as description,
       t.note, t.hidden_from_child, t.created_at, t.reverses_group, t.auto, t.entered_by,
       e.edited_by as last_edited_by,
       e.edited_at as last_edited_at,
       coalesce(ec.n, 0)::int as edit_count
from public.transactions t
left join lateral (
  select x.* from public.transaction_edits x where x.tx_id = t.id order by x.id desc limit 1
) e on true
left join lateral (
  select count(*) as n from public.transaction_edits x where x.tx_id = t.id
) ec on true;

revoke all on public.transactions_current from anon, authenticated, public;
grant select on public.transactions_current to authenticated;

-- Move money in one account without writing a transaction row (used by edits).
create or replace function public._move(p_child text, p_account text, p_delta numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_cur numeric;
begin
  if p_delta = 0 then return; end if;
  select case p_account when 'בזבוזים' then spending
                        when 'חסכון'   then savings
                        when 'השקעה'   then invest end
    into v_cur from balances where child_id = p_child for update;
  if not found then raise exception 'ילד/ה לא נמצא/ה'; end if;
  if v_cur is null then raise exception 'חשבון לא תקין'; end if;
  if v_cur + p_delta < 0 then raise exception 'אין מספיק כסף ב%', p_account; end if;
  update balances set
    spending = spending + case when p_account = 'בזבוזים' then p_delta else 0 end,
    savings  = savings  + case when p_account = 'חסכון'   then p_delta else 0 end,
    invest   = invest   + case when p_account = 'השקעה'   then p_delta else 0 end
  where child_id = p_child;
end $$;

-- ✏️ Edit an entry: amount (sign kept), account, type, description + reason.
create or replace function public.edit_entry(
  p_tx bigint, p_account text, p_amount numeric, p_type text, p_desc text, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare c record; v_amt numeric;
        v_type text := _txt(p_type, 40); v_desc text := _txt(p_desc, 120);
        v_note text := nullif(_txt(p_note, 200), '');
begin
  perform _require_admin();
  select * into c from transactions_current where id = p_tx;
  if not found then raise exception 'פעולה לא נמצאה'; end if;
  perform pg_advisory_xact_lock(hashtext(c.group_id::text));

  if c.reverses_group is not null then raise exception 'אי אפשר לערוך ביטול'; end if;
  if c.type = 'העברה' then raise exception 'אי אפשר לערוך העברה — בטלו אותה ובצעו מחדש'; end if;
  if exists (select 1 from transactions where reverses_group = c.group_id) then
    raise exception 'הפעולה בוטלה ולכן אי אפשר לערוך אותה';
  end if;
  if p_account is null or p_account not in ('בזבוזים', 'חסכון', 'השקעה') then raise exception 'חשבון לא תקין'; end if;
  if v_type = '' then raise exception 'חובה לבחור סוג'; end if;
  if v_desc = '' then raise exception 'חובה להזין תיאור'; end if;

  v_amt := _amt(p_amount) * sign(c.amount);   -- expenses stay negative, deposits positive
  if v_amt = c.amount and p_account = c.account and v_type = c.type and v_desc = c.description then
    raise exception 'לא השתנה דבר';
  end if;

  -- Fix balances: remove the old effect, apply the new one (credit first to avoid false "not enough money")
  if p_account = c.account then
    perform _move(c.child_id, c.account, v_amt - c.amount);
  elsif v_amt > 0 then
    perform _move(c.child_id, p_account, v_amt);
    perform _move(c.child_id, c.account, -c.amount);
  else
    perform _move(c.child_id, c.account, -c.amount);
    perform _move(c.child_id, p_account, v_amt);
  end if;

  insert into transaction_edits (tx_id, edited_by, prev_account, prev_amount, prev_type, prev_description,
                                 account, amount, type, description, note)
  values (p_tx, auth.uid(), c.account, c.amount, c.type, c.description,
          p_account, v_amt, v_type, v_desc, v_note);
end $$;

-- ↩️ Cancel now reverses the entry's CURRENT (possibly edited) values.
create or replace function public.reverse_entry(
  p_group uuid, p_note text default null, p_show_child boolean default true
) returns void
language plpgsql security definer set search_path = public as $$
declare r record; g uuid := gen_random_uuid(); n int := 0;
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
  for r in select * from transactions_current where group_id = p_group order by id loop
    perform _apply(g, r.child_id, r.account, -r.amount, 'ביטול',
                   '↩️ ביטול: ' || r.description, p_group);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'פעולה לא נמצאה'; end if;
  update transactions
     set note = v_note, hidden_from_child = not coalesce(p_show_child, true)
   where group_id = g;
end $$;

revoke execute on function public._move(text, text, numeric) from public, anon, authenticated;
revoke execute on function public.edit_entry(bigint, text, numeric, text, text, text) from public, anon;
grant  execute on function public.edit_entry(bigint, text, numeric, text, text, text) to authenticated;
revoke execute on function public.reverse_entry(uuid, text, boolean) from public, anon;
grant  execute on function public.reverse_entry(uuid, text, boolean) to authenticated;
