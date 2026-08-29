-- Exact concept-level academic practice without introducing a second selector.
-- The wrapper delegates eligibility/ranking to the canonical gk_get_batch for each
-- subject/topic scope that contains the concept, then filters the exact concept_id.

create or replace function public.gk_get_concept_batch(
 p_concept_id text,
 p_lane text default 'MIXED',
 p_mode text default 'all',
 p_count integer default 20
) returns jsonb
language sql volatile security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), scopes as(
  select distinct q.subject,q.topic
  from gk.questions q
  where q.active and q.concept_id=p_concept_id
), expanded as(
  select x.item,x.ord
  from scopes s
  cross join lateral jsonb_array_elements(
    public.gk_get_batch(p_mode,100,p_lane,s.subject,s.topic,null,null,null,null,null)
  ) with ordinality x(item,ord)
), exact as(
  select item,min(ord)::bigint ord
  from expanded
  where item->>'concept_id'=p_concept_id
  group by item
  order by min(ord),item->>'id'
  limit greatest(1,least(100,coalesce(p_count,20)))
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else coalesce(jsonb_agg(item order by ord,item->>'id'),'[]'::jsonb) end
from exact;
$$;

create or replace function public.gk_get_concept_catalog(
 p_subject text default null,
 p_topic text default null
) returns jsonb
language sql stable security definer
set search_path=pg_catalog,public,gk,auth
as $$
with u as(select auth.uid() uid), rows as(
 select q.concept_id,q.subject,q.topic,
   count(*)::int total,
   count(*) filter(where q.content_lane='MAIN')::int main,
   count(*) filter(where q.content_lane='RAPID')::int rapid,
   count(*) filter(where coalesce(s.learning_status,'New') in ('Persistent Weak','Weak','Fragile'))::int weak,
   count(*) filter(where coalesce(s.exposure_count,0)=0)::int unseen,
   count(*) filter(where coalesce(s.learning_status,'New')='Proven Mastered')::int mastered
 from gk.questions q cross join u
 left join gk.question_state s on s.user_id=u.uid and s.question_id=q.question_id
 where q.active and nullif(btrim(q.concept_id),'') is not null
   and (p_subject is null or q.subject=p_subject)
   and (p_topic is null or q.topic=p_topic)
 group by q.concept_id,q.subject,q.topic
)
select case when (select uid from u) is null then jsonb_build_object('ok',false,'error','Authentication required')
 else jsonb_build_object('ok',true,'concepts',coalesce((select jsonb_agg(jsonb_build_object(
   'conceptId',concept_id,'subject',subject,'topic',topic,'total',total,'main',main,'rapidRecall',rapid,'weak',weak,'unseen',unseen,'mastered',mastered
 ) order by subject,topic,concept_id) from rows),'[]'::jsonb)) end;
$$;

revoke execute on function public.gk_get_concept_batch(text,text,text,integer) from public, anon;
revoke execute on function public.gk_get_concept_catalog(text,text) from public, anon;
grant execute on function public.gk_get_concept_batch(text,text,text,integer) to authenticated;
grant execute on function public.gk_get_concept_catalog(text,text) to authenticated;
