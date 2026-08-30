\set ON_ERROR_STOP on

insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002')
on conflict do nothing;

insert into gk.questions(question_id,question,option_a,option_b,option_c,option_d,correct_option,active,content_lane,subject,topic,concept_id)
values
 ('Q_NEW','New','A','B','C','D','A',true,'MAIN','Test','New','C1'),
 ('Q_EXPOSED','Exposed no attempt','A','B','C','D','A',true,'MAIN','Test','New','C2'),
 ('Q_FIRST_CORRECT','First correct','A','B','C','D','A',true,'MAIN','Test','State','C3'),
 ('Q_FIRST_WRONG','First wrong','A','B','C','D','A',true,'MAIN','Test','State','C4'),
 ('Q_WEAK','Weak','A','B','C','D','A',true,'MAIN','Test','State','C5'),
 ('Q_PW','Persistent Weak','A','B','C','D','A',true,'MAIN','Test','State','C6'),
 ('Q_STRONG','Strong','A','B','C','D','A',true,'MAIN','Test','State','C7'),
 ('Q_MASTER','Mastered recent','A','B','C','D','A',true,'MAIN','Test','State','C8'),
 ('Q_MASTER_DUE','Mastered due','A','B','C','D','A',true,'MAIN','Test','State','C9'),
 ('Q_GUESS_UNRES','Guess unresolved','A','B','C','D','A',true,'MAIN','Test','Guess','C10'),
 ('Q_GUESS_RES','Guess resolved','A','B','C','D','A',true,'MAIN','Test','Guess','C11'),
 ('Q_SAME_SESSION','Same session','A','B','C','D','A',true,'MAIN','Test','Spacing','C12'),
 ('Q_IDEM','Idempotency','A','B','C','D','A',true,'MAIN','Test','Idem','C13'),
 ('Q_LTNS_NEVER','Never seen','A','B','C','D','A',true,'MAIN','LTNS','Age','C14'),
 ('Q_LTNS_OLD','Old seen','A','B','C','D','A',true,'MAIN','LTNS','Age','C15'),
 ('Q_LTNS_RECENT','Recent seen','A','B','C','D','A',true,'MAIN','LTNS','Age','C16'),
 ('Q_LANE_MAIN','Lane main','A','B','C','D','A',true,'MAIN','LaneTest','Lane','C17'),
 ('Q_LANE_RAPID','Lane rapid','A','B','C','D','A',true,'RAPID','LaneTest','Lane','C18')
on conflict(question_id) do nothing;

-- User 1 raw evidence.
insert into gk.attempts(attempt_id,user_id,attempted_at,question_id,selected_option,is_correct,session_id,guessed)
values
 ('A-FC','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_FIRST_CORRECT','A',true,'FC-1',false),
 ('A-FW','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_FIRST_WRONG','B',false,'FW-1',false),
 ('A-W1','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_WEAK','A',true,'W-1',false),
 ('A-W2','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_WEAK','B',false,'W-2',false),
 ('A-PW1','00000000-0000-0000-0000-000000000001',now()-interval '40 hours','Q_PW','A',true,'PW-1',false),
 ('A-PW2','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_PW','B',false,'PW-2',false),
 ('A-PW3','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_PW','B',false,'PW-3',false),
 ('A-S1','00000000-0000-0000-0000-000000000001',now()-interval '40 hours','Q_STRONG','A',true,'S-1',false),
 ('A-S2','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_STRONG','A',true,'S-2',false),
 ('A-S3','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_STRONG','A',true,'S-3',false),
 ('A-M1','00000000-0000-0000-0000-000000000001',now()-interval '59 hours','Q_MASTER','A',true,'M-1',false),
 ('A-M2','00000000-0000-0000-0000-000000000001',now()-interval '40 hours','Q_MASTER','A',true,'M-2',false),
 ('A-M3','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_MASTER','A',true,'M-3',false),
 ('A-M4','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_MASTER','A',true,'M-4',false),
 ('A-MD1','00000000-0000-0000-0000-000000000001',now()-interval '33 days','Q_MASTER_DUE','A',true,'MD-1',false),
 ('A-MD2','00000000-0000-0000-0000-000000000001',now()-interval '32 days 5 hours','Q_MASTER_DUE','A',true,'MD-2',false),
 ('A-MD3','00000000-0000-0000-0000-000000000001',now()-interval '31 days 10 hours','Q_MASTER_DUE','A',true,'MD-3',false),
 ('A-MD4','00000000-0000-0000-0000-000000000001',now()-interval '30 days 15 hours','Q_MASTER_DUE','A',true,'MD-4',false),
 ('A-GU','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_GUESS_UNRES','A',true,'GU-1',true),
 ('A-GR1','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_GUESS_RES','A',true,'GR-1',true),
 ('A-GR2','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_GUESS_RES','A',true,'GR-2',false),
 ('A-SS1','00000000-0000-0000-0000-000000000001',now()-interval '21 hours','Q_SAME_SESSION','B',false,'SAME',false),
 ('A-SS2','00000000-0000-0000-0000-000000000001',now()-interval '2 hours','Q_SAME_SESSION','A',true,'SAME',false)
