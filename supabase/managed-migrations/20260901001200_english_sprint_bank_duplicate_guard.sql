-- Avoid duplicate per-user Sprint Bank membership when an identical question is saved from more than one Sprint.
create or replace function english.promote_sprint_bank_item(p_uid uuid,p_session_id uuid,p_position integer)
returns text language plpgsql security definer
set search_path=pg_catalog,public,english,auth as $$
declare i english.sprint_items%rowtype; qid text; oa text; ob text; oc text; od text; subj text;
begin
  if p_uid is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from english.sprint_sessions s where s.session_id=p_session_id and s.user_id=p_uid and s.status='completed') then return null; end if;
  if not exists(select 1 from english.sprint_bank_items b where b.user_id=p_uid and b.source_session_id=p_session_id and b.source_position=p_position) then return null; end if;

  select * into i from english.sprint_items where session_id=p_session_id and position=p_position;
  if not found then raise exception 'Sprint item not found'; end if;
  subj:=english.sprint_bank_subject(i.category,i.question_type);

  select q.question_id into qid
  from english.questions q
  where q.active
    and regexp_replace(lower(btrim(q.question)),'\s+',' ','g')=regexp_replace(lower(btrim(i.question)),'\s+',' ','g')
  order by q.created_at asc,q.question_id asc
  limit 1;

  if qid is null then
    qid:='SPBANK_'||replace(substr(p_session_id::text,1,8),'-','')||'_'||lpad(p_position::text,2,'0');
    if not exists(select 1 from english.questions q where q.question_id=qid) then
      oa:=english.sprint_option_text(i.options,'A');ob:=english.sprint_option_text(i.options,'B');oc:=english.sprint_option_text(i.options,'C');od:=english.sprint_option_text(i.options,'D');
      if oa='' or ob='' or oc='' or od='' then raise exception 'Sprint option mapping incomplete at %',p_position; end if;
      insert into english.questions(question_id,topic,question,option_a,option_b,option_c,option_d,correct,explanation,question_type,source_file,concept_id,difficulty,source_id,learning_status,content_status,exam_relevance,active,created_at,updated_at)
      values(qid,i.category,i.question,oa,ob,oc,od,i.correct_key,i.explanation,i.question_type,'GPT SSC Sprint Bank',coalesce(nullif(i.metadata->>'conceptKey',''),qid),'Medium','SprintBank:'||p_session_id::text||':'||p_position::text,'New','Active','SSC CGL User-selected Sprint Bank',true,now(),now());
    end if;
  end if;

  if exists(select 1 from english.sprint_bank_items b where b.user_id=p_uid and b.question_id=qid and not (b.source_session_id=p_session_id and b.source_position=p_position)) then
    delete from english.sprint_bank_items where user_id=p_uid and source_session_id=p_session_id and source_position=p_position;
    return qid;
  end if;

  update english.sprint_bank_items set question_id=qid,subject=subj,promoted_at=coalesce(promoted_at,now()) where user_id=p_uid and source_session_id=p_session_id and source_position=p_position;
  return qid;
end $$;

revoke all on function english.promote_sprint_bank_item(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function english.promote_sprint_bank_item(uuid,uuid,integer) to service_role;
