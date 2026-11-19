alter table public.xp_ledger drop constraint if exists xp_ledger_source_type_check;
alter table public.xp_ledger add constraint xp_ledger_source_type_check check (source_type in ('lesson','quest','achievement','challenge'));
create table if not exists public.daily_challenge_catalog (
 slug text primary key,
 title text not null,
 description text not null,
 prompt text not null,
 starter_code text not null default '',
 expected_answer text not null,
 explanation text not null,
 xp_reward integer not null default 40 check (xp_reward between 1 and 200),
 active boolean not null default true
);
create table if not exists public.daily_challenge_submissions (
 user_id uuid not null references auth.users(id) on delete cascade,
 challenge_slug text not null references public.daily_challenge_catalog(slug) on delete cascade,
 submitted_answer text not null,
 is_correct boolean not null,
 submitted_at timestamptz not null default now(),
 primary key(user_id, challenge_slug)
);
alter table public.daily_challenge_catalog enable row level security;
alter table public.daily_challenge_submissions enable row level security;
revoke all on public.daily_challenge_catalog, public.daily_challenge_submissions from anon, authenticated;
grant select on public.daily_challenge_catalog to authenticated;
grant select on public.daily_challenge_submissions to authenticated;
create policy "Players read their own challenge submissions" on public.daily_challenge_submissions for select to authenticated using ((select auth.uid())=user_id);
insert into public.daily_challenge_catalog(slug,title,description,prompt,starter_code,expected_answer,explanation,xp_reward) values
('daily-output-42','The Meaning of Life','Predict a tiny program output.','What does print(6 * 7) display? Enter the output only.','print(6 * 7)','42','The multiplication expression 6 * 7 evaluates to 42, and print displays that value.',40),
('daily-string-quest','String Alchemy','Read a string method.','What does print("py".upper()) display?','print("py".upper())','PY','upper() returns an uppercase version of the string.',40),
('daily-list-count','Inventory Check','Count the items in a list.','What does print(len(["map", "key", "potion"])) display?','print(len(["map", "key", "potion"]))','3','The list has three elements, so len() returns 3.',40),
('daily-remainder','Coin Remainder','Practice the modulo operator.','What does print(17 % 5) display?','print(17 % 5)','2','17 divided by 5 leaves a remainder of 2.',40),
('daily-range','Loop Counter','Understand range().','How many times does this loop run? for n in range(4): print(n). Enter a number.','for n in range(4):\n    print(n)','4','range(4) generates 0, 1, 2, and 3: four iterations.',40)
on conflict(slug) do update set title=excluded.title,description=excluded.description,prompt=excluded.prompt,starter_code=excluded.starter_code,expected_answer=excluded.expected_answer,explanation=excluded.explanation,xp_reward=excluded.xp_reward,active=true;
create or replace function public.get_daily_challenge()
returns table(slug text,title text,description text,prompt text,starter_code text,xp_reward integer)
language sql stable security definer set search_path=''
as $$
 select c.slug,c.title,c.description,c.prompt,c.starter_code,c.xp_reward
 from public.daily_challenge_catalog c
 where c.active=true
 order by c.slug
 offset ((extract(doy from (now() at time zone 'UTC'))::integer - 1) % (select greatest(count(*)::integer,1) from public.daily_challenge_catalog where active=true))
 limit 1
$$;
revoke all on function public.get_daily_challenge() from public, anon;
grant execute on function public.get_daily_challenge() to authenticated;
create or replace function public.submit_daily_challenge(p_slug text,p_answer text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_challenge public.daily_challenge_catalog%rowtype;
 v_inserted integer:=0;
 v_correct boolean;
 v_today date:=(now() at time zone 'UTC')::date;
 v_stats public.player_stats%rowtype;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select c.* into v_challenge from public.daily_challenge_catalog c
 where c.slug=p_slug and c.active=true
 and c.slug=(select d.slug from public.get_daily_challenge() d);
 if not found then raise exception 'This is not the active daily challenge'; end if;
 if length(coalesce(p_answer,''))>300 then raise exception 'Answer is too long'; end if;
 v_correct:=lower(btrim(coalesce(p_answer,'')))=lower(btrim(v_challenge.expected_answer));
 insert into public.daily_challenge_submissions(user_id,challenge_slug,submitted_answer,is_correct)
 values(v_user,v_challenge.slug,left(coalesce(p_answer,''),300),v_correct)
 on conflict(user_id,challenge_slug) do nothing;
 get diagnostics v_inserted=row_count;
 if v_inserted=0 then
  return jsonb_build_object('correct',false,'already_submitted',true,'message','You have already attempted today''s challenge.');
 end if;
 if v_correct then
  insert into public.xp_ledger(user_id,source_key,source_type,xp_awarded)
  values(v_user,'challenge:'||v_challenge.slug,'challenge',v_challenge.xp_reward)
  on conflict(user_id,source_key) do nothing;
  insert into public.player_stats(user_id) values(v_user) on conflict(user_id) do nothing;
  update public.player_stats set total_xp=total_xp+v_challenge.xp_reward,
   level=1+floor((total_xp+v_challenge.xp_reward)::numeric/250)::integer,
   current_streak=case when last_active_date=v_today then current_streak when last_active_date=v_today-1 then current_streak+1 else 1 end,
   longest_streak=greatest(longest_streak,case when last_active_date=v_today then current_streak when last_active_date=v_today-1 then current_streak+1 else 1 end),
   last_active_date=v_today,updated_at=now() where user_id=v_user;
  insert into public.daily_activity(user_id,activity_date,xp_earned)
  values(v_user,v_today,v_challenge.xp_reward)
  on conflict(user_id,activity_date) do update set xp_earned=public.daily_activity.xp_earned+excluded.xp_earned;
 end if;
 return jsonb_build_object('correct',v_correct,'xp_gained',case when v_correct then v_challenge.xp_reward else 0 end,'explanation',v_challenge.explanation);
end $$;
revoke all on function public.submit_daily_challenge(text,text) from public,anon;
grant execute on function public.submit_daily_challenge(text,text) to authenticated;
create or replace function public.get_public_leaderboard(p_limit integer default 20)
returns table(rank bigint,username text,display_name text,level integer,total_xp integer,current_streak integer)
language sql stable security definer set search_path=''
as $$
 select row_number() over(order by s.total_xp desc,s.updated_at asc) as rank,
 coalesce(p.username,'adventurer') as username,
 coalesce(nullif(p.display_name,''),p.username,'Adventurer') as display_name,
 s.level,s.total_xp,s.current_streak
 from public.player_stats s
 join public.profiles p on p.id=s.user_id
 order by s.total_xp desc,s.updated_at asc
 limit least(greatest(coalesce(p_limit,20),1),50)
$$;
revoke all on function public.get_public_leaderboard(integer) from public,anon;
grant execute on function public.get_public_leaderboard(integer) to authenticated;