on conflict do nothing;

insert into gk.exposures(exposure_id,user_id,exposed_at,question_id,session_id,mode,exposure_key)
values
 ('E-EXPOSED','00000000-0000-0000-0000-000000000001',now()-interval '1 hour','Q_EXPOSED','EXPOSED-S','practice','E-EXPOSED-K'),
 ('E-LTNS-OLD','00000000-0000-0000-0000-000000000001',now()-interval '40 days','Q_LTNS_OLD','L-1','practice','E-LTNS-OLD-K'),
 ('E-LTNS-RECENT','00000000-0000-0000-0000-000000000001',now()-interval '2 days','Q_LTNS_RECENT','L-2','practice','E-LTNS-RECENT-K')
on conflict do nothing;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);

-- Evidence-derived state and spacing contracts.
do $$
declare p record; def text;
begin
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_NEW';
 if p.learning_state<>'New' or p.attempts<>0 then raise exception 'New profile contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_FIRST_CORRECT';
 if p.learning_state<>'Fragile' or p.first_attempt_correct is not true then raise exception 'First-correct contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_FIRST_WRONG';
 if p.learning_state<>'Fragile' or p.first_attempt_correct is not false then raise exception 'First-wrong contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_WEAK';
 if p.learning_state<>'Weak' or p.retention_wrong<>1 then raise exception 'Weak contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_PW';
 if p.learning_state<>'Persistent Weak' or p.retention_wrong<2 then raise exception 'Persistent Weak contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_STRONG';
 if p.learning_state<>'Strong' or p.retention_correct<>2 then raise exception 'Strong contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_MASTER';
 if p.learning_state<>'Proven Mastered' or p.retention_correct<>3 or p.due then raise exception 'Proven Mastered contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_MASTER_DUE';
 if p.learning_state<>'Proven Mastered' or not p.due then raise exception 'Due mastered contract failed: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_SAME_SESSION';
 if p.retention_attempts<>0 then raise exception 'Same-session correction incorrectly proved retention: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_GUESS_UNRES';
 if not p.unconfirmed_guess then raise exception 'Guessed correct must remain unresolved: %',to_jsonb(p); end if;
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_GUESS_RES';
 if p.unconfirmed_guess or p.confirmed_unguessed_spaced_recalls<1 then raise exception 'Later spaced unguessed recall did not resolve guess: %',to_jsonb(p); end if;

 select pg_get_functiondef('gk.learning_profiles_v2(uuid)'::regprocedure) into def;
 if def not like '%>= 18%' then raise exception '18-hour retention gate missing'; end if;
 foreach def in array array['New','Fragile','Learning','Weak','Persistent Weak','Strong','Proven Mastered'] loop
   if position(quote_literal(def) in pg_get_functiondef('gk.learning_profiles_v2(uuid)'::regprocedure))=0 then
     raise exception 'Learning state % missing from runtime derivation',def;
   end if;
 end loop;
end $$;

-- New is exposure-authoritative, not attempt/cache-authoritative.
do $$
declare ids jsonb;
begin
 ids:=public.gk_get_batch('new',1000,'MIXED',null,null,null,null,null,null,null);
 if not exists(select 1 from jsonb_array_elements(ids) x where x->>'id'='Q_NEW') then raise exception 'Unexposed Q_NEW missing from New'; end if;
 if exists(select 1 from jsonb_array_elements(ids) x where x->>'id'='Q_EXPOSED') then raise exception 'Exposed Q_EXPOSED leaked into New'; end if;
end $$;

