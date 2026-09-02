-- Lightweight Home/Revision count surface. Do not fold Targeted detail into the Home snapshot.
create or replace function public.english_get_targeted_summary()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','english','auth'
as $$
with uid as(select auth.uid() id),
base as(
  select r.question_id,m.concept_id,r.metadata,r.origins,ce.next_review,
    case
      when coalesce(r.metadata->>'targeted_kind','')='confusion'
        or 'Learner Context'=any(coalesce(r.origins,'{}'::text[]))
        or 'Learner Context Related'=any(coalesce(r.origins,'{}'::text[])) then 'confusion'
      when coalesce(r.metadata->>'targeted_kind','')='transfer_check'
        or 'I Guessed'=any(coalesce(r.origins,'{}'::text[]))
        or 'AI Transfer'=any(coalesce(r.origins,'{}'::text[])) then 'transfer_check'
      when coalesce(r.metadata->>'targeted_kind','')='retention_check' then 'retention_check'
      else 'need_learning'
    end kind
  from uid
  join english.learning_route_state r on r.user_id=uid.id and r.route='targeted'
  join english.questions q on q.question_id=r.question_id and q.active and english.question_visible_to_user(uid.id,q.question_id)
  left join english.question_concept_mappings m on m.question_id=r.question_id
  left join english.concept_evidence ce on ce.user_id=uid.id and ce.concept_id=m.concept_id
), dedup as(
  select b.*,row_number() over(partition by coalesce(b.concept_id,b.question_id) order by
    case b.kind when 'confusion' then 1 when 'need_learning' then 2 when 'transfer_check' then 3 else 4 end) rn
  from base b
), current as(select * from dedup where rn=1),
conf as(
  select count(*)::int n
  from uid join english.learner_confusions c on c.user_id=uid.id
  where c.status<>'resolved'
)
select case when uid.id is null then jsonb_build_object('ok',false,'error','Authentication required') else
  jsonb_build_object(
    'ok',true,
    'active',(select count(*) from current),
    'dueNow',(select count(*) from current where next_review is null or next_review<=now()),
    'confusions',(select n from conf),
    'needLearning',(select count(*) from current where kind='need_learning'),
    'transferChecks',(select count(*) from current where kind='transfer_check'),
    'retentionChecks',(select count(*) from current where kind='retention_check')
  )
end from uid;
$$;
revoke all on function public.english_get_targeted_summary() from public,anon;
grant execute on function public.english_get_targeted_summary() to authenticated,service_role;
