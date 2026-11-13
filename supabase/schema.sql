-- ════════════════════════════════════════════════════════════════════
--  Bank of Mom and Dad — Supabase schema
--  Run once in: Supabase Dashboard → SQL Editor → New query → Run
--  Safe to re-run (drops and recreates functions/policies; tables use IF NOT EXISTS).
--
--  Security model
--  • Login = Supabase Auth email+password (username@bomd.local, no real email).
--  • Parents (role 'admin') read everything; a child reads only their own rows.
--  • Nobody writes to tables directly. All money movement goes through the
--    SECURITY DEFINER functions below, which check is_admin(), validate input,
--    update the balance and append to the audit log in ONE transaction.
--  • transactions is append-only: no UPDATE/DELETE grants and no policies for
--    them. Mistakes are fixed with reverse_entry(), which appends a reversal.
--  • entered_by is always auth.uid() — taken from the session, never the client.
-- ════════════════════════════════════════════════════════════════════

-- ── TABLES ──────────────────────────────────────────────────────────
create table if not exists public.children (
  id      text primary key check (id ~ '^[a-z0-9_]{1,32}$'),
  name    text not null,
  avatar  text not null default '🙂',
  sort    int  not null default 0
);

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text not null unique,
  display_name  text not null,
  role          text not null check (role in ('admin', 'child')),
  child_id      text references public.children(id),
  check ((role = 'child') = (child_id is not null))
);

create table if not exists public.balances (
  child_id  text primary key references public.children(id) on delete cascade,
  spending  numeric(10,2) not null default 0 check (spending >= 0),  -- בזבוזים
  savings   numeric(10,2) not null default 0 check (savings  >= 0),  -- חסכון
  invest    numeric(10,2) not null default 0 check (invest   >= 0)   -- השקעה
);

create table if not exists public.transactions (
  id              bigint generated always as identity primary key,
  group_id        uuid not null,                  -- rows created by one action for one child
  child_id        text not null references public.children(id),
  account         text not null check (account in ('בזבוזים', 'חסכון', 'השקעה')),
  amount          numeric(10,2) not null check (amount <> 0),
  type            text not null check (length(type) between 1 and 40),
  description     text not null check (length(description) between 1 and 120),
  created_at      timestamptz not null default now(),
  entered_by      uuid not null references public.profiles(id),
  reverses_group  uuid                            -- set on reversal rows
);
create index if not exists transactions_child_created on public.transactions (child_id, created_at desc, id desc);
create index if not exists transactions_created       on public.transactions (created_at desc, id desc);
create index if not exists transactions_group         on public.transactions (group_id);
create index if not exists transactions_reverses      on public.transactions (reverses_group) where reverses_group is not null;

-- ── PRIVILEGES: read-only for logged-in users, nothing for anon ─────
revoke all on public.children, public.profiles, public.balances, public.transactions from anon, authenticated, public;
grant select on public.children, public.profiles, public.balances, public.transactions to authenticated;

alter table public.children     enable row level security;
alter table public.profiles     enable row level security;
alter table public.balances     enable row level security;
alter table public.transactions enable row level security;

-- ── HELPERS used by policies ────────────────────────────────────────
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.my_child_id() returns text
language sql stable security definer set search_path = public as $$
  select child_id from profiles where id = auth.uid();
$$;

-- ── ROW LEVEL SECURITY (SELECT only; no write policies exist) ───────
drop policy if exists children_read     on public.children;
drop policy if exists profiles_read     on public.profiles;
drop policy if exists balances_read     on public.balances;
drop policy if exists transactions_read on public.transactions;

create policy children_read on public.children for select to authenticated
  using (public.is_admin() or id = public.my_child_id());
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy balances_read on public.balances for select to authenticated
  using (public.is_admin() or child_id = public.my_child_id());
create policy transactions_read on public.transactions for select to authenticated
  using (public.is_admin() or child_id = public.my_child_id());

-- ── INTERNAL HELPERS (not callable from the API) ────────────────────
create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'אין הרשאה לפעולה זו'; end if;
end $$;

-- Validate + round a positive amount (0.01 – 99,999).
create or replace function public._amt(p numeric) returns numeric
language plpgsql immutable as $$
begin
  if p is null or p <= 0 or p > 99999 then
    raise exception 'סכום לא תקין (0.01 – 99,999)';
  end if;
  return round(p, 2);
end $$;

create or replace function public._txt(p text, maxlen int default 100) returns text
language sql immutable as $$ select left(btrim(coalesce(p, '')), maxlen) $$;

