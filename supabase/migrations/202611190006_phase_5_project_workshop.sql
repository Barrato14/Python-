create table if not exists public.learner_projects (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null check (char_length(title) between 1 and 80),
 description text not null default '' check (char_length(description) <= 300),
 code text not null check (char_length(code) between 1 and 12000),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists learner_projects_user_created_idx on public.learner_projects(user_id, created_at desc);
alter table public.learner_projects enable row level security;
revoke all on public.learner_projects from anon;
grant select, insert, update, delete on public.learner_projects to authenticated;
drop policy if exists "Players read their own projects" on public.learner_projects;
create policy "Players read their own projects" on public.learner_projects for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "Players create their own projects" on public.learner_projects;
create policy "Players create their own projects" on public.learner_projects for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "Players update their own projects" on public.learner_projects;
create policy "Players update their own projects" on public.learner_projects for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "Players delete their own projects" on public.learner_projects;
create policy "Players delete their own projects" on public.learner_projects for delete to authenticated using ((select auth.uid()) = user_id);
