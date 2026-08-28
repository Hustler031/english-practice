create or replace function public.english_get_phrasal_batch(p_mode text default 'smart',p_count integer default 20)
returns jsonb language plpgsql volatile security definer set search_path='pg_catalog','public','english','auth' as $$
declare uid uuid:=auth.uid();m text:=lower(btrim(coalesce(p_mode,'smart')));n integer:=greatest(1,least(100,coalesce(p_count,20)));eligible_n integer;urgent integer;rotation_n integer;ratio numeric:=.6;learn_target integer;rot_target integer;out jsonb;current_count integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('smart','weak','difficult','starred','random','all') then raise exception 'Unknown Phrasal mode: %',p_mode; end if;
 create temporary table if not exists pg_temp.phrasal_pick(concept_id text primary key,lane text,ord integer) on commit drop;
 truncate pg_temp.phrasal_pick;

 if m='all' then
   insert into pg_temp.phrasal_pick
   select c.concept_id,'rotation',row_number() over(order by (c.fresh_variant_count>0) desc,c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz) asc,c.tier desc,c.due desc,coalesce(c.days_since_revision,1000000000) desc,c.concept_id)::int
   from english.phrasal_concepts(uid) c where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0);
 elsif m='random' then
   insert into pg_temp.phrasal_pick
   select x.concept_id,'learning',x.rn from (
     select c.concept_id,row_number() over(order by random())::int rn
     from english.phrasal_concepts(uid) c where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0)
   ) x order by x.rn limit n;
 elsif m in ('weak','difficult','starred') then
   insert into pg_temp.phrasal_pick
   select x.concept_id,'learning',x.rn from (
     select c.concept_id,row_number() over(order by c.tier desc,c.due desc,coalesce(c.days_since_revision,1000000000) desc,c.concept_id)::int rn
     from english.phrasal_concepts(uid) c
     where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0)
       and (m<>'weak' or c.state in ('Persistent Weak','Weak','Fragile') or c.recall_weak)
       and (m<>'difficult' or c.difficult)
       and (m<>'starred' or c.starred)
   ) x order by x.rn limit n;
 else
   select count(*),count(*) filter(where tier>=4),count(*) filter(where fresh_variant_count>0 or never_revised or coalesce(days_since_revision,0)>=7)
   into eligible_n,urgent,rotation_n from english.phrasal_concepts(uid) where active_variant_count>0 and (not proven_mastery or fresh_variant_count>0);
   n:=least(n,coalesce(eligible_n,0));
   if n=0 then return '[]'::jsonb; end if;
   if urgent<=floor(n*.35) and rotation_n>=ceil(n*.5) then ratio:=.45; elsif urgent>=ceil(n*.75) then ratio:=.7; end if;
   learn_target:=round(n*ratio);rot_target:=n-learn_target;
   insert into pg_temp.phrasal_pick
   select x.concept_id,'learning',x.rn from (
     select c.concept_id,row_number() over(order by c.tier desc,c.due desc,coalesce(c.days_since_revision,1000000000) desc,c.concept_id)::int rn
     from english.phrasal_concepts(uid) c where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0)
   ) x order by x.rn limit learn_target;
   insert into pg_temp.phrasal_pick
   select x.concept_id,'rotation',learn_target+x.rn from (
     select c.concept_id,row_number() over(order by (c.fresh_variant_count>0) desc,c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz) asc,c.tier desc,c.due desc,coalesce(c.days_since_revision,1000000000) desc,c.concept_id)::int rn
     from english.phrasal_concepts(uid) c where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0) and not exists(select 1 from pg_temp.phrasal_pick p where p.concept_id=c.concept_id)
   ) x order by x.rn limit rot_target;
   select count(*) into current_count from pg_temp.phrasal_pick;
   if current_count<n then
     insert into pg_temp.phrasal_pick
     select x.concept_id,'rotation',current_count+x.rn from (
       select c.concept_id,row_number() over(order by (c.fresh_variant_count>0) desc,c.never_revised desc,coalesce(c.last_revision,'epoch'::timestamptz) asc,c.tier desc,c.due desc,coalesce(c.days_since_revision,1000000000) desc,c.concept_id)::int rn
       from english.phrasal_concepts(uid) c where c.active_variant_count>0 and (not c.proven_mastery or c.fresh_variant_count>0) and not exists(select 1 from pg_temp.phrasal_pick p where p.concept_id=c.concept_id)
     ) x order by x.rn limit n-current_count;
   end if;
 end if;

 with chosen as (
   select p.concept_id,p.lane,p.ord,c.state,c.proven_mastery,c.recall_weak,c.recognition_strong,c.preferred_family,c.due,c.difficult,c.starred,c.fresh_variant_count,c.never_revised,c.days_since_revision
   from pg_temp.phrasal_pick p join english.phrasal_concepts(uid) c using(concept_id)
 ), variants as (
   select ch.concept_id,ch.lane,ch.ord,ch.state,ch.proven_mastery,ch.recall_weak,ch.recognition_strong,ch.preferred_family,ch.due,ch.difficult,ch.starred,ch.fresh_variant_count,ch.never_revised,ch.days_since_revision,
          q.question_id,english.phrasal_question_family(q) family,
          count(a.*)::int total_attempts,
          count(a.*) filter(where lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision'))::int module_attempts,
          max(a.attempted_at) filter(where lower(coalesce(a.module,'')) in ('phrasaldaily','phrasalrevision')) last_module_attempt
   from chosen ch join english.questions q on coalesce(nullif(btrim(q.concept_id),''),'PVQ_'||q.question_id)=ch.concept_id and q.active
   left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
   left join english.attempts a on a.user_id=uid and a.question_id=q.question_id
   where not coalesce(s.mastered,false)
   group by ch.concept_id,ch.lane,ch.ord,ch.state,ch.proven_mastery,ch.recall_weak,ch.recognition_strong,ch.preferred_family,ch.due,ch.difficult,ch.starred,ch.fresh_variant_count,ch.never_revised,ch.days_since_revision,q.question_id,q.question_type
 ), ranked as (
   select v.*,row_number() over(partition by concept_id order by case when preferred_family<>'' and family=preferred_family then 0 else 1 end,module_attempts,coalesce(last_module_attempt,'epoch'::timestamptz),total_attempts,question_id) vrn
   from variants v
 ), payload as (
   select r.ord,english.question_payload(uid,r.question_id) || jsonb_build_object(
     'phrasalConceptId',r.concept_id,'phrasalSelectionReason',english.phrasal_selection_reason(r.state,r.due,r.recall_weak,r.recognition_strong,r.difficult,r.starred,r.proven_mastery,r.fresh_variant_count,r.never_revised,r.days_since_revision,r.lane),
     'phrasalSelectionLane',r.lane,'phrasalBaselineState',r.state,'phrasalConceptMastered',r.proven_mastery,
     'phrasalLearningNeed',case when r.preferred_family='' then 'rotation' else r.preferred_family end,
     'phrasalRecallWeak',r.recall_weak,'phrasalQuestionFamily',r.family
   ) j from ranked r where vrn=1
 ) select coalesce(jsonb_agg(j order by ord),'[]'::jsonb) into out from payload;
 return out;
end;
$$;

revoke all on function public.english_get_phrasal_batch(text,integer) from public,anon;
grant execute on function public.english_get_phrasal_batch(text,integer) to authenticated;
