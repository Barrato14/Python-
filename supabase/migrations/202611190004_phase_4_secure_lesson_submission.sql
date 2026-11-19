revoke insert, update, delete on public.lesson_progress from authenticated;
drop policy if exists "Players create their own lesson progress" on public.lesson_progress;
drop policy if exists "Players update their own lesson progress" on public.lesson_progress;

create or replace function public.submit_lesson_answer(p_lesson_slug text, p_answer_index integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_user uuid := auth.uid();
 v_correct integer;
 v_reward jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 v_correct := case p_lesson_slug
  when 'python-first-steps' then 1
  when 'variables-and-values' then 2
  when 'working-with-strings' then 1
  when 'numbers-and-operators' then 0
  when 'decisions-with-if' then 2
  when 'loops-and-repetition' then 1
  when 'functions-and-reuse' then 2
  when 'lists-and-collections' then 0
  else null end;
 if v_correct is null then raise exception 'Unknown lesson'; end if;
 if p_answer_index is distinct from v_correct then
  return jsonb_build_object('correct',false,'xp_gained',0);
 end if;
 insert into public.lesson_progress(user_id,lesson_slug,completed,completed_at,updated_at)
 values(v_user,p_lesson_slug,true,now(),now())
 on conflict(user_id,lesson_slug) do update set completed=true,completed_at=coalesce(public.lesson_progress.completed_at,now()),updated_at=now();
 v_reward := public.complete_lesson_reward(p_lesson_slug);
 return v_reward || jsonb_build_object('correct',true);
end;
$$;
revoke all on function public.submit_lesson_answer(text,integer) from public, anon;
grant execute on function public.submit_lesson_answer(text,integer) to authenticated;

create or replace function public.claim_quest_reward(p_quest_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
 v_user uuid := auth.uid();
 v_reward integer;
 v_inserted integer;
 v_stats public.player_stats%rowtype;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select q.xp_reward into v_reward
 from public.quest_catalog q
 join public.quest_progress p on p.quest_slug=q.slug and p.user_id=v_user
 where q.slug=p_quest_slug and q.active=true and p.completed_at is not null;
 if v_reward is null then raise exception 'Quest is not complete or already unavailable'; end if;
 insert into public.xp_ledger(user_id,source_key,source_type,xp_awarded)
 values(v_user,'quest:'||p_quest_slug,'quest',v_reward)
 on conflict(user_id,source_key) do nothing;
 get diagnostics v_inserted = row_count;
 if v_inserted=0 then raise exception 'Quest reward already claimed'; end if;
 insert into public.player_stats(user_id) values(v_user) on conflict(user_id) do nothing;
 update public.player_stats set total_xp=total_xp+v_reward,level=1+floor((total_xp+v_reward)::numeric/250)::integer,updated_at=now() where user_id=v_user;
 insert into public.daily_activity(user_id,activity_date,xp_earned,lessons_completed)
 values(v_user,(now() at time zone 'UTC')::date,v_reward,0)
 on conflict(user_id,activity_date) do update set xp_earned=public.daily_activity.xp_earned+excluded.xp_earned;
 select * into v_stats from public.player_stats where user_id=v_user;
 return jsonb_build_object('xp_gained',v_reward,'total_xp',v_stats.total_xp,'level',v_stats.level);
end;
$$;
revoke all on function public.claim_quest_reward(text) from public, anon;
grant execute on function public.claim_quest_reward(text) to authenticated;
