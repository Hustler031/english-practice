create or replace function maths._render_questions(p_uid uuid,p_ids text[],p_force_memory_reveal boolean default false) returns jsonb language sql stable security definer set search_path=pg_catalog,public,maths as $$
with src as (
  select r.*,u.ord,upper(coalesce(r.correct_option,'')) ckey,upper(coalesce(st.last_correct_option,'')) last_key,
         jsonb_build_object('A',coalesce(r.option_a,''),'B',coalesce(r.option_b,''),'C',coalesce(r.option_c,''),'D',coalesce(r.option_d,'')) omap
  from unnest(p_ids) with ordinality u(id,ord)
  join maths._user_runtime(p_uid) r on r.question_id=u.id
  left join maths.question_state st on st.user_id=p_uid and st.question_id=r.question_id
), rot as (
  select s.*,
    (not p_force_memory_reveal and upper(coalesce(s.answer_mode,''))<>'REVEAL' and s.ckey in('A','B','C','D') and s.last_key=s.ckey) rotate_key,
    case s.ckey when 'A' then 'B' when 'B' then 'C' when 'C' then 'D' when 'D' then 'A' else '' end swap_key
  from src s
)
select coalesce(jsonb_agg(jsonb_build_object(
  'questionId',r.question_id,'chapter',coalesce(r.chapter,''),'topic',coalesce(r.topic,''),'subtopic',coalesce(r.subtopic,''),'majorTopic',coalesce(r.major_topic,''),
  'prompt',r.prompt,'answer',coalesce(r.answer,''),'explanation',coalesce(r.explanation,''),'memoryCue',coalesce(r.memory_cue,''),
  'answerMode',case when p_force_memory_reveal or upper(coalesce(r.answer_mode,''))='REVEAL' or r.ckey not in('A','B','C','D') then 'REVEAL' else 'MCQ' end,
  'options',case when p_force_memory_reveal or upper(coalesce(r.answer_mode,''))='REVEAL' or r.ckey not in('A','B','C','D') then '[]'::jsonb else jsonb_build_array(
    jsonb_build_object('key','A','text',case when r.rotate_key and r.ckey='A' then r.omap->>r.swap_key when r.rotate_key and r.swap_key='A' then r.omap->>r.ckey else r.omap->>'A' end),
    jsonb_build_object('key','B','text',case when r.rotate_key and r.ckey='B' then r.omap->>r.swap_key when r.rotate_key and r.swap_key='B' then r.omap->>r.ckey else r.omap->>'B' end),
    jsonb_build_object('key','C','text',case when r.rotate_key and r.ckey='C' then r.omap->>r.swap_key when r.rotate_key and r.swap_key='C' then r.omap->>r.ckey else r.omap->>'C' end),
    jsonb_build_object('key','D','text',case when r.rotate_key and r.ckey='D' then r.omap->>r.swap_key when r.rotate_key and r.swap_key='D' then r.omap->>r.ckey else r.omap->>'D' end)
  ) end,
  'correctOption',case when p_force_memory_reveal or upper(coalesce(r.answer_mode,''))='REVEAL' or r.ckey not in('A','B','C','D') then '' when r.rotate_key then r.swap_key else r.ckey end,
  'variantType',case when p_force_memory_reveal then 'CALC_RECALL' else coalesce(nullif(r.variant_types,''),nullif(r.template_group,''),'STATIC') end,
  'starred',r.starred,'difficult',r.difficult,'mastered',r.mastered,'inConcept',exists(select 1 from maths.concept_membership c where c.user_id=p_uid and c.question_id=r.question_id and c.active),
  'diagram',case when r.diagram_json is null then null else jsonb_build_object('type',r.diagram_type,'payload',r.diagram_json) end,
  'sourceFile',coalesce(r.source_file,''),'sourcePage',coalesce(r.source_page,'')
) order by r.ord),'[]'::jsonb) from rot r
$$;
revoke all on function maths._render_questions(uuid,text[],boolean) from public,anon,authenticated;


