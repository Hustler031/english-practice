create or replace function public.english_get_sprint_picks_library()
returns jsonb
language sql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with subjects(subject,ord) as (values
 ('Grammar',1),('Voice',2),('Narration',3),('Vocabulary',4),('Phrasal Verbs',5),('Idioms & OWS',6),('Spelling & Usage',7)
), ranked as (
 select b.*,row_number() over(partition by b.question_id order by b.saved_at desc,b.source_session_id,b.source_position) rn
 from english.sprint_bank_items b
 where b.user_id=auth.uid() and b.question_id is not null
), rows as (
 select b.subject,b.saved_at,q.question_id,q.topic,q.question,q.option_a,q.option_b,q.option_c,q.option_d,
        upper(q.correct) correct_key,q.explanation,q.question_type,m.concept_id,
        coalesce(st.status,'New') status,coalesce(st.mastered,false) mastered,
        coalesce(st.attempts,0) attempts,coalesce(st.correct,0) correct_count,coalesce(st.wrong,0) wrong_count,
        st.last_attempt,st.next_review,
        case
          when coalesce(st.mastered,false) or coalesce(st.status,'') in ('Mastered','Proven Mastered') then 'Mastered'
          when st.status='Persistent Weak' then 'PW'
          when st.status='Weak' then 'Weak'
          when st.status='Fragile' then 'Fragile'
          when st.status='Learning' then 'Learning'
          when st.status='Strong' then 'Strong'
          else 'New'
        end state_label
 from ranked b
 join english.questions q on q.question_id=b.question_id and q.active
 left join english.question_state st on st.user_id=b.user_id and st.question_id=b.question_id
 left join english.question_concept_mappings m on m.question_id=b.question_id
 where b.rn=1
), subject_counts as (
 select subject,
        count(*)::int total,
        count(*) filter(where state_label='PW')::int pw,
        count(*) filter(where state_label='Weak')::int weak,
        count(*) filter(where state_label='Fragile')::int fragile,
        count(*) filter(where state_label='Learning')::int learning,
        count(*) filter(where state_label='New')::int fresh,
        count(*) filter(where state_label='Strong')::int strong,
        count(*) filter(where state_label='Mastered')::int mastered
 from rows group by subject
)
select case when auth.uid() is null then jsonb_build_object('ok',false,'error','Authentication required') else jsonb_build_object(
 'ok',true,
 'total',(select count(*) from rows),
 'subjects',(select jsonb_agg(jsonb_build_object(
   'subject',s.subject,'count',coalesce(c.total,0),
   'states',jsonb_build_object('PW',coalesce(c.pw,0),'Weak',coalesce(c.weak,0),'Fragile',coalesce(c.fragile,0),'Learning',coalesce(c.learning,0),'New',coalesce(c.fresh,0),'Strong',coalesce(c.strong,0),'Mastered',coalesce(c.mastered,0))
 ) order by s.ord) from subjects s left join subject_counts c on c.subject=s.subject),
 'items',coalesce((select jsonb_agg(jsonb_build_object(
   'id',question_id,'subject',subject,'category',topic,'topic',topic,'question',question,
   'options',jsonb_build_array(
      jsonb_build_object('key','A','text',option_a),jsonb_build_object('key','B','text',option_b),
      jsonb_build_object('key','C','text',option_c),jsonb_build_object('key','D','text',option_d)
   ),
   'correctKey',correct_key,'explanation',explanation,'questionType',question_type,
   'conceptId',concept_id,'status',status,'state',state_label,'mastered',mastered,
   'attempts',attempts,'correct',correct_count,'wrong',wrong_count,'lastAttempt',last_attempt,'nextReview',next_review,
   'savedAt',saved_at,'selectionReason','Saved from SSC Sprint'
 ) order by saved_at desc,question_id) from rows),'[]'::jsonb)
) end;
$function$;

revoke all on function public.english_get_sprint_picks_library() from public;
grant execute on function public.english_get_sprint_picks_library() to authenticated;
