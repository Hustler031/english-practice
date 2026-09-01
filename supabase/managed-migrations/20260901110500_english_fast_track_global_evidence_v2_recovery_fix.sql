-- Follow-up hardening: do not rely on PL/pgSQL FOUND after the Difficult lookup.
create or replace function english.route_after_question_state_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'english', 'auth'
as $function$
declare
  r english.learning_route_state%rowtype;
  reason text;
  d boolean:=false;
  ev record;
  clean_days integer:=0;
  wrong_after integer:=0;
  recovery_origin text;
begin
  if coalesce(new.mastered,false) then return new; end if;

  select * into r from english.learning_route_state
  where user_id=new.user_id and question_id=new.question_id;
  select coalesce(ds.difficult,false) into d
  from english.difficult_state ds where ds.user_id=new.user_id and ds.question_id=new.question_id;
  if not found then d:=false; end if;

  if not d and (r.question_id is null or r.route<>'fast_track') then
    select * into ev from english.fast_track_evidence(new.user_id,new.question_id);
    if coalesce(ev.eligible,false) then
      perform english.route_to_fast_track(
        new.user_id,new.question_id,'Global Evidence',
        '10 spaced checkpoints, >=80% accuracy and last 4 clean',false
      );
      return new;
    end if;
  end if;

  if r.question_id is not null and r.route='targeted'
     and new.status in ('Strong','Proven Mastered') and coalesce(new.last_result,false) then
    if not d then
      select
        count(distinct (a.attempted_at at time zone 'Asia/Kolkata')::date) filter(where coalesce(a.correct,false))::int,
        count(*) filter(where not coalesce(a.correct,false))::int
      into clean_days,wrong_after
      from english.attempts a
      where a.user_id=new.user_id and a.question_id=new.question_id
        and a.attempted_at>=coalesce(r.targeted_at,'epoch'::timestamptz);

      if clean_days>=2 and wrong_after=0 then
        recovery_origin:=english.route_recovery_origin(r.last_route_reason);
        perform english.route_to_fast_track(
          new.user_id,new.question_id,recovery_origin,
          'Targeted item recovered with spaced clean evidence',true
        );
        return new;
      end if;
    end if;
  end if;

  reason:=english.route_targeted_reason(new.user_id,new.question_id);
  if nullif(reason,'') is not null then
    perform english.route_to_targeted(
      new.user_id,new.question_id,
      case when reason='Difficult' then 'Difficult' else 'Central Intelligence' end,
      reason
    );
  end if;
  return new;
end
$function$;