-- Proven Mastered stays out before due and re-enters Daily when due.
do $$
declare ids jsonb;
begin
 ids:=public.gk_get_batch('daily',1000,'MIXED','Test',null,null,null,null,null,null);
 if exists(select 1 from jsonb_array_elements(ids) x where x->>'id'='Q_MASTER') then raise exception 'Not-due mastered question leaked into Daily'; end if;
 if not exists(select 1 from jsonb_array_elements(ids) x where x->>'id'='Q_MASTER_DUE') then raise exception 'Due mastered question did not re-enter Daily'; end if;
end $$;

-- Long Time No See is oldest/never-seen rotation, not a hidden 30-day filter.
do $$
declare ids jsonb; first_id text;
begin
 ids:=public.gk_get_batch('long_unseen',3,'MIXED','LTNS',null,null,null,null,null,null);
 first_id:=ids->0->>'id';
 if first_id<>'Q_LTNS_NEVER' then raise exception 'Long Time No See did not put never-seen first: %',ids; end if;
 if jsonb_array_length(ids)<>3 then raise exception 'Long Time No See applied an unexpected hidden cutoff: %',ids; end if;
end $$;

-- Main/Rapid are lanes of the same application and remain mutually exclusive when requested.
do $$
declare main_ids jsonb; rapid_ids jsonb;
begin
 main_ids:=public.gk_get_batch('all',100,'MAIN','LaneTest',null,null,null,null,null,null);
 rapid_ids:=public.gk_get_batch('all',100,'RAPID','LaneTest',null,null,null,null,null,null);
 if jsonb_array_length(main_ids)<>1 or main_ids->0->>'id'<>'Q_LANE_MAIN' then raise exception 'MAIN lane contract failed: %',main_ids; end if;
 if jsonb_array_length(rapid_ids)<>1 or rapid_ids->0->>'id'<>'Q_LANE_RAPID' then raise exception 'RAPID lane contract failed: %',rapid_ids; end if;
end $$;

-- Answer idempotency: same attempt and different attempt IDs in the same session/question
-- still create one raw attempt because submission_key is session+question scoped.
select public.gk_submit_answer('Q_IDEM','A',false,'IDEM-A1','practice','IDEM-S',10);
select public.gk_submit_answer('Q_IDEM','A',false,'IDEM-A1','practice','IDEM-S',10);
select public.gk_submit_answer('Q_IDEM','A',false,'IDEM-A2','practice','IDEM-S',10);
do $$begin
 if (select count(*) from gk.attempts where user_id=auth.uid() and question_id='Q_IDEM')<>1 then raise exception 'Answer idempotency failed'; end if;
end $$;

select public.gk_record_exposure('Q_IDEM','IDEM-S','practice','IDEM-E1');
select public.gk_record_exposure('Q_IDEM','IDEM-S','practice','IDEM-E2');
do $$begin
 if (select count(*) from gk.exposures where user_id=auth.uid() and question_id='Q_IDEM' and session_id='IDEM-S')<>1 then raise exception 'Exposure idempotency failed'; end if;
end $$;

select public.gk_mark_guessed('Q_IDEM','IDEM-A1',true,'MUT-G1');
select public.gk_mark_guessed('Q_IDEM','IDEM-A1',true,'MUT-G2');
do $$declare p record; begin
 select * into p from gk.learning_profiles_v2(auth.uid()) where question_id='Q_IDEM';
 if p.guessed_attempts<>1 or not p.unconfirmed_guess then raise exception 'Guessed idempotency failed: %',to_jsonb(p); end if;
end $$;

-- Demand-set ownership. A legacy NULL-owner set is visible only to the sole legacy
-- evidence owner; private owned sets never cross users.
insert into gk.demand_sets(demand_id,user_id,title,kind,question_ids,created_at,active) values
 ('D-LEGACY',null,'Legacy','weak','["Q_WEAK"]'::jsonb,now(),true),
 ('D-U1','00000000-0000-0000-0000-000000000001','User 1','weak','["Q_WEAK"]'::jsonb,now(),true),
 ('D-U2','00000000-0000-0000-0000-000000000002','User 2','weak','["Q_WEAK"]'::jsonb,now(),true);
do $$declare hub jsonb; begin
 hub:=public.gk_get_on_demand_hub();
 if not exists(select 1 from jsonb_array_elements(hub->'myDemandSets') x where x->>'demandId'='D-U1') then raise exception 'Own demand set missing'; end if;
 if not exists(select 1 from jsonb_array_elements(hub->'myDemandSets') x where x->>'demandId'='D-LEGACY') then raise exception 'Legacy compatibility set missing for sole legacy owner'; end if;
 if exists(select 1 from jsonb_array_elements(hub->'myDemandSets') x where x->>'demandId'='D-U2') then raise exception 'Cross-user demand set leak'; end if;
