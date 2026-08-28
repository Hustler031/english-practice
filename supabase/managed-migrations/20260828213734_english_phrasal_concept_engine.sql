create or replace function english.phrasal_question_family(q english.questions)
returns text language sql immutable as $$
select case
  when lower(coalesce(q.question_type,'')) ~ 'reverse\s+recall\s+card' then 'recall'
  when lower(coalesce(q.question_type,'')) ~ 'incorrect|confus|discrimin' then 'confusion'
  else 'recognition' end;
$$;

create or replace function english.phrasal_concepts(p_user_id uuid)
returns table(
  concept_id text, word text, question_count integer, active_variant_count integer,
  fresh_variant_count integer, question_mastered_count integer,
  attempts integer, correct integer, wrong integer, state text, next_review timestamptz,
  proven_mastery boolean, due boolean, starred boolean, difficult boolean,
  revised_count integer, never_revised boolean, last_revision timestamptz,
  days_since_revision integer, recognition_attempts integer, recognition_accuracy numeric,
  recognition_last_correct boolean, recall_attempts integer, recall_success integer,
  recall_confused integer, recall_forgotten integer, recall_last_selected text,
  confusion_attempts integer, confusion_accuracy numeric, confusion_last_correct boolean,
  recognition_strong boolean, recognition_weak boolean, recall_weak boolean,
  confusion_weak boolean, preferred_family text, tier integer
)
language sql stable security definer set search_path='pg_catalog','english','auth' as $$
with qbank as (
  select q.*, coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id) ckey,
         english.phrasal_question_family(q) family,
         coalesce(s.mastered,false) manual_mastered,
         coalesce(s.last_marked,false) q_starred,
         coalesce(d.difficult,false) q_difficult
  from english.questions q
  left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id
  where q.active and (english.canonical_category(q.topic)='PHRASAL' or lower(btrim(coalesce(q.topic,'')))='phrasal verb')
), a0 as (
  select qb.ckey,qb.family,a.*,
         (a.attempted_at at time zone 'Asia/Kolkata')::date study_date,
         row_number() over(partition by qb.ckey,(a.attempted_at at time zone 'Asia/Kolkata')::date order by a.attempted_at,a.source_row nulls last,a.created_at,a.attempt_id) day_rn
  from qbank qb join english.attempts a on a.user_id=p_user_id and a.question_id=qb.question_id
), concept_tot as (
  select ckey,count(*)::int attempts,count(*) filter(where coalesce(correct,false))::int correct,
         count(*) filter(where not coalesce(correct,false))::int wrong
  from a0 group by ckey
), cp0 as (select * from a0 where day_rn=1),
cp as (
  select x.*,row_number() over(partition by ckey order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) rev_no
  from cp0 x
), cpa as (
  select ckey,count(*)::int checkpoint_count,
         count(*) filter(where not coalesce(correct,false))::int checkpoint_wrong,
         array_agg(coalesce(correct,false) order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) results_desc,
         array_agg(study_date order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) dates_desc,
         array_agg(attempted_at order by study_date desc,attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc) times_desc,
         count(*) filter(where rev_no<=4 and not coalesce(correct,false))::int recent_wrong
  from cp group by ckey
), prof0 as (
  select k.ckey,coalesce(t.attempts,0)::int attempts,coalesce(t.correct,0)::int correct,coalesce(t.wrong,0)::int wrong,
         coalesce(c.checkpoint_count,0)::int checkpoint_count,coalesce(c.checkpoint_wrong,0)::int checkpoint_wrong,
         coalesce(c.recent_wrong,0)::int recent_wrong,
         coalesce((select min(i)-1 from generate_subscripts(c.results_desc,1) g(i) where c.results_desc[i]=false),cardinality(c.results_desc),0)::int streak,
         c.results_desc[1] last_checkpoint_correct,c.dates_desc[1] last_checkpoint_date,c.dates_desc[2] previous_checkpoint_date,c.times_desc[1] last_checkpoint_at
  from (select distinct ckey from qbank) k left join concept_tot t using(ckey) left join cpa c using(ckey)
), prof1 as (
  select p.*,
    case when attempts=0 then 'New'
         when last_checkpoint_correct=false then case when recent_wrong>=2 then 'Persistent Weak' else 'Weak' end
         when streak>=4 and previous_checkpoint_date is not null and (last_checkpoint_date-previous_checkpoint_date)>=5 then 'Proven Mastered'
         when streak>=3 then 'Strong'
         when checkpoint_wrong>0 then 'Fragile'
         else 'Learning' end derived_state
  from prof0 p
), prof as (
  select p.*,
    case when attempts=0 or last_checkpoint_at is null then null::timestamptz
         else last_checkpoint_at + make_interval(days=>case derived_state when 'Persistent Weak' then 1 when 'Weak' then 1 when 'Fragile' then case when streak>=2 then 3 else 2 end when 'Learning' then 1 when 'Strong' then 7 when 'Proven Mastered' then 30 else 7 end) end next_review
  from prof1 p
), fam_base as (
  select ckey,family,count(*)::int attempts,count(*) filter(where coalesce(correct,false))::int correct,
         (array_agg(coalesce(correct,false) order by attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc))[1] last_correct,
         (array_agg(upper(coalesce(selected_answer,'')) order by attempted_at desc,source_row desc nulls last,created_at desc,attempt_id desc))[1] last_selected,
         count(*) filter(where upper(coalesce(selected_answer,''))='A')::int selected_a,
         count(*) filter(where upper(coalesce(selected_answer,''))='B')::int selected_b,
         count(*) filter(where upper(coalesce(selected_answer,''))='C')::int selected_c
  from a0 group by ckey,family
), fam as (
 select k.ckey,
   coalesce(r.attempts,0)::int recognition_attempts,case when coalesce(r.attempts,0)>0 then r.correct::numeric/r.attempts else null end recognition_accuracy,r.last_correct recognition_last_correct,
   coalesce(rc.attempts,0)::int recall_attempts,coalesce(rc.selected_a,0)::int recall_success,coalesce(rc.selected_b,0)::int recall_confused,coalesce(rc.selected_c,0)::int recall_forgotten,coalesce(rc.last_selected,'') recall_last_selected,
   coalesce(cf.attempts,0)::int confusion_attempts,case when coalesce(cf.attempts,0)>0 then cf.correct::numeric/cf.attempts else null end confusion_accuracy,cf.last_correct confusion_last_correct
 from (select distinct ckey from qbank) k
 left join fam_base r on r.ckey=k.ckey and r.family='recognition'
 left join fam_base rc on rc.ckey=k.ckey and rc.family='recall'
 left join fam_base cf on cf.ckey=k.ckey and cf.family='confusion'
), variants as (
 select qb.ckey,min(coalesce(qb.word,'')) word,count(*)::int question_count,
        count(*) filter(where not qb.manual_mastered)::int active_variant_count,
        count(*) filter(where not qb.manual_mastered and not exists(select 1 from english.attempts a where a.user_id=p_user_id and a.question_id=qb.question_id))::int fresh_variant_count,
        count(*) filter(where qb.manual_mastered)::int question_mastered_count,
        coalesce(bool_or((not qb.manual_mastered) and qb.q_starred),false) starred,
        coalesce(bool_or((not qb.manual_mastered) and qb.q_difficult),false) difficult
 from qbank qb group by qb.ckey
), rev as (
 select qb.ckey,count(a.*)::int revised_count,max(a.attempted_at) last_revision
 from qbank qb left join english.attempts a on a.user_id=p_user_id and a.question_id=qb.question_id and lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')
 group by qb.ckey
), calc as (
 select v.ckey,v.word,v.question_count,v.active_variant_count,v.fresh_variant_count,v.question_mastered_count,v.starred,v.difficult,
        p.attempts,p.correct,p.wrong,p.derived_state state,p.next_review,(p.derived_state='Proven Mastered') proven_mastery,
        (p.next_review is not null and (p.next_review at time zone 'Asia/Kolkata')::date <= (now() at time zone 'Asia/Kolkata')::date) due,
        r.revised_count,(r.revised_count=0) never_revised,r.last_revision,
        case when r.last_revision is null then null else greatest(0,floor(extract(epoch from (now()-r.last_revision))/86400)::int) end days_since_revision,
        f.recognition_attempts,f.recognition_accuracy,f.recognition_last_correct,f.recall_attempts,f.recall_success,f.recall_confused,f.recall_forgotten,f.recall_last_selected,f.confusion_attempts,f.confusion_accuracy,f.confusion_last_correct,
        (f.recognition_attempts>=2 and f.recognition_accuracy>=.75 and f.recognition_last_correct=true) recognition_strong,
        (f.recognition_attempts>0 and (f.recognition_last_correct=false or f.recognition_accuracy<.7)) recognition_weak,
        (f.recall_attempts>0 and (f.recall_last_selected in ('B','C') or f.recall_success::numeric/f.recall_attempts<.67)) recall_weak,
        (f.confusion_attempts>0 and (f.confusion_last_correct=false or f.confusion_accuracy<.7)) confusion_weak
 from variants v join prof p on p.ckey=v.ckey join fam f on f.ckey=v.ckey join rev r on r.ckey=v.ckey
), pref as (
 select c.*,
   case when recall_weak and recognition_strong then 'recall'
        when recognition_weak then case when confusion_weak then 'confusion' else 'recognition' end
        when recall_weak then 'recall'
        when confusion_weak and recall_attempts>0 and recall_last_selected='A' then 'confusion'
        when recognition_strong and recall_attempts=0 then 'recall'
        else '' end preferred_family
 from calc c
), tiered as (
 select p.*,
   case when due and state='Persistent Weak' then 10
        when due and recall_weak and recognition_strong then 9
        when due and state='Weak' then 8
        when due and state='Fragile' then 7
        when due then 6
        when difficult then 5
        when starred then 4
        when proven_mastery and fresh_variant_count>0 then 3
        when never_revised then 3
        when state in ('Learning','New') then 2 else 1 end tier
 from pref p
)
select ckey as concept_id,word,question_count,active_variant_count,fresh_variant_count,question_mastered_count,attempts,correct,wrong,state,next_review,proven_mastery,due,starred,difficult,revised_count,never_revised,last_revision,days_since_revision,recognition_attempts,recognition_accuracy,recognition_last_correct,recall_attempts,recall_success,recall_confused,recall_forgotten,recall_last_selected,confusion_attempts,confusion_accuracy,confusion_last_correct,recognition_strong,recognition_weak,recall_weak,confusion_weak,preferred_family,tier
from tiered;
$$;

