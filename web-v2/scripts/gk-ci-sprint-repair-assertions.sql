\set ON_ERROR_STOP on

DO $$
DECLARE r boolean; def text;
BEGIN
  IF to_regclass('gk.exam_diagnostics') IS NULL THEN RAISE EXCEPTION 'Sprint diagnostics table missing'; END IF;
  FOREACH def IN ARRAY ARRAY[
    'public.gk_start_section_sprint(integer,text)',
    'public.gk_finish_section_sprint(text,jsonb)',
    'public.gk_get_section_sprint_analysis(text)',
    'public.gk_analyze_section_sprint(text)',
    'public.gk_get_sprint_repair_batch(text,text,integer)',
    'public.gk_create_sprint_repair_set(text,text,integer)'
  ] LOOP
    IF to_regprocedure(def) IS NULL THEN RAISE EXCEPTION 'Sprint repair RPC missing: %',def; END IF;
  END LOOP;
  SELECT relrowsecurity INTO r FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='gk' AND c.relname='exam_diagnostics';
  IF coalesce(r,false) IS NOT TRUE THEN RAISE EXCEPTION 'Sprint diagnostics RLS missing'; END IF;
  IF has_table_privilege('authenticated','gk.exam_diagnostics','INSERT') OR has_table_privilege('authenticated','gk.exam_diagnostics','UPDATE') THEN
    RAISE EXCEPTION 'Sprint diagnostic writes must remain RPC-only';
  END IF;
  SELECT pg_get_functiondef('public.gk_finish_section_sprint(text,jsonb)'::regprocedure) INTO def;
  IF def ILIKE '%insert into gk.attempts%' OR def ILIKE '%insert into gk.exposures%' OR def ILIKE '%question_state%' THEN
    RAISE EXCEPTION 'Sprint finalizer leaked into adaptive learning evidence';
  END IF;
  SELECT pg_get_functiondef('public.gk_analyze_section_sprint(text)'::regprocedure) INTO def;
  IF def ILIKE '%insert into gk.attempts%' OR def ILIKE '%insert into gk.exposures%' OR def ILIKE '%question_state%' THEN
    RAISE EXCEPTION 'Sprint analysis leaked into adaptive learning evidence';
  END IF;
END $$;

insert into gk.questions(question_id,question,option_a,option_b,option_c,option_d,correct_option,active,content_lane,subject,topic,concept_id)
values ('Q_ECON_SPRINT','Economy sprint alias','A','B','C','D','A',true,'MAIN','Economy','Alias','C_ECON_SPRINT')
on conflict(question_id) do nothing;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);

insert into gk.exam_sessions(session_id,user_id,mode,question_ids,duration_seconds,source_kind)
values('SPRINT-CI','00000000-0000-0000-0000-000000000001','SECTION_SPRINT','["Q_WEAK","Q_FIRST_WRONG","Q_NEW","Q_ECON_SPRINT"]'::jsonb,900,'EXAM_MIXED')
on conflict(session_id) do nothing;

create temporary table sprint_counts_before as
select (select count(*) from gk.attempts where user_id=auth.uid()) attempts,
       (select count(*) from gk.exposures where user_id=auth.uid()) exposures;

select public.gk_finish_section_sprint('SPRINT-CI','{
  "Q_WEAK":{"selected":"B","correct":false,"responseMs":35000},
  "Q_FIRST_WRONG":{"selected":"A","correct":true,"responseMs":5000}
}'::jsonb);
select public.gk_finish_section_sprint('SPRINT-CI','{
  "Q_WEAK":{"selected":"A","correct":true,"responseMs":1000}
}'::jsonb);

DO $$
DECLARE r jsonb; a integer; e integer;
BEGIN
  IF (select count(*) from gk.exam_answers where session_id='SPRINT-CI')<>2 THEN RAISE EXCEPTION 'Sprint answers are not exactly-once'; END IF;
  SELECT result INTO r FROM gk.exam_sessions WHERE session_id='SPRINT-CI';
  IF (r->>'correct')::int<>1 OR (r->>'wrong')::int<>1 OR (r->>'unattempted')::int<>2 THEN RAISE EXCEPTION 'Sprint result counts wrong: %',r; END IF;
  IF (r->>'score')::numeric<>1.5 OR (r->>'maxScore')::numeric<>8 THEN RAISE EXCEPTION 'Sprint scoring wrong: %',r; END IF;
  IF (r->>'marksLostWrong')::numeric<>0.5 OR (r->>'marksLostUnattempted')::numeric<>4 THEN RAISE EXCEPTION 'Marks-lost math wrong: %',r; END IF;
  SELECT count(*) INTO a FROM gk.attempts WHERE user_id=auth.uid();
  SELECT count(*) INTO e FROM gk.exposures WHERE user_id=auth.uid();
  IF a<>(select attempts from sprint_counts_before) OR e<>(select exposures from sprint_counts_before) THEN RAISE EXCEPTION 'Sprint mutated adaptive Attempts/Exposures'; END IF;
