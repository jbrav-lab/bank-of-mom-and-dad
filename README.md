# 🏦 בנק אמא ואבא

A small family app for tracking the kids' pocket money (spending, savings and investment accounts). It's built mobile-first, so a parent can log an expense or an allowance from a phone in a few taps.

- **Front end:** one static page (`index.html`) hosted on GitHub Pages.
- **Back end:** [Supabase](https://supabase.com) free tier (Postgres, Auth and Row Level Security).
- **Login:** a username and password (`<username>@bomd.local` in Supabase Auth; no real email is used).

## Security model
- Parents (role `admin`) can see and change everything. A child can only **see** their own accounts.
- The tables can't be written to directly. Every change goes through a server function (`supabase/schema.sql`) that checks the user is a parent, validates the amount, updates the balance and appends to the audit log, all in one transaction.
- The audit log is **append-only**. Every entry records who made it (from the login session) and when (server time). Mistakes are fixed with "↩️ ביטול" (undo), which adds a reversing entry. Nothing is ever edited or deleted.
- The Supabase *publishable* key in `index.html` is meant to be public. The data is protected by RLS.

## One-time setup
1. **Supabase → SQL Editor:** run `supabase/schema.sql`, then `supabase/002-allowance-passwords.sql`, then `supabase/003-separate-allowance-deposits.sql`, then `supabase/004-cancellation-note-visibility.sql`.
2. **Supabase → Authentication → Sign In / Providers → Email:** turn off *Confirm email*. You can also turn off *Allow new users to sign up*, because users are created by hand.
3. **Supabase → Authentication → Users → Add user → Create new user:** create one user per person, such as `parent1@bomd.local`, with *Auto Confirm User* ticked.
4. Copy `supabase/seed.example.sql` to `supabase/seed.local.sql`, which git ignores. Fill in the real names and usernames, then run it in the SQL Editor. Its last query should show a `profile_id` for every user.
5. **GitHub → Settings → Pages:** Source *Deploy from a branch*, branch `main`, folder `/ (root)`.
6. **GitHub → Actions → "Supabase keep-alive" → Run workflow** once, to check that it works. After that it runs twice a week so the free project doesn't pause.

## Everyday use
- Open the Pages URL on your phone and use **Add to Home Screen**.
- **Parents:** tap a child, then **➖ הוצאה** (expense) or **➕ הפקדה / דמי כיס** (deposit or allowance).
- **Changing a password:** everyone can change their own (🔑). A parent can set a new password for anyone who forgot theirs under ⚙️ הגדרות.
- **Weekly allowance:** the amounts are set per child under ⚙️ הגדרות. It is deposited automatically every Friday at 11:59 Israel time by a `pg_cron` job in Supabase. Each child has an on/off switch.

## Local preview
```bash
npx serve .
```