end $$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
do $$declare hub jsonb; begin
 hub:=public.gk_get_on_demand_hub();
 if not exists(select 1 from jsonb_array_elements(hub->'myDemandSets') x where x->>'demandId'='D-U2') then raise exception 'Second user own demand set missing'; end if;
 if exists(select 1 from jsonb_array_elements(hub->'myDemandSets') x where x->>'demandId' in ('D-U1','D-LEGACY')) then raise exception 'Second user saw private/legacy-owned set'; end if;
end $$;

-- Security: authenticated browser has RPC execution but no direct private-table DML/SELECT.
do $$declare t text; begin
 foreach t in array array['attempts','exposures','question_state','sessions','session_questions','user_notes','flags','demand_sets'] loop
   if has_table_privilege('authenticated','gk.'||t,'SELECT') or has_table_privilege('authenticated','gk.'||t,'INSERT')
      or has_table_privilege('authenticated','gk.'||t,'UPDATE') or has_table_privilege('authenticated','gk.'||t,'DELETE') then
     raise exception 'Authenticated direct table privilege remains on %',t;
   end if;
 end loop;
 if not has_function_privilege('authenticated','public.gk_submit_answer(text,text,boolean,text,text,text,integer)','EXECUTE') then raise exception 'Authenticated submit RPC missing'; end if;
 if has_function_privilege('anon','public.gk_submit_answer(text,text,boolean,text,text,text,integer)','EXECUTE') then raise exception 'Anon can execute submit RPC'; end if;
 if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='gk_submit_answer' and pg_get_function_identity_arguments(p.oid)='p_question_id text, p_selected_option text, p_marked_review boolean, p_attempt_id text, p_mode text, p_session_id text')<>0 then
   raise exception 'Obsolete six-argument submit overload remains';
 end if;
 if not exists(select 1 from pg_policies where schemaname='gk' and tablename='demand_sets' and policyname='gk_demand_sets_own') then raise exception 'Demand-set RLS policy missing'; end if;
end $$;

-- Active question canonical answer invariant.
do $$begin
 begin
   insert into gk.questions(question_id,question,option_a,option_b,option_c,option_d,correct_option,active,content_lane)
   values('Q_BAD_KEY','Bad key','A','B','C','D','not-a-key',true,'MAIN');
   raise exception 'Invalid active correct_option was accepted';
 exception when check_violation then null;
 end;
end $$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);

-- Runtime RPC surface required by the frontend must exist with one unambiguous signature.
do $$declare sig text; begin
 foreach sig in array array[
  'public.gk_submit_answer(text,text,boolean,text,text,text,integer)',
  'public.gk_record_exposure(text,text,text,text)',
  'public.gk_mark_guessed(text,text,boolean,text)',
  'public.gk_set_starred(text,boolean)',
  'public.gk_set_difficult(text,boolean)',
  'public.gk_set_flag(text,boolean,text,text)',
  'public.gk_save_note(text,text)',
  'public.gk_save_session(text,text,text,integer,jsonb,jsonb,text[],boolean,jsonb)',
  'public.gk_get_resume_session()',
  'public.gk_start_daily(integer)',
  'public.gk_create_demand_set(text,integer,text)',
  'public.gk_get_batch(text,integer,text,text,text,text,text,text,integer,text)',
  'public.gk_get_scope_batch(text,integer,text,text,text,text,text,integer,text)',
  'public.gk_get_lecture_part_batch(text,text,integer,integer)',
  'public.gk_get_new_practice_hub()',
  'public.gk_get_starred_hub()',
  'public.gk_get_starred_group_batch(integer,integer,boolean,text,integer)',
  'public.gk_get_guessed_hub()',
  'public.gk_get_on_demand_hub()',
  'public.gk_get_progress()',
  'public.gk_get_question_intelligence(text,text)',
  'public.gk_get_concept_catalog(text,text)',
  'public.gk_get_concept_batch(text,text,text,integer)',
  'public.gk_get_flagged_content()',
  'public.gk_get_catalog()',
  'public.gk_get_home_snapshot()'
 ] loop
   if to_regprocedure(sig) is null then raise exception 'Missing runtime RPC %',sig; end if;
 end loop;
end $$;

select 'GK clean-room runtime assertions passed' as result;
