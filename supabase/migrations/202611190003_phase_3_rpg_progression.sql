create table if not exists public.player_stats (
 user_id uuid primary key references auth.users(id) on delete cascade,
 total_xp integer not null default 0 check (total_xp >= 0),
 level integer not null default 1 check (level >= 1),
 current_streak integer not null default 0 check (current_streak >= 0),
 longest_streak integer not null default 0 check (longest_streak >= 0),
 last_active_date date,
 updated_at timestamptz not null default now()
);
create table if not exists public.xp_ledger (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 source_key text not null,
 source_type text not null check (source_type in ('lesson','quest','achievement')),
 xp_awarded integer not null check (xp_awarded > 0),
 created_at timestamptz not null default now(),
 unique(user_id, source_key)
);
create table if not exists public.daily_activity (
 user_id uuid not null references auth.users(id) on delete cascade,
 activity_date date not null,
 xp_earned integer not null default 0 check (xp_earned >= 0),
 lessons_completed integer not null default 0 check (lessons_completed >= 0),
 primary key(user_id, activity_date)
);
create table if not exists public.quest_catalog (
 slug text primary key,
 title text not null,
 description text not null,
 goal_type text not null check(goal_type in ('lessons_completed','world_completed','xp_total')),
 goal_value integer not null check(goal_value > 0),
 xp_reward integer not null check(xp_reward > 0),
 world_name text,
 active boolean not null default true
);
create table if not exists public.quest_progress (
 user_id uuid not null references auth.users(id) on delete cascade,
 quest_slug text not null references public.quest_catalog(slug) on delete cascade,
 progress_value integer not null default 0 check(progress_value >= 0),
 completed_at timestamptz,
 primary key(user_id, quest_slug)
);
create table if not exists public.achievement_catalog (
 slug text primary key,
 title text not null,
 description text not null,
 icon text not null default '✦',
 xp_reward integer not null default 0 check(xp_reward >= 0)
);
create table if not exists public.user_achievements (
 user_id uuid not null references auth.users(id) on delete cascade,
 achievement_slug text not null references public.achievement_catalog(slug) on delete cascade,
 unlocked_at timestamptz not null default now(),
 primary key(user_id, achievement_slug)
);

insert into public.quest_catalog(slug,title,description,goal_type,goal_value,xp_reward,world_name) values
 ('first-code','First Steps','Complete your first Python lesson','lessons_completed',1,75,null),
 ('triple-practice','Practice Makes Progress','Complete three lessons','lessons_completed',3,125,null),
 ('spark-master','Spark Keeper','Finish every lesson in The First Spark','world_completed',4,200,'The First Spark'),
 ('xp-hunter','XP Hunter','Earn 250 experience points','xp_total',250,100,null)
on conflict(slug) do update set title=excluded.title,description=excluded.description,goal_type=excluded.goal_type,goal_value=excluded.goal_value,xp_reward=excluded.xp_reward,world_name=excluded.world_name;
insert into public.achievement_catalog(slug,title,description,icon,xp_reward) values
 ('first-steps','First Steps','Finish your first lesson','✦',25),
 ('five-lessons','Curious Mind','Complete five lessons','✧',50),
 ('spark-master','Realm Explorer','Complete The First Spark world','⚔',100),
 ('xp-500','Rising Adventurer','Earn 500 XP','★',75)
on conflict(slug) do update set title=excluded.title,description=excluded.description,icon=excluded.icon,xp_reward=excluded.xp_reward;