-- Apply one signed movement to one account and log it. Locks the balance row.
create or replace function public._apply(
  p_group uuid, p_child text, p_account text, p_delta numeric,
  p_type text, p_desc text, p_reverses uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_cur numeric;
begin
  select case p_account when 'בזבוזים' then spending
                        when 'חסכון'   then savings
                        when 'השקעה'   then invest end
    into v_cur
    from balances where child_id = p_child for update;

  if not found then raise exception 'ילד/ה לא נמצא/ה'; end if;
  if v_cur is null then raise exception 'חשבון לא תקין'; end if;
  if v_cur + p_delta < 0 then raise exception 'אין מספיק כסף ב%', p_account; end if;

  update balances set
    spending = spending + case when p_account = 'בזבוזים' then p_delta else 0 end,
    savings  = savings  + case when p_account = 'חסכון'   then p_delta else 0 end,
    invest   = invest   + case when p_account = 'השקעה'   then p_delta else 0 end
  where child_id = p_child;

  insert into transactions (group_id, child_id, account, amount, type, description, entered_by, reverses_group)
  values (p_group, p_child, p_account, p_delta, p_type, left(p_desc, 120), auth.uid(), p_reverses);
end $$;

-- Resolve 'all' or a single child id into a list of child ids.
create or replace function public._targets(p_child text) returns setof text
language sql stable security definer set search_path = public as $$
  select id from children where p_child = 'all' or id = p_child order by sort, id;
$$;

-- ── PUBLIC API (called with supabase.rpc) ───────────────────────────

-- ➖ Expense / purchase
create or replace function public.add_expense(
  p_child text, p_account text, p_type text, p_amount numeric, p_desc text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_desc text := _txt(p_desc); v_type text := _txt(p_type, 40);
begin
  perform _require_admin();
  if v_type = '' then raise exception 'חובה לבחור סוג הוצאה'; end if;
  if v_desc = '' then raise exception 'חובה להזין תיאור'; end if;
  perform _apply(gen_random_uuid(), p_child, p_account, -_amt(p_amount), v_type, '🛒 ' || v_desc);
end $$;

-- ➕ Special deposit (gift, birthday, holiday…)
create or replace function public.add_deposit(
  p_child text, p_account text, p_occasion text, p_amount numeric, p_desc text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_occ text := _txt(p_occasion, 40); v_desc text := _txt(p_desc);
begin
  perform _require_admin();
  if v_occ = '' then raise exception 'חובה לבחור סוג הפקדה'; end if;
  perform _apply(gen_random_uuid(), p_child, p_account, _amt(p_amount), v_occ,
                 '🎁 ' || coalesce(nullif(v_desc, ''), v_occ));
end $$;

-- 📅 Weekly allowance: 5 spending, 5 savings, 10 invest. p_child = id or 'all'.
create or replace function public.weekly_allowance(p_child text) returns int
language plpgsql security definer set search_path = public as $$
declare c text; g uuid; n int := 0;
begin
  perform _require_admin();
  for c in select * from _targets(p_child) loop
    g := gen_random_uuid();
    perform _apply(g, c, 'בזבוזים', 5,  'דמי כיס', '📅 דמי כיס שבועיים');
    perform _apply(g, c, 'חסכון',   5,  'דמי כיס', '📅 דמי כיס שבועיים');
    perform _apply(g, c, 'השקעה',   10, 'דמי כיס', '📅 דמי כיס שבועיים');
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'ילד/ה לא נמצא/ה'; end if;
  return n;
end $$;

-- 🔄 Transfer between a child's own accounts
create or replace function public.transfer(
  p_child text, p_from text, p_to text, p_amount numeric
) returns void
language plpgsql security definer set search_path = public as $$
declare g uuid := gen_random_uuid(); v numeric := _amt(p_amount);
begin
  perform _require_admin();
  if p_from = p_to then raise exception 'החשבונות חייבים להיות שונים'; end if;
  perform _apply(g, p_child, p_from, -v, 'העברה', '🔄 העברה → ' || p_to);
  perform _apply(g, p_child, p_to,    v, 'העברה', '🔄 העברה ← ' || p_from);
end $$;

-- 📈 Interest into the investment account. p_child = id or 'all'.
create or replace function public.add_interest(
  p_child text, p_amount numeric, p_note text
) returns int
language plpgsql security definer set search_path = public as $$
declare c text; n int := 0; v numeric := _amt(p_amount);
        d text := '📈 ' || coalesce(nullif(_txt(p_note), ''), 'ריבית');
begin
  perform _require_admin();
  for c in select * from _targets(p_child) loop
    perform _apply(gen_random_uuid(), c, 'השקעה', v, 'ריבית', d);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'ילד/ה לא נמצא/ה'; end if;
  return n;
end $$;

-- ✏️ Set balances to exact values. Logs the difference per account.
create or replace function public.set_balances(
  p_child text, p_spending numeric, p_savings numeric, p_invest numeric
) returns void
language plpgsql security definer set search_path = public as $$
declare b balances; g uuid := gen_random_uuid(); changed boolean := false;
begin
  perform _require_admin();
  if least(p_spending, p_savings, p_invest) < 0 or greatest(p_spending, p_savings, p_invest) > 99999
     or p_spending is null or p_savings is null or p_invest is null then
    raise exception 'יתרה לא תקינה (0 – 99,999)';
  end if;
  select * into b from balances where child_id = p_child for update;
  if not found then raise exception 'ילד/ה לא נמצא/ה'; end if;

  if round(p_spending, 2) <> b.spending then
    perform _apply(g, p_child, 'בזבוזים', round(p_spending, 2) - b.spending, 'תיקון יתרה', '✏️ תיקון יתרה'); changed := true; end if;
  if round(p_savings, 2) <> b.savings then
    perform _apply(g, p_child, 'חסכון',   round(p_savings, 2)  - b.savings,  'תיקון יתרה', '✏️ תיקון יתרה'); changed := true; end if;
  if round(p_invest, 2) <> b.invest then
    perform _apply(g, p_child, 'השקעה',   round(p_invest, 2)   - b.invest,   'תיקון יתרה', '✏️ תיקון יתרה'); changed := true; end if;
  if not changed then raise exception 'לא השתנה דבר'; end if;
end $$;

-- ↩️ Undo an action by appending opposite entries (the log itself is never edited).
create or replace function public.reverse_entry(p_group uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r transactions; g uuid := gen_random_uuid(); n int := 0;
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
end $$;

-- ── FUNCTION PRIVILEGES ─────────────────────────────────────────────
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.is_admin(), public.my_child_id(),
  public.add_expense(text, text, text, numeric, text),
  public.add_deposit(text, text, text, numeric, text),
  public.weekly_allowance(text),
  public.transfer(text, text, text, numeric),
  public.add_interest(text, numeric, text),
  public.set_balances(text, numeric, numeric, numeric),
  public.reverse_entry(uuid)
to authenticated;

-- Keep future functions private by default too.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
