-- =====================================================================
--  CHS Spin Game — shared database
--  Run this ONCE in Supabase: Dashboard → SQL Editor → New query → Run
--
--  >>> BEFORE RUNNING: change the admin password on the line marked  <<<
--  >>> "CHANGE ME" near the bottom.                                   <<<
--
--  Security model: the game uses the public "anon" key, which anyone can
--  see in the page source. So the tables are fully locked (no direct
--  access) and the game can only call the functions below. Players can
--  never read the list of emails; the admin functions need the password.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tables ----------
create table if not exists public.registrations (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  name        text not null check (length(name) between 1 and 120),
  email       text not null check (length(email) between 3 and 254),
  email_norm  text not null,
  device_id   text check (length(device_id) <= 64),
  prize       text not null default ''
);

-- 1 email = 1 spin, across every device
create unique index if not exists registrations_email_unique
  on public.registrations (email_norm);

-- 1 device = 1 spin (the admin can "release" a device, which nulls it)
create unique index if not exists registrations_device_unique
  on public.registrations (device_id) where device_id is not null;

-- The jackpot can only be held by one player at a time
create unique index if not exists registrations_jackpot_unique
  on public.registrations (prize) where prize = 'Mystery prize (Jackpot)';

create table if not exists public.prize_stock (
  name       text primary key,
  remaining  int  not null default 0 check (remaining >= 0)
);

create table if not exists public.app_secrets (
  key    text primary key,
  value  text not null
);

-- Lock every table: no direct reads/writes with the anon key.
alter table public.registrations enable row level security;
alter table public.prize_stock  enable row level security;
alter table public.app_secrets  enable row level security;
revoke all on public.registrations, public.prize_stock, public.app_secrets from anon, authenticated;

-- ---------- Player functions ----------

-- Has this email or device already played? → 'email' | 'device' | null
create or replace function public.check_player(p_email text, p_device text)
returns text language sql security definer set search_path = public stable as $$
  select case
    when exists (select 1 from registrations where email_norm = lower(trim(p_email))) then 'email'
    when p_device is not null and exists (select 1 from registrations where device_id = p_device) then 'device'
    else null end;
$$;

-- Register a player. Only works after the player has verified their email with
-- the 6-digit code (they then hold a Supabase session for that exact email).
-- Fails with a 409 if the email or device was already used.
create or replace function public.register_player(p_name text, p_email text, p_device text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if coalesce(lower(auth.jwt() ->> 'email'), '') <> lower(trim(p_email)) then
    raise exception 'email not verified' using errcode = '42501';
  end if;
  insert into registrations (name, email, email_norm, device_id)
  values (trim(p_name), trim(p_email), lower(trim(p_email)), p_device)
  returning id into new_id;
  return new_id;
end $$;

-- Record a prize. Only works once per registration (prize must still be empty).
create or replace function public.set_prize(p_id uuid, p_prize text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update registrations set prize = p_prize where id = p_id and prize = '';
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.jackpot_claimed()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from registrations where prize = 'Mystery prize (Jackpot)');
$$;

create or replace function public.list_stock()
returns table (name text, remaining int)
language sql security definer set search_path = public stable as $$
  select name, remaining from prize_stock order by name;
$$;

-- Atomic stock decrement: returns true if a prize was taken
create or replace function public.decrement_stock(prize_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update prize_stock set remaining = remaining - 1
   where name = prize_name and remaining > 0;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ---------- Admin functions (password checked on the server) ----------

create or replace function public.is_admin(p_pw text)
returns boolean language sql security definer set search_path = public, extensions stable as $$
  select exists (
    select 1 from app_secrets
     where key = 'admin_password_hash' and value = crypt(p_pw, value)
  );
$$;

create or replace function public.admin_list(p_pw text)
returns setof registrations language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_pw) then raise exception 'not authorised' using errcode = '42501'; end if;
  return query select * from registrations order by created_at desc;
end $$;

create or replace function public.admin_clear(p_pw text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_pw) then raise exception 'not authorised' using errcode = '42501'; end if;
  delete from registrations where true;
end $$;

create or replace function public.admin_reset_jackpot(p_pw text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_pw) then raise exception 'not authorised' using errcode = '42501'; end if;
  update registrations set prize = '' where prize = 'Mystery prize (Jackpot)';
end $$;

create or replace function public.admin_release_device(p_pw text, p_device text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_pw) then raise exception 'not authorised' using errcode = '42501'; end if;
  update registrations set device_id = null where device_id = p_device;
end $$;

create or replace function public.admin_set_stock(p_pw text, p_name text, p_remaining int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(p_pw) then raise exception 'not authorised' using errcode = '42501'; end if;
  insert into prize_stock (name, remaining) values (p_name, greatest(p_remaining, 0))
  on conflict (name) do update set remaining = excluded.remaining;
end $$;

-- Only these functions are callable from the game.
-- "authenticated" = a player who has verified their email code.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.register_player(text, text, text) to authenticated;
grant execute on function
  public.check_player(text, text),
  public.set_prize(uuid, text),
  public.jackpot_claimed(),
  public.list_stock(),
  public.decrement_stock(text),
  public.is_admin(text),
  public.admin_list(text),
  public.admin_clear(text),
  public.admin_reset_jackpot(text),
  public.admin_release_device(text, text),
  public.admin_set_stock(text, text, int)
to anon, authenticated;

-- ---------- First-time admin setup (from the /admin page) ----------
-- Has an admin password been set yet?
create or replace function public.admin_password_set()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from app_secrets where key = 'admin_password_hash');
$$;

-- Set the admin password ONCE. Only works while no password exists;
-- after that it always returns false (change it later via SQL).
create or replace function public.admin_setup(p_pw text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if p_pw is null or length(p_pw) < 8 then
    raise exception 'password must be at least 8 characters' using errcode = '22023';
  end if;
  insert into app_secrets (key, value)
  values ('admin_password_hash', crypt(p_pw, gen_salt('bf')))
  on conflict (key) do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;

revoke execute on function public.admin_password_set(), public.admin_setup(text) from public;
grant execute on function public.admin_password_set(), public.admin_setup(text) to anon, authenticated;

-- ---------- Starting data ----------
insert into public.prize_stock (name, remaining) values
  ('Tracks Fidget', 60), ('Controller Fidget', 80), ('Ballpen', 100), ('Notebook', 100)
on conflict (name) do nothing;

-- Admin password (stored hashed). Optional: you can instead set it once
-- from the /admin page ("Create admin password").                         ▼▼▼ CHANGE ME ▼▼▼
insert into public.app_secrets (key, value)
values ('admin_password_hash', extensions.crypt('change-this-password', extensions.gen_salt('bf')))
on conflict (key) do update set value = excluded.value;
