-- ════════════════════════════════════════════════════════════════════
--  Migration 002 — configurable weekly allowance, automatic Friday run,
--  password reset by parents, settings audit log.
--  Run once in: Supabase Dashboard → SQL Editor → New query → Run
--  (after schema.sql). Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ── Extensions ──────────────────────────────────────────────────────
create extension if not exists pg_cron  with schema pg_catalog;
create extension if not exists pgcrypto with schema extensions;

-- ── Automatic entries have no parent; mark them explicitly ──────────
alter table public.transactions add column if not exists auto boolean not null default false;
alter table public.transactions alter column entered_by drop not null;
alter table public.transactions drop constraint if exists transactions_who_check;
alter table public.transactions add constraint transactions_who_check check (entered_by is not null or auto);

-- ── Weekly allowance amounts per child ──────────────────────────────
create table if not exists public.allowance (
  child_id    text primary key references public.children(id) on delete cascade,
  spending    numeric(10,2) not null default 5  check (spending between 0 and 1000),
  savings     numeric(10,2) not null default 5  check (savings  between 0 and 1000),
  invest      numeric(10,2) not null default 10 check (invest   between 0 and 1000),
  auto_active boolean not null default true,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);
insert into public.allowance (child_id) select id from public.children on conflict (child_id) do nothing;

-- One row per automatic run (prevents paying twice in the same week)
create table if not exists public.allowance_runs (
  run_date date primary key,
  ran_at   timestamptz not null default now(),
  children int not null
);

-- Append-only log of settings changes (allowance amounts, password resets)
create table if not exists public.settings_log (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  entered_by  uuid not null references public.profiles(id),
  action      text not null,
  details     text not null
);

revoke all on public.allowance, public.allowance_runs, public.settings_log from anon, authenticated, public;
grant select on public.allowance, public.allowance_runs, public.settings_log to authenticated;
alter table public.allowance      enable row level security;
alter table public.allowance_runs enable row level security;
alter table public.settings_log   enable row level security;

drop policy if exists allowance_read      on public.allowance;
drop policy if exists allowance_runs_read on public.allowance_runs;
drop policy if exists settings_log_read   on public.settings_log;
create policy allowance_read      on public.allowance      for select to authenticated using (public.is_admin() or child_id = public.my_child_id());
create policy allowance_runs_read on public.allowance_runs for select to authenticated using (public.is_admin());
create policy settings_log_read   on public.settings_log   for select to authenticated using (public.is_admin());