END $$;

select public.gk_analyze_section_sprint('SPRINT-CI');
select public.gk_analyze_section_sprint('SPRINT-CI');

DO $$
DECLARE analysis jsonb; c1 integer; c2 integer; before_n integer; after_n integer; repair jsonb;
BEGIN
  SELECT count(*) INTO before_n FROM gk.exam_diagnostics WHERE session_id='SPRINT-CI';
  PERFORM public.gk_analyze_section_sprint('SPRINT-CI');
  SELECT count(*) INTO after_n FROM gk.exam_diagnostics WHERE session_id='SPRINT-CI';
  IF before_n<>after_n OR before_n=0 THEN RAISE EXCEPTION 'Sprint diagnostics are not idempotent'; END IF;
  IF (select count(*) from gk.exam_diagnostics where session_id='SPRINT-CI' group by session_id having count(*)<>count(distinct concept_key)) IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate concept recommendations detected';
  END IF;
  SELECT priority_score INTO c1 FROM gk.exam_diagnostics WHERE session_id='SPRINT-CI' AND concept_key='C5';
  SELECT priority_score INTO c2 FROM gk.exam_diagnostics WHERE session_id='SPRINT-CI' AND concept_key='C1';
  IF coalesce(c1,0)<=coalesce(c2,0) THEN RAISE EXCEPTION 'Existing Weak + wrong concept should outrank isolated unattempted concept: % <= %',c1,c2; END IF;
  analysis:=public.gk_get_section_sprint_analysis('SPRINT-CI');
  IF coalesce((analysis->>'analysisReady')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'Analysis not marked ready'; END IF;
  IF NOT EXISTS(select 1 from jsonb_array_elements(analysis->'subjects') s where s->>'subject'='Economics') THEN
    RAISE EXCEPTION 'Sprint subject analysis did not use canonical Economics alias: %',analysis->'subjects';
  END IF;
  IF EXISTS(select 1 from jsonb_array_elements(analysis->'questionIssues') q where q->>'classification' in('careless','guessed','confused')) THEN
    RAISE EXCEPTION 'Sprint timing analysis made unsupported psychological claims';
  END IF;
  repair:=public.gk_create_sprint_repair_set('SPRINT-CI','C5',6);
  IF coalesce((repair->>'ok')::boolean,false) IS NOT TRUE OR nullif(repair->>'setId','') IS NULL THEN RAISE EXCEPTION 'Per-concept repair set creation failed: %',repair; END IF;
  IF (select count(*) from gk.attempts where user_id=auth.uid())<>(select attempts from sprint_counts_before)
     OR (select count(*) from gk.exposures where user_id=auth.uid())<>(select exposures from sprint_counts_before) THEN
    RAISE EXCEPTION 'Repair selection mutated adaptive evidence before learner entered quiz';
  END IF;
END $$;

-- Other users cannot read or analyze this user's Sprint diagnostics.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
DO $$
DECLARE x jsonb;
BEGIN
  x:=public.gk_get_section_sprint_analysis('SPRINT-CI');
  IF coalesce((x->>'ok')::boolean,true) IS NOT FALSE THEN RAISE EXCEPTION 'Cross-user Sprint analysis read leaked'; END IF;
  IF exists(select 1 from gk.exam_diagnostics where session_id='SPRINT-CI') THEN RAISE EXCEPTION 'RLS leaked another user diagnostics'; END IF;
END $$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
DO $$
DECLARE d jsonb;
BEGIN
  d:=public.gk_get_intelligence_dashboard();
  IF NOT EXISTS(select 1 from jsonb_array_elements(d->'subjects') x where x ? 'evidenceConfidence') THEN
    RAISE EXCEPTION 'Progress evidence-confidence field missing';
  END IF;
END $$;

SELECT 'GK Sprint repair clean-room assertions passed' AS status;
