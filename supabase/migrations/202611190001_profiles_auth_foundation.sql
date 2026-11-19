create schema if not exists app_private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name text,
  avatar_url text,
  role text not null default 'student' check (role in ('student','content_editor','administrator')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on public.profiles from anon;
grant select, update on public.profiles to authenticated;
revoke update on public.profiles from authenticated;
grant update (username, display_name, avatar_url) on public.profiles to authenticated;

drop policy if exists "Players can read their own profile" on public.profiles;
create policy "Players can read their own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
drop policy if exists "Players can update their own profile" on public.profiles;
create policy "Players can update their own profile" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create or replace function app_private.set_profile_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles for each row execute function app_private.set_profile_updated_at();

create or replace function app_private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  candidate text;
begin
  candidate := lower(regexp_replace(coalesce(split_part(new.email, '@', 1), 'player'), '[^a-z0-9_]', '', 'g'));
  candidate := left(candidate, 14);
  if length(candidate) < 3 then candidate := 'player'; end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate || '_' || left(replace(new.id::text, '-', ''), 8), nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 60), ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function app_private.handle_new_user();
