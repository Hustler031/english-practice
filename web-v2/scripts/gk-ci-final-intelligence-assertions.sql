\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('gk.content_series') IS NULL OR to_regclass('gk.question_source_memberships') IS NULL THEN
    RAISE EXCEPTION 'Teacher series/source-membership foundation missing';
  END IF;
  IF to_regclass('gk.question_enrichments') IS NULL OR to_regclass('gk.concept_confusions') IS NULL THEN
    RAISE EXCEPTION 'GPT enrichment/confusion support foundation missing';
  END IF;
  IF to_regclass('gk.exam_sessions') IS NULL OR to_regclass('gk.exam_answers') IS NULL THEN
    RAISE EXCEPTION 'Isolated Section Sprint evidence store missing';
  END IF;
  IF to_regprocedure('public.gk_get_intelligence_dashboard()') IS NULL THEN RAISE EXCEPTION 'Intelligence dashboard RPC missing'; END IF;
  IF to_regprocedure('public.gk_get_teacher_library()') IS NULL THEN RAISE EXCEPTION 'Teacher library RPC missing'; END IF;
  IF to_regprocedure('public.gk_get_teacher_batch(text,text,text,integer,text)') IS NULL THEN RAISE EXCEPTION 'Teacher selector RPC missing'; END IF;
  IF to_regprocedure('public.gk_get_knowledge_story(text,text)') IS NULL THEN RAISE EXCEPTION 'Knowledge Story RPC missing'; END IF;
  IF to_regprocedure('public.gk_get_sprint_plan()') IS NULL THEN RAISE EXCEPTION 'Sprint plan RPC missing'; END IF;
  IF to_regprocedure('public.gk_start_section_sprint(integer)') IS NULL OR to_regprocedure('public.gk_finish_section_sprint(text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Section Sprint RPC contract missing';
  END IF;
END $$;

DO $$
DECLARE r boolean;
BEGIN
  SELECT bool_and(c.relrowsecurity) INTO r
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='gk' AND c.relname IN('content_series','question_source_memberships','question_enrichments','concept_confusions','canonical_duplicate_review','exam_sessions','exam_answers');
  IF coalesce(r,false) IS NOT TRUE THEN RAISE EXCEPTION 'New GK intelligence tables must have RLS enabled'; END IF;

  IF has_table_privilege('authenticated','gk.exam_sessions','INSERT') OR has_table_privilege('authenticated','gk.exam_answers','INSERT') THEN
    RAISE EXCEPTION 'Exam evidence writes must remain RPC-only';
  END IF;
  IF has_table_privilege('authenticated','gk.canonical_duplicate_review','SELECT') THEN
    RAISE EXCEPTION 'Duplicate-review evidence must remain maintainer-only';
  END IF;
END $$;

DO $$
DECLARE a text; b text;
BEGIN
  IF gk.canonical_subject('Art and Culture') <> 'Art & Culture' THEN RAISE EXCEPTION 'Art & Culture taxonomy alias failed'; END IF;
  IF gk.canonical_subject('Economy') <> 'Economics' THEN RAISE EXCEPTION 'Economics taxonomy alias failed'; END IF;
  a:=gk.question_fingerprint('Which statement is correct?',array['Alpha','Beta','Gamma','Delta']);
  b:=gk.question_fingerprint('Which statement is correct?',array['One','Two','Three','Four']);
  IF a=b THEN RAISE EXCEPTION 'Fingerprint must not dedupe generic stems without matching option evidence'; END IF;
  IF gk.question_fingerprint('  Test   stem ',array['B','A']) <> gk.question_fingerprint('test stem',array['A','B']) THEN
    RAISE EXCEPTION 'Fingerprint normalization/order independence failed';
  END IF;
END $$;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM gk.content_series WHERE series_id IN('TEACHER_TOPIC_PYQ','TEACHER_MIXED_PYQ','GPT_BOOSTER');
  IF n<>3 THEN RAISE EXCEPTION 'Required Topic/Mixed/GPT Booster series rows missing'; END IF;
END $$;

SELECT 'GK final intelligence clean-room assertions passed' AS status;
