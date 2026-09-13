-- Usage-first Phrasal intelligence. Contextual usage keeps the existing internal
-- family name `context_fill` so all current ingest/publisher contracts remain compatible.

create or replace function english.phrasal_concepts_v2(p_user_id uuid)
returns table(
  concept_id text, word text, active_variant_count integer, fresh_variant_count integer,
  state text, next_review timestamptz, proven_mastery boolean, due boolean, starred boolean, difficult boolean,
  revised_count integer, never_revised boolean, last_revision timestamptz, days_since_revision integer,
  recognition_attempts integer, recognition_accuracy numeric, recognition_last_correct boolean,
  usage_attempts integer, usage_accuracy numeric, usage_last_correct boolean,
  recall_attempts integer, recall_success integer, recall_confused integer, recall_forgotten integer, recall_last_selected text,
  confusion_attempts integer, confusion_accuracy numeric, confusion_last_correct boolean,
  recognition_strong boolean, recognition_weak boolean, usage_strong boolean, usage_weak boolean,
  recall_weak boolean, confusion_weak boolean, preferred_family text, tier integer
)
language sql stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
with base as materialized (select * from english.phrasal_concepts(p_user_id)),
qbank as materialized (
  select q.question_id,coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id) concept_id,
         english.phrasal_effective_family(q) family
  from english.questions q
  where q.active and english.question_visible_to_user(p_user_id,q.question_id)
    and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
),
fam_base as materialized (
  select qb.concept_id,qb.family,count(a.*)::int attempts,
         count(a.*) filter(where coalesce(a.correct,false))::int correct,
         (array_agg(coalesce(a.correct,false) order by a.attempted_at desc,a.source_row desc nulls last,a.created_at desc,a.attempt_id desc))[1] last_correct,
         (array_agg(upper(coalesce(a.selected_answer,'')) order by a.attempted_at desc,a.source_row desc nulls last,a.created_at desc,a.attempt_id desc))[1] last_selected,
         count(a.*) filter(where upper(coalesce(a.selected_answer,''))='A')::int selected_a,
         count(a.*) filter(where upper(coalesce(a.selected_answer,''))='B')::int selected_b,
         count(a.*) filter(where upper(coalesce(a.selected_answer,''))='C')::int selected_c
  from qbank qb join english.attempts a on a.user_id=p_user_id and a.question_id=qb.question_id
  group by qb.concept_id,qb.family
),
fam as (
  select b.concept_id,
    coalesce(r.attempts,0)::int recognition_attempts,
    case when coalesce(r.attempts,0)>0 then r.correct::numeric/r.attempts end recognition_accuracy,r.last_correct recognition_last_correct,
    coalesce(u.attempts,0)::int usage_attempts,
    case when coalesce(u.attempts,0)>0 then u.correct::numeric/u.attempts end usage_accuracy,u.last_correct usage_last_correct,
    coalesce(rc.attempts,0)::int recall_attempts,coalesce(rc.selected_a,0)::int recall_success,
    coalesce(rc.selected_b,0)::int recall_confused,coalesce(rc.selected_c,0)::int recall_forgotten,coalesce(rc.last_selected,'') recall_last_selected,
    coalesce(cf.attempts,0)::int confusion_attempts,
    case when coalesce(cf.attempts,0)>0 then cf.correct::numeric/cf.attempts end confusion_accuracy,cf.last_correct confusion_last_correct
  from base b
  left join fam_base r on r.concept_id=b.concept_id and r.family='recognition'
  left join fam_base u on u.concept_id=b.concept_id and u.family='context_fill'
  left join fam_base rc on rc.concept_id=b.concept_id and rc.family='recall'
  left join fam_base cf on cf.concept_id=b.concept_id and cf.family='confusion'
),
signals as (
  select b.concept_id,b.word,b.active_variant_count,b.fresh_variant_count,b.state,b.next_review,
         b.proven_mastery,b.due,b.starred,b.difficult,b.revised_count,b.never_revised,b.last_revision,b.days_since_revision,
         f.recognition_attempts,f.recognition_accuracy,f.recognition_last_correct,f.usage_attempts,f.usage_accuracy,f.usage_last_correct,
         f.recall_attempts,f.recall_success,f.recall_confused,f.recall_forgotten,f.recall_last_selected,
         f.confusion_attempts,f.confusion_accuracy,f.confusion_last_correct,
         (f.recognition_attempts>=2 and coalesce(f.recognition_accuracy,0)>=.75 and f.recognition_last_correct=true) recognition_strong,
         (f.recognition_attempts>0 and (f.recognition_last_correct=false or coalesce(f.recognition_accuracy,0)<.70)) recognition_weak,
         (f.usage_attempts>=2 and coalesce(f.usage_accuracy,0)>=.75 and f.usage_last_correct=true) usage_strong,
         (f.usage_attempts>0 and (f.usage_last_correct=false or coalesce(f.usage_accuracy,0)<.75)) usage_weak,
         (f.recall_attempts>0 and (f.recall_last_selected in ('B','C') or f.recall_success::numeric/nullif(f.recall_attempts,0)<.67)) recall_weak,
         (f.confusion_attempts>0 and (f.confusion_last_correct=false or coalesce(f.confusion_accuracy,0)<.70)) confusion_weak
  from base b join fam f using(concept_id)
),
pref as (
  select s.*,
    case when s.recognition_weak then 'recognition' when s.usage_weak then 'context_fill'
         when s.confusion_weak then 'confusion' when s.recall_weak then 'recall'
         when s.recognition_strong and s.usage_attempts=0 then 'context_fill'
         when s.recognition_strong and s.recall_attempts=0 then 'recall'
         when s.recognition_strong and s.usage_strong and s.confusion_attempts=0 then 'confusion'
         when s.due and s.state in ('Strong','Fragile','Learning') then 'context_fill' else '' end preferred_family_v2,
    case when s.state='Persistent Weak' then 10
         when s.recognition_weak or s.usage_weak or s.recall_weak or s.confusion_weak then 9
         when s.state='Weak' then 8 when s.state='Fragile' then 7 when s.due then 6
         when s.difficult then 5 when s.starred then 4 when s.never_revised or s.state='New' then 3 else 1 end tier_v2
  from signals s
)
select concept_id,word,active_variant_count,fresh_variant_count,state,next_review,proven_mastery,due,starred,difficult,
       revised_count,never_revised,last_revision,days_since_revision,
       recognition_attempts,recognition_accuracy,recognition_last_correct,usage_attempts,usage_accuracy,usage_last_correct,
       recall_attempts,recall_success,recall_confused,recall_forgotten,recall_last_selected,
       confusion_attempts,confusion_accuracy,confusion_last_correct,
       recognition_strong,recognition_weak,usage_strong,usage_weak,recall_weak,confusion_weak,preferred_family_v2,tier_v2
from pref;
$function$;

create or replace function public.english_get_phrasal_learning_analysis()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); out jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select jsonb_build_object(
    'version','usage_first_v2','concepts',count(*),'strongOrMastered',count(*) filter(where state in ('Strong','Proven Mastered')),
    'recognitionWeak',count(*) filter(where recognition_weak),'usageWeak',count(*) filter(where usage_weak),
    'recallWeak',count(*) filter(where recall_weak),'confusionWeak',count(*) filter(where confusion_weak),
    'recognitionAttempts',sum(recognition_attempts),'usageAttempts',sum(usage_attempts),
    'recallAttempts',sum(recall_attempts),'confusionAttempts',sum(confusion_attempts)
  ) into out from english.phrasal_concepts_v2(uid);
  return out;
end;
$function$;
grant execute on function public.english_get_phrasal_learning_analysis() to authenticated;