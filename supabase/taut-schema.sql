-- =====================================================================
-- TAUT: access-controlled backend for Supabase
-- Run this WHOLE file once in Supabase -> SQL Editor (as the default
-- "postgres" user). Safe to re-run.
--
-- Model: anyone may create an account. An account sees NOTHING until the
-- family owner approves it (as viewer / editor). Every rule is enforced
-- here in the database, not in the app.
-- =====================================================================

-- ---------- types ----------------------------------------------------
do $$ begin
  create type public.member_role as enum ('owner', 'editor', 'viewer');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.member_status as enum ('pending', 'approved', 'rejected', 'revoked');
exception when duplicate_object then null; end $$;

-- ---------- tables ---------------------------------------------------
create table if not exists public.families (
  id         uuid primary key default gen_random_uuid(),
  name       text not null default 'Keluarga',
  created_at timestamptz not null default now()
);

-- one row per account; email is copied from auth.users (clients cannot edit it)
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text not null,
  full_name  text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.memberships (
  family_id    uuid not null references public.families (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  status       public.member_status not null default 'pending',
  role         public.member_role,                 -- only set while approved
  note         text not null default '',           -- "how are you related?"
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references public.profiles (id) on delete set null,
  primary key (family_id, user_id),
  constraint role_only_when_approved check ((status = 'approved') = (role is not null))
);

create table if not exists public.trees (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families (id) on delete cascade,
  name       text not null default 'Salasilah Keluarga',
  data       jsonb not null default '{}'::jsonb,
  version    integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
create index if not exists trees_family_idx on public.trees (family_id);

create table if not exists public.memories (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families (id) on delete cascade,
  image_path  text not null,                       -- path in bucket 'memories': <family_id>/<file>
  caption     text not null default '',
  year        integer,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists memories_family_idx on public.memories (family_id);

create table if not exists public.audit_log (
  id        bigint generated always as identity primary key,
  family_id uuid not null references public.families (id) on delete cascade,
  actor     uuid references public.profiles (id) on delete set null,
  action    text not null,
  target    uuid references public.profiles (id) on delete set null,
  detail    jsonb not null default '{}'::jsonb,
  at        timestamptz not null default now()
);

-- ---------- permission helpers (never return NULL) -------------------
create or replace function public.is_member(f uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.memberships
                 where family_id = f and user_id = auth.uid() and status = 'approved');
$$;

create or replace function public.can_edit(f uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.memberships
                 where family_id = f and user_id = auth.uid()
                   and status = 'approved' and role in ('owner', 'editor'));
$$;

create or replace function public.is_owner(f uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.memberships
                 where family_id = f and user_id = auth.uid()
                   and status = 'approved' and role = 'owner');
$$;

-- ---------- new account -> profile + pending request -----------------
-- The pending request is created only once the email is CONFIRMED, so a
-- stranger cannot put your uncle's address in your pending list.
create or replace function public.handle_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do update set email = excluded.email;

  if new.email_confirmed_at is not null then
    insert into public.memberships (family_id, user_id)
    select id, new.id from public.families order by created_at limit 1
    on conflict do nothing;                 -- rejected people stay rejected
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_change on auth.users;
create trigger on_auth_user_change
  after insert or update of email, email_confirmed_at on auth.users
  for each row execute function public.handle_auth_user();

-- ---------- row level security ---------------------------------------
alter table public.families    enable row level security;
alter table public.profiles    enable row level security;
alter table public.memberships enable row level security;
alter table public.trees       enable row level security;
alter table public.memories    enable row level security;
alter table public.audit_log   enable row level security;

drop policy if exists families_read    on public.families;
drop policy if exists profiles_read    on public.profiles;
drop policy if exists memberships_read on public.memberships;
drop policy if exists trees_read       on public.trees;
drop policy if exists trees_insert     on public.trees;
drop policy if exists trees_delete     on public.trees;
drop policy if exists memories_read    on public.memories;
drop policy if exists memories_insert  on public.memories;
drop policy if exists memories_update  on public.memories;
drop policy if exists memories_delete  on public.memories;
drop policy if exists audit_read       on public.audit_log;

create policy families_read on public.families for select to authenticated
  using (public.is_member(id));

create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid()
         or exists (select 1 from public.memberships m
                    where m.user_id = profiles.id and public.is_owner(m.family_id)));

create policy memberships_read on public.memberships for select to authenticated
  using (user_id = auth.uid() or public.is_owner(family_id));

create policy trees_read   on public.trees for select to authenticated using (public.is_member(family_id));
create policy trees_insert on public.trees for insert to authenticated with check (public.can_edit(family_id));
create policy trees_delete on public.trees for delete to authenticated using (public.is_owner(family_id));
-- trees are UPDATED only through save_tree() below (optimistic locking)

create policy memories_read   on public.memories for select to authenticated using (public.is_member(family_id));
create policy memories_insert on public.memories for insert to authenticated with check (public.can_edit(family_id));
create policy memories_update on public.memories for update to authenticated
  using (public.can_edit(family_id)) with check (public.can_edit(family_id));
create policy memories_delete on public.memories for delete to authenticated using (public.can_edit(family_id));

create policy audit_read on public.audit_log for select to authenticated using (public.is_owner(family_id));

-- defence in depth: nothing for anonymous visitors, no direct writes to
-- the access tables (they change only through the functions below)
revoke all on all tables in schema public from anon;
revoke insert, update, delete on public.families, public.profiles, public.memberships, public.audit_log from authenticated;
revoke update on public.trees from authenticated;

-- ---------- owner actions (the only way access changes) --------------
create or replace function public._guard_last_owner(f uuid, u uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.memberships
             where family_id = f and user_id = u and status = 'approved' and role = 'owner')
     and (select count(*) from public.memberships
          where family_id = f and status = 'approved' and role = 'owner') <= 1 then
    raise exception 'Cannot remove or demote the last owner' using errcode = 'P0001';
  end if;
end $$;

create or replace function public.approve_member(p_family uuid, p_user uuid, p_role public.member_role)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner(p_family) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.memberships
     set status = 'approved', role = p_role, decided_at = now(), decided_by = auth.uid()
   where family_id = p_family and user_id = p_user and status in ('pending', 'rejected', 'revoked');
  if not found then raise exception 'No such pending request' using errcode = 'P0002'; end if;
  insert into public.audit_log (family_id, actor, action, target, detail)
  values (p_family, auth.uid(), 'approve', p_user, jsonb_build_object('role', p_role));
end $$;

create or replace function public.reject_member(p_family uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner(p_family) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.memberships
     set status = 'rejected', role = null, decided_at = now(), decided_by = auth.uid()
   where family_id = p_family and user_id = p_user and status = 'pending';
  if not found then raise exception 'No such pending request' using errcode = 'P0002'; end if;
  insert into public.audit_log (family_id, actor, action, target) values (p_family, auth.uid(), 'reject', p_user);
end $$;

create or replace function public.change_role(p_family uuid, p_user uuid, p_role public.member_role)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner(p_family) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_role <> 'owner' then perform public._guard_last_owner(p_family, p_user); end if;
  update public.memberships set role = p_role, decided_at = now(), decided_by = auth.uid()
   where family_id = p_family and user_id = p_user and status = 'approved';
  if not found then raise exception 'Not an approved member' using errcode = 'P0002'; end if;
  insert into public.audit_log (family_id, actor, action, target, detail)
  values (p_family, auth.uid(), 'change_role', p_user, jsonb_build_object('role', p_role));
end $$;

create or replace function public.revoke_member(p_family uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner(p_family) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform public._guard_last_owner(p_family, p_user);
  update public.memberships
     set status = 'revoked', role = null, decided_at = now(), decided_by = auth.uid()
   where family_id = p_family and user_id = p_user and status = 'approved';
  if not found then raise exception 'Not an approved member' using errcode = 'P0002'; end if;
  insert into public.audit_log (family_id, actor, action, target) values (p_family, auth.uid(), 'revoke', p_user);
end $$;

-- ---------- member actions -------------------------------------------
-- Saves a whole tree. Fails if someone else saved first (p_expected_version is stale).
create or replace function public.save_tree(p_tree uuid, p_data jsonb, p_expected_version integer, p_name text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare f uuid; v integer;
begin
  select family_id into f from public.trees where id = p_tree;
  if f is null or not public.can_edit(f) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.trees
     set data = p_data, name = coalesce(p_name, name), version = version + 1,
         updated_at = now(), updated_by = auth.uid()
   where id = p_tree and version = p_expected_version
   returning version into v;
  if v is null then raise exception 'Version conflict: reload and try again' using errcode = '40001'; end if;
  return v;
end $$;

-- a pending person may tell the owner who they are
create or replace function public.submit_request_note(p_family uuid, p_note text)
returns void language sql security definer set search_path = public as $$
  update public.memberships set note = left(coalesce(p_note, ''), 300)
   where family_id = p_family and user_id = auth.uid() and status = 'pending';
$$;

create or replace function public.set_full_name(p_name text)
returns void language sql security definer set search_path = public as $$
  update public.profiles set full_name = left(coalesce(p_name, ''), 80) where id = auth.uid();
$$;

-- function execute rights
revoke all on function public.is_member(uuid), public.can_edit(uuid), public.is_owner(uuid),
  public.approve_member(uuid, uuid, public.member_role), public.reject_member(uuid, uuid),
  public.change_role(uuid, uuid, public.member_role), public.revoke_member(uuid, uuid),
  public.save_tree(uuid, jsonb, integer, text), public.submit_request_note(uuid, text),
  public.set_full_name(text) from public, anon;
grant execute on function public.is_member(uuid), public.can_edit(uuid), public.is_owner(uuid),
  public.approve_member(uuid, uuid, public.member_role), public.reject_member(uuid, uuid),
  public.change_role(uuid, uuid, public.member_role), public.revoke_member(uuid, uuid),
  public.save_tree(uuid, jsonb, integer, text), public.submit_request_note(uuid, text),
  public.set_full_name(text) to authenticated;
revoke all on function public._guard_last_owner(uuid, uuid), public.handle_auth_user() from public, anon, authenticated;

-- ---------- one-time setup: create the family and make YOU the owner ----
-- Callable only from this SQL editor, never from the app.
create or replace function public.bootstrap_family(p_owner_email text, p_name text default 'Keluarga')
returns uuid language plpgsql security definer set search_path = public as $$
declare f uuid; u uuid;
begin
  if exists (select 1 from public.families) then raise exception 'Family already exists'; end if;
  select p.id into u from public.profiles p join auth.users a on a.id = p.id
   where lower(p.email) = lower(p_owner_email) and a.email_confirmed_at is not null;
  if u is null then raise exception 'Create and confirm this account first'; end if;

  insert into public.families (name) values (p_name) returning id into f;
  insert into public.memberships (family_id, user_id, status, role, decided_at, decided_by)
  values (f, u, 'approved', 'owner', now(), u);
  -- anyone who confirmed before the family existed becomes a pending request
  insert into public.memberships (family_id, user_id)
  select f, p.id from public.profiles p join auth.users a on a.id = p.id
   where p.id <> u and a.email_confirmed_at is not null;
  insert into public.trees (family_id, name) values (f, 'Salasilah Keluarga');
  insert into public.audit_log (family_id, actor, action, target) values (f, u, 'bootstrap', u);
  return f;
end $$;
revoke all on function public.bootstrap_family(text, text) from public, anon, authenticated;

-- ---------- private photo storage ------------------------------------
insert into storage.buckets (id, name, public) values ('memories', 'memories', false)
on conflict (id) do update set public = false;

drop policy if exists memories_obj_read   on storage.objects;
drop policy if exists memories_obj_insert on storage.objects;
drop policy if exists memories_obj_update on storage.objects;
drop policy if exists memories_obj_delete on storage.objects;

create policy memories_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'memories' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy memories_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'memories' and public.can_edit(((storage.foldername(name))[1])::uuid));
create policy memories_obj_update on storage.objects for update to authenticated
  using (bucket_id = 'memories' and public.can_edit(((storage.foldername(name))[1])::uuid));
create policy memories_obj_delete on storage.objects for delete to authenticated
  using (bucket_id = 'memories' and public.can_edit(((storage.foldername(name))[1])::uuid));
