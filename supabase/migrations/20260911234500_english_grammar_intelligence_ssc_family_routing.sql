-- ENGLISH V2 — Grammar Intelligence: SSC family-routing repair
--
-- Problem fixed:
-- 1. First exposure was effectively biased to context_fill.
-- 2. Weak rules were explicitly preferred as context_fill.
-- 3. Curriculum rows with a narrow supported_families list could leave GPT with no
--    legal SSC surface other than a filler, even though sentence improvement and
--    error detection are generic presentation surfaces for atomic grammar rules.
--
-- Design:
-- - Grammar Intelligence remains authoritative for the rule and legal family set.
-- - context_fill, sentence_improvement and error_detection are treated as universal
--   SSC grammar surfaces for an atomic grammar rule.
-- - direct_fill is retained only when curriculum explicitly supports it.
-- - transformation / contrast / transfer remain opt-in curriculum capabilities.
-- - weak/new rules are no longer hard-wired to context_fill.

create or replace function english.grammar_allowed_families(
  p_supported text[],
  p_selection_count integer,
  p_state text
)
returns text[]
language plpgsql
immutable
set search_path to 'pg_catalog'
as $function$
declare
  v_supported text[] := coalesce(p_supported,array[]::text[]);
  v_capabilities text[] := array[]::text[];
  v_plan text[] := array[]::text[];
  outv text[] := array[]::text[];
  f text;
begin
  -- These are presentation surfaces, not separate grammar concepts. Any verified
  -- atomic grammar rule can be tested naturally through them.
  foreach f in array array['context_fill','sentence_improvement','error_detection'] loop
    if not (f=any(v_capabilities)) then
      v_capabilities:=array_append(v_capabilities,f);
    end if;
  end loop;

  -- Direct fill remains curriculum-controlled because it is intentionally the
  -- easiest / most recognition-heavy surface.
  if 'direct_fill'=any(v_supported) then
    v_capabilities:=array_append(v_capabilities,'direct_fill');
  end if;

  -- Higher-order surfaces remain curriculum-controlled.
  foreach f in array array['transformation','contrast','transfer'] loop
    if f=any(v_supported) and not (f=any(v_capabilities)) then
      v_capabilities:=array_append(v_capabilities,f);
    end if;
  end loop;

  -- Progression controls which of the legal capabilities the planner may use now.
  -- No state is allowed to collapse automatically to context_fill only.
  if coalesce(p_state,'')='weak' then
    v_plan:=array['sentence_improvement','error_detection','context_fill','direct_fill'];
  elsif coalesce(p_selection_count,0)<=0 then
    v_plan:=array['context_fill','sentence_improvement','error_detection','direct_fill'];
  elsif p_selection_count=1 then
    v_plan:=array['sentence_improvement','error_detection','context_fill','direct_fill'];
  elsif p_selection_count=2 then
    v_plan:=array['error_detection','sentence_improvement','contrast','context_fill','direct_fill'];
  elsif p_selection_count=3 then
    v_plan:=array['error_detection','transformation','contrast','sentence_improvement','context_fill'];
  else
    v_plan:=array['transfer','contrast','error_detection','transformation','sentence_improvement','context_fill'];
  end if;

  foreach f in array v_plan loop
    if f=any(v_capabilities) and not (f=any(outv)) then
      outv:=array_append(outv,f);
    end if;
  end loop;

  if cardinality(outv)=0 then
    outv:=v_capabilities;
  end if;

  return outv;
end
$function$;

create or replace function english.grammar_preferred_family(
  p_supported text[],
  p_selection_count integer,
  p_state text
)
returns text
language plpgsql
immutable
set search_path to 'pg_catalog'
as $function$
declare
  a text[]:=english.grammar_allowed_families(p_supported,p_selection_count,p_state);
begin
  -- Preferred is guidance only. The ChatGPT planner may choose another member of
  -- allowedQuestionFamilies when batch diversity or pedagogy makes it better.
  if coalesce(p_state,'')='weak' then
    if 'sentence_improvement'=any(a) then return 'sentence_improvement';
    elsif 'error_detection'=any(a) then return 'error_detection';
    elsif 'context_fill'=any(a) then return 'context_fill';
    elsif 'direct_fill'=any(a) then return 'direct_fill';
    end if;
  end if;

  if coalesce(p_selection_count,0)<=0 then
    -- New rules should still be accessible, but no longer default every rule to a filler.
    if 'sentence_improvement'=any(a) then return 'sentence_improvement';
    elsif 'context_fill'=any(a) then return 'context_fill';
    elsif 'error_detection'=any(a) then return 'error_detection';
    end if;
  elsif p_selection_count=1 then
    if 'error_detection'=any(a) then return 'error_detection';
    elsif 'sentence_improvement'=any(a) then return 'sentence_improvement';
    elsif 'context_fill'=any(a) then return 'context_fill';
    end if;
  elsif p_selection_count=2 then
    if 'error_detection'=any(a) then return 'error_detection';
    elsif 'contrast'=any(a) then return 'contrast';
    elsif 'sentence_improvement'=any(a) then return 'sentence_improvement';
    end if;
  elsif p_selection_count=3 then
    if 'transformation'=any(a) then return 'transformation';
    elsif 'contrast'=any(a) then return 'contrast';
    elsif 'error_detection'=any(a) then return 'error_detection';
    elsif 'sentence_improvement'=any(a) then return 'sentence_improvement';
    end if;
  else
    if 'transfer'=any(a) then return 'transfer';
    elsif 'contrast'=any(a) then return 'contrast';
    elsif 'error_detection'=any(a) then return 'error_detection';
    elsif 'transformation'=any(a) then return 'transformation';
    elsif 'sentence_improvement'=any(a) then return 'sentence_improvement';
    elsif 'context_fill'=any(a) then return 'context_fill';
    end if;
  end if;

  return coalesce(a[1],'sentence_improvement');
end
$function$;

comment on function english.grammar_allowed_families(text[],integer,text) is
'Grammar Intelligence family allowance. Core SSC surfaces (context fill, sentence improvement, error detection) are universally legal for atomic grammar rules; higher-order surfaces remain curriculum-controlled.';

comment on function english.grammar_preferred_family(text[],integer,text) is
'Grammar Intelligence preferred family progression. Preference is advisory inside allowedQuestionFamilies and must not be treated as a hard family lock.';
