-- Production hotfix: PostgreSQL raised `column reference "next_review" is ambiguous`
-- inside english.targeted_filter_batch().  The PL/pgSQL variable name collided
-- with a joined table column.  Keep the same cooldown semantics and rename only
-- the local variable so Focused Targeted sessions remain deterministic.

create or replace function english.targeted_filter_batch(
  p_user_id uuid,
  p_rows jsonb,
  p_count integer,
  p_exclude text[] default '{}'::text[]
) returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','english','auth'
as $function$
declare
  item jsonb;
  qid text;
  cid text;
  kind text;
  v_next_review timestamptz;
  alt text;
  meta jsonb;
  outv jsonb:='[]'::jsonb;
  n integer:=greatest(1,least(30,coalesce(p_count,15)));
  excludes text[]:=coalesce(p_exclude,'{}'::text[]);
begin
  if p_user_id is null then raise exception 'Authentication required'; end if;

  for item in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    exit when jsonb_array_length(outv)>=n;
    qid:=coalesce(nullif(item->>'id',''),nullif(item->>'question_id',''),nullif(item->>'questionId',''));
    cid:=nullif(item->>'conceptId','');
    kind:=lower(coalesce(item->>'targetedKind','need_learning'));
    begin
      v_next_review:=nullif(item->>'conceptNextReview','')::timestamptz;
    exception when others then
      v_next_review:=null;
    end;
    if qid is null then continue; end if;

    alt:=null;
    if qid=any(excludes) or english.targeted_question_in_cooldown(p_user_id,qid,v_next_review) then
      if cid is not null and kind in('confusion','transfer_check','need_learning') then
        select q2.question_id into alt
        from english.questions q2
        join english.question_concept_mappings m2 on m2.question_id=q2.question_id
        left join english.question_state s2 on s2.user_id=p_user_id and s2.question_id=q2.question_id
        left join english.question_quality_metrics qm2 on qm2.user_id=p_user_id and qm2.question_id=q2.question_id
        where m2.concept_id=cid
          and q2.active
          and english.question_visible_to_user(p_user_id,q2.question_id)
          and q2.question_id<>qid
          and not(q2.question_id=any(excludes))
          and not coalesce(s2.mastered,false)
          and not english.targeted_question_in_cooldown(p_user_id,q2.question_id,v_next_review)
          and not exists(
            select 1 from jsonb_array_elements(outv) z
            where coalesce(z->>'id',z->>'question_id',z->>'questionId')=q2.question_id
          )
        order by
          coalesce(qm2.too_easy,false),
          coalesce(qm2.observed_difficulty,0.5) desc,
          coalesce(s2.last_attempt,'epoch'::timestamptz),
          q2.question_id
        limit 1;
      end if;

      -- Never force-fill by replaying the same exact item. Underfill is safer.
      if alt is null then continue; end if;
      meta:=item-array[
        'id','question_id','questionId','category','topic','word','question','options',
        'correctKey','correct_key','explanation','questionType','question_type','subtopic','difficulty'
      ]::text[];
      item:=english.question_payload(p_user_id,alt)||meta||jsonb_build_object('deliveryAlternate',true);
      qid:=alt;
    end if;

    if not(qid=any(excludes))
       and not exists(
         select 1 from jsonb_array_elements(outv) z
         where coalesce(z->>'id',z->>'question_id',z->>'questionId')=qid
       ) then
      outv:=outv||jsonb_build_array(item);
    end if;
  end loop;
  return outv;
end
$function$;