create or replace function english.phrasal_selection_reason(
  p_state text,p_due boolean,p_recall_weak boolean,p_recognition_strong boolean,p_difficult boolean,p_starred boolean,p_mastered boolean,p_fresh integer,p_never boolean,p_days integer,p_lane text
) returns text language sql immutable as $$
select case when p_recall_weak and p_recognition_strong then 'Recall Weak'
 when p_state in ('Persistent Weak','Weak','Fragile') then p_state
 when p_due then 'Due Retention'
 when p_difficult and p_starred then 'Difficult + Starred'
 when p_difficult then 'Difficult'
 when p_starred then 'Starred'
 when p_mastered and p_fresh>0 then 'Fresh Variant Check'
 when p_lane='rotation' and p_never then 'Never / Under-revised'
 when p_lane='rotation' and coalesce(p_days,0)>=7 then 'Longest Not Seen'
 when p_lane='rotation' then 'Healthy Rotation'
 when p_state in ('Learning','New') then 'Learning'
 else 'Rotation' end;
$$;

revoke all on function english.phrasal_concepts(uuid) from public,anon,authenticated;
revoke all on function english.phrasal_question_family(english.questions) from public,anon,authenticated;
revoke all on function english.phrasal_selection_reason(text,boolean,boolean,boolean,boolean,boolean,boolean,integer,boolean,integer,text) from public,anon,authenticated;
