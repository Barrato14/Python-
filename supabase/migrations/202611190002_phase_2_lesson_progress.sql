create table if not exists public.lesson_progress (
 user_id uuid not null references auth.users(id) on delete cascade,
 lesson_slug text not null check (lesson_slug ~ '^[a-z0-9-]{3,80}$'),
 completed boolean not null default false,
 completed_at timestamptz,
 updated_at timestamptz not null default now(),
 primary key (user_id, lesson_slug),
 constraint lesson_progress_completed_at_check check ((completed = false and completed_at is null) or (completed = true and completed_at is not null))
);
alter table public.lesson_progress enable row level security;
revoke all on public.lesson_progress from anon;
grant select, insert, update on public.lesson_progress to authenticated;
create policy "Players read their own lesson progress" on public.lesson_progress for select to authenticated using ((select auth.uid()) = user_id);
create policy "Players create their own lesson progress" on public.lesson_progress for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Players update their own lesson progress" on public.lesson_progress for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
