-- The normal quiz answer path is intentionally durable/outbox-backed.
-- A learner can tap the Fast Track routing decision before the queued answer reaches Postgres.
-- Persist that routing intent separately and apply it immediately after the durable wrong attempt arrives.

create table if not exists english.fast_track_failure_decision_intent (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references english.questions(question_id) on delete cascade,
  decision text not null check (decision in ('targeted','keep')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '15 minutes',
  primary key(user_id,question_id)
);

alter table english.fast_track_failure_decision_intent enable row level security;
revoke all on english.fast_track_failure_decision_intent from public,anon,authenticated;
grant all on english.fast_track_failure_decision_intent to service_role;

create or replace function public.english_resolve_fast_track_failure(p_question_id text,p_add_targeted boolean)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid(); r english.learning_route_state%rowtype; v_decision text:=case when coalesce(p_add_targeted,false) then 'targeted' else 'keep' end;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into r from english.learning_route_state where user_id=uid and question_id=btrim(p_question_id) and route='fast_track' for update;
 if not found then return jsonb_build_object('ok',false,'reason','not-fast-track'); end if;

 if not r.pending_failure_decision then
   insert into english.fast_track_failure_decision_intent(user_id,question_id,decision,created_at,expires_at)
   values(uid,btrim(p_question_id),v_decision,now(),now()+interval '15 minutes')
   on conflict(user_id,question_id) do update set decision=excluded.decision,created_at=excluded.created_at,expires_at=excluded.expires_at;
   return jsonb_build_object('ok',true,'route','fast_track','queuedDecision',true,'decision',v_decision);
 end if;

 if v_decision='targeted' then
   delete from english.fast_track_failure_decision_intent where user_id=uid and question_id=btrim(p_question_id);
   return english.route_to_targeted(uid,btrim(p_question_id),'Fast Track Failure','Learner approved Targeted Mastery after Fast Track miss');
 end if;
 if r.kept_failure_count>=1 then
   delete from english.fast_track_failure_decision_intent where user_id=uid and question_id=btrim(p_question_id);
   return english.route_to_targeted(uid,btrim(p_question_id),'Fast Track Failure','Repeated Fast Track miss requires Targeted Mastery');
 end if;
 update english.learning_route_state set
   pending_failure_decision=false,kept_failure_count=kept_failure_count+1,fast_track_status='waiting',
   next_fast_track_check=now()+interval '1 day',last_route_reason='One Fast Track miss kept; spaced confirmation required',updated_at=now()
 where user_id=uid and question_id=btrim(p_question_id);
 delete from english.fast_track_failure_decision_intent where user_id=uid and question_id=btrim(p_question_id);
 perform english.route_event(uid,btrim(p_question_id),'KEEP','fast_track','fast_track','Fast Track Failure','Learner kept one-off miss in Fast Track; spaced confirmation required','{}'::jsonb,null);
 return jsonb_build_object('ok',true,'route','fast_track','status','waiting','confirmationRequired',true,'nextCheck',now()+interval '1 day');
end $$;

create or replace function english.apply_fast_track_failure_decision_intent()
returns trigger language plpgsql security definer
set search_path=pg_catalog,english,auth as $$
declare i english.fast_track_failure_decision_intent%rowtype; r english.learning_route_state%rowtype;
begin
 if lower(coalesce(new.module,''))<>'fasttrack' or coalesce(new.correct,false) then return new; end if;
 select * into i from english.fast_track_failure_decision_intent
 where user_id=new.user_id and question_id=new.question_id and expires_at>=now() for update;
 if not found then return new; end if;
 delete from english.fast_track_failure_decision_intent where user_id=i.user_id and question_id=i.question_id;
 select * into r from english.learning_route_state where user_id=new.user_id and question_id=new.question_id for update;
 if not found or r.route<>'fast_track' then return new; end if;
 if i.decision='targeted' then
   perform english.route_to_targeted(new.user_id,new.question_id,'Fast Track Failure','Learner approved Targeted Mastery after Fast Track miss');
   return new;
 end if;
 if r.kept_failure_count>=1 then
   perform english.route_to_targeted(new.user_id,new.question_id,'Fast Track Failure','Repeated Fast Track miss requires Targeted Mastery');
   return new;
 end if;
 update english.learning_route_state set
   pending_failure_decision=false,kept_failure_count=kept_failure_count+1,fast_track_status='waiting',
   next_fast_track_check=now()+interval '1 day',last_route_reason='One Fast Track miss kept; spaced confirmation required',updated_at=now()
 where user_id=new.user_id and question_id=new.question_id;
 perform english.route_event(new.user_id,new.question_id,'KEEP','fast_track','fast_track','Fast Track Failure','Learner kept one-off miss in Fast Track; spaced confirmation required','{}'::jsonb,null);
 return new;
end $$;

drop trigger if exists zz_english_fast_track_failure_decision on english.attempts;
create trigger zz_english_fast_track_failure_decision
after insert on english.attempts for each row execute function english.apply_fast_track_failure_decision_intent();

grant execute on function public.english_resolve_fast_track_failure(text,boolean) to authenticated,service_role;