-- ── _apply gains an "auto" flag (no parent attached) ────────────────
drop function if exists public._apply(uuid, text, text, numeric, text, text, uuid);
create or replace function public._apply(
  p_group uuid, p_child text, p_account text, p_delta numeric,
  p_type text, p_desc text, p_reverses uuid default null, p_auto boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
declare v_cur numeric;
begin
  if not p_auto and auth.uid() is null then raise exception 'אין הרשאה'; end if;

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

  insert into transactions (group_id, child_id, account, amount, type, description, entered_by, reverses_group, auto)
  values (p_group, p_child, p_account, p_delta, p_type, left(p_desc, 120),
          case when p_auto then null else auth.uid() end, p_reverses, p_auto);
end $$;

-- Pay one child's configured allowance. Returns false if all amounts are 0.
create or replace function public._pay_allowance(p_child text, p_auto boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare a allowance; g uuid := gen_random_uuid();
        d text := case when p_auto then '📅 דמי כיס שבועיים (אוטומטי)' else '📅 דמי כיס שבועיים' end;
begin
  insert into allowance (child_id) values (p_child) on conflict (child_id) do nothing;
  select * into a from allowance where child_id = p_child;
  if a.spending + a.savings + a.invest = 0 then return false; end if;
  if a.spending > 0 then perform _apply(g, p_child, 'בזבוזים', a.spending, 'דמי כיס', d, null, p_auto); end if;
  if a.savings  > 0 then perform _apply(g, p_child, 'חסכון',   a.savings,  'דמי כיס', d, null, p_auto); end if;
  if a.invest   > 0 then perform _apply(g, p_child, 'השקעה',   a.invest,   'דמי כיס', d, null, p_auto); end if;
  return true;
end $$;

-- 📅 Manual allowance (parent button). p_child = id or 'all'.
create or replace function public.weekly_allowance(p_child text) returns int
language plpgsql security definer set search_path = public as $$
declare c text; n int := 0;
begin
  perform _require_admin();
  for c in select * from _targets(p_child) loop
    if _pay_allowance(c, false) then n := n + 1; end if;
  end loop;
  if n = 0 then raise exception 'לא הוגדרו דמי כיס'; end if;
  return n;
end $$;

-- 🤖 Automatic Friday run. Called by pg_cron at 08:59 and 09:59 UTC on Fridays;
-- only the call that lands at 11:xx Israel time pays (handles summer/winter time).
create or replace function public.auto_weekly_allowance() returns int
language plpgsql security definer set search_path = public as $$
declare local_ts timestamp := now() at time zone 'Asia/Jerusalem';
        c text; n int := 0; inserted int;
begin
  if extract(isodow from local_ts) <> 5 or extract(hour from local_ts) <> 11 then return 0; end if;
  insert into allowance_runs (run_date, children) values (local_ts::date, 0)
    on conflict (run_date) do nothing;
  get diagnostics inserted = row_count;
  if inserted = 0 then return 0; end if;           -- already ran this Friday
  for c in select a.child_id from allowance a join children ch on ch.id = a.child_id
           where a.auto_active order by ch.sort, ch.id loop
    if _pay_allowance(c, true) then n := n + 1; end if;
  end loop;
  update allowance_runs set children = n where run_date = local_ts::date;
  return n;
end $$;

-- ✏️ Change a child's weekly amounts (p_child = id or 'all').
create or replace function public.set_allowance(
  p_child text, p_spending numeric, p_savings numeric, p_invest numeric, p_auto_active boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare c text; n int := 0; nm text;
begin
  perform _require_admin();
  if p_spending is null or p_savings is null or p_invest is null
     or least(p_spending, p_savings, p_invest) < 0 or greatest(p_spending, p_savings, p_invest) > 1000 then
    raise exception 'סכום לא תקין (0 – 1,000)';
  end if;
  for c in select * from _targets(p_child) loop
    insert into allowance (child_id, spending, savings, invest, auto_active, updated_at, updated_by)
    values (c, round(p_spending, 2), round(p_savings, 2), round(p_invest, 2), coalesce(p_auto_active, true), now(), auth.uid())
    on conflict (child_id) do update set
      spending = excluded.spending, savings = excluded.savings, invest = excluded.invest,
      auto_active = excluded.auto_active, updated_at = now(), updated_by = auth.uid();
    select name into nm from children where id = c;
    insert into settings_log (entered_by, action, details) values (auth.uid(), 'שינוי דמי כיס',
      format('%s: בזבוזים %s · חסכון %s · השקעה %s · אוטומטי %s', nm,
             round(p_spending, 2), round(p_savings, 2), round(p_invest, 2),
             case when coalesce(p_auto_active, true) then 'פעיל' else 'כבוי' end));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'ילד/ה לא נמצא/ה'; end if;
end $$;

-- 🔐 Parent sets a new password for any user (forgotten-password recovery).
create or replace function public.reset_password(p_username text, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_name text;
begin
  perform _require_admin();
  if p_password is null or length(p_password) < 6 or length(p_password) > 72 then
    raise exception 'הסיסמה חייבת להכיל 6–72 תווים';
  end if;
  select id, display_name into v_id, v_name from profiles where username = lower(btrim(p_username));
  if v_id is null then raise exception 'משתמש לא נמצא'; end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_id;
  -- Sign the user out everywhere (except the parent's own current session)
  if v_id <> auth.uid() then
    delete from auth.sessions where user_id = v_id;
  end if;

  insert into settings_log (entered_by, action, details)
  values (auth.uid(), 'איפוס סיסמה', 'סיסמה חדשה ל' || v_name);
end $$;

-- ── Function privileges ─────────────────────────────────────────────
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.is_admin(), public.my_child_id(),
  public.add_expense(text, text, text, numeric, text),
  public.add_deposit(text, text, text, numeric, text),
  public.weekly_allowance(text),
  public.transfer(text, text, text, numeric),
  public.add_interest(text, numeric, text),
  public.set_balances(text, numeric, numeric, numeric),
  public.reverse_entry(uuid),
  public.set_allowance(text, numeric, numeric, numeric, boolean),
  public.reset_password(text, text)
to authenticated;

-- ── Schedule: Fridays 08:59 and 09:59 UTC (= 11:59 Israel, summer/winter) ──
select cron.unschedule(jobid) from cron.job where jobname = 'weekly-allowance';
select cron.schedule('weekly-allowance', '59 8,9 * * 5', 'select public.auto_weekly_allowance()');

-- Check: should list the job
select jobname, schedule, command, active from cron.job where jobname = 'weekly-allowance';