do $$
declare t text;
begin
 foreach t in array array['player_stats','xp_ledger','daily_activity','quest_progress','user_achievements'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from anon, authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy "Players read own %1$I" on public.%1$I for select to authenticated using ((select auth.uid()) = user_id)',t);
 end loop;
end $$;
alter table public.quest_catalog enable row level security;
alter table public.achievement_catalog enable row level security;
revoke all on public.quest_catalog, public.achievement_catalog from anon, authenticated;
grant select on public.quest_catalog, public.achievement_catalog to anon, authenticated;
create policy "Quest catalog is public" on public.quest_catalog for select to anon, authenticated using (active = true);
create policy "Achievement catalog is public" on public.achievement_catalog for select to anon, authenticated using (true);

create or replace function public.complete_lesson_reward(p_lesson_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_user uuid := auth.uid();
 v_xp integer := 50;
 v_today date := (now() at time zone 'UTC')::date;
 v_inserted integer;
 v_stats public.player_stats%rowtype;
 v_completed integer;
 v_new_achievements text[] := array[]::text[];
 v_world_done integer;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_lesson_slug not in ('python-first-steps','variables-and-values','working-with-strings','numbers-and-operators','decisions-with-if','loops-and-repetition','functions-and-reuse','lists-and-collections') then
  raise exception 'Unknown lesson';
 end if;
 if not exists(select 1 from public.lesson_progress where user_id=v_user and lesson_slug=p_lesson_slug and completed=true) then
  raise exception 'Complete the lesson before claiming its reward';
 end if;
 insert into public.xp_ledger(user_id,source_key,source_type,xp_awarded)
 values(v_user,'lesson:'||p_lesson_slug,'lesson',v_xp)
 on conflict(user_id,source_key) do nothing;
 get diagnostics v_inserted = row_count;
 insert into public.player_stats(user_id) values(v_user) on conflict(user_id) do nothing;
 if v_inserted=1 then
  insert into public.daily_activity(user_id,activity_date,xp_earned,lessons_completed)
  values(v_user,v_today,v_xp,1)
  on conflict(user_id,activity_date) do update set xp_earned=public.daily_activity.xp_earned+excluded.xp_earned,lessons_completed=public.daily_activity.lessons_completed+1;
  update public.player_stats set total_xp=total_xp+v_xp,
   level=1+floor((total_xp+v_xp)::numeric/250)::integer,
   current_streak=case when last_active_date=v_today then current_streak when last_active_date=v_today-1 then current_streak+1 else 1 end,
   longest_streak=greatest(longest_streak,case when last_active_date=v_today then current_streak when last_active_date=v_today-1 then current_streak+1 else 1 end),
   last_active_date=v_today,updated_at=now()
  where user_id=v_user;
 end if;
 select count(*) into v_completed from public.lesson_progress where user_id=v_user and completed=true;
 select count(*) into v_world_done from public.lesson_progress where user_id=v_user and completed=true and lesson_slug in ('python-first-steps','variables-and-values','working-with-strings','numbers-and-operators');
 insert into public.quest_progress(user_id,quest_slug,progress_value,completed_at)
 select v_user,q.slug,least(q.goal_value,case q.goal_type when 'lessons_completed' then v_completed when 'world_completed' then v_world_done when 'xp_total' then coalesce((select total_xp from public.player_stats where user_id=v_user),0) else 0 end),
 case when (case q.goal_type when 'lessons_completed' then v_completed when 'world_completed' then v_world_done when 'xp_total' then coalesce((select total_xp from public.player_stats where user_id=v_user),0) else 0 end)>=q.goal_value then now() else null end
 from public.quest_catalog q where q.active=true
 on conflict(user_id,quest_slug) do update set progress_value=greatest(public.quest_progress.progress_value,excluded.progress_value),completed_at=coalesce(public.quest_progress.completed_at,excluded.completed_at);
 select array_agg(a.slug) into v_new_achievements from public.achievement_catalog a
 where (a.slug='first-steps' and v_completed>=1) or (a.slug='five-lessons' and v_completed>=5) or (a.slug='spark-master' and v_world_done>=4) or (a.slug='xp-500' and coalesce((select total_xp from public.player_stats where user_id=v_user),0)>=500)
 and not exists(select 1 from public.user_achievements ua where ua.user_id=v_user and ua.achievement_slug=a.slug);
 if v_new_achievements is not null then
  insert into public.user_achievements(user_id,achievement_slug) select v_user, unnest(v_new_achievements) on conflict do nothing;
 end if;
 select * into v_stats from public.player_stats where user_id=v_user;
 return jsonb_build_object('xp_gained',case when v_inserted=1 then v_xp else 0 end,'total_xp',v_stats.total_xp,'level',v_stats.level,'current_streak',v_stats.current_streak,'new_achievements',coalesce(to_jsonb(v_new_achievements),'[]'::jsonb));
end;
$$;
revoke all on function public.complete_lesson_reward(text) from public, anon;
grant execute on function public.complete_lesson_reward(text) to authenticated;
