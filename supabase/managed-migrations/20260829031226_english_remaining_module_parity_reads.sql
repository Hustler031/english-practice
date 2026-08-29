create or replace function public.english_get_bank_coverage_batch(p_category text, p_count integer default 10)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); v_cat text:=upper(btrim(coalesce(p_category,'ALL'))); v_n integer:=greatest(1,least(100,coalesce(p_count,10))); out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with base as (
   select q.question_id,english.learning_category(q.topic) cat,
          row_number() over(partition by english.learning_category(q.topic) order by q.question_id)::int cat_ord
   from english.questions q
   left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
   where english.is_genuine_bank_question(q)
     and (v_cat='ALL' or english.learning_category(q.topic)=v_cat)
     and coalesce(s.attempts,0)=0 and not coalesce(s.mastered,false)
 ), chosen as (
   select question_id,row_number() over(order by case when v_cat='ALL' then cat_ord else 0 end,cat,question_id)::int ord
   from base
   order by case when v_cat='ALL' then cat_ord else 0 end,cat,question_id
   limit v_n
 )
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end $function$;

create or replace function public.english_get_topic_items(p_category text)
returns jsonb
language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',q.question_id,'question_id',q.question_id,'word',coalesce(q.word,''),'question',coalesce(q.question,''),
 'weak',coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile') or coalesce(s.wrong,0)>0,
 'started',coalesce(s.attempts,0)>0,'attempts',coalesce(s.attempts,0),'status',coalesce(s.status,'New'),
 'subtopic',coalesce(q.subtopic,''),'source',coalesce(q.source_file,'')
) order by q.question_id),'[]'::jsonb) end
from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
where q.active and not coalesce(s.mastered,false) and english.canonical_category(q.topic)=upper(btrim(coalesce(p_category,'')));
$function$;

create or replace function public.english_get_new_practice_items(p_category text default 'ALL', p_source text default 'ALL')
returns jsonb
language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
with base as (
 select q.*,english.new_practice_type(auth.uid(),q) type_id,english.new_practice_source(auth.uid(),q) source_name,
        english.recent_content_date(q) added,coalesce(s.status,'New') st,coalesce(s.attempts,0) att,coalesce(s.last_marked,false) starred,coalesce(s.wrong,0) wrong
 from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 where auth.uid() is not null and q.active and not coalesce(s.mastered,false)
   and (english.recent_content_date(q) is not null
        or exists(select 1 from english.hindu_vocab_registry h where h.user_id=auth.uid() and h.active and h.in_vocab and h.question_id=q.question_id)
        or exists(select 1 from english.saved_items si where si.user_id=auth.uid() and si.active and si.practice_question_id=q.question_id))
)
select coalesce(jsonb_agg(jsonb_build_object(
 'id',question_id,'question_id',question_id,'word',coalesce(word,''),'question',coalesce(question,''),'weak',st in ('Persistent Weak','Weak','Fragile'),
 'started',att>0,'attempts',att,'starred',starred,'status',st,'source',source_name,'date',added
) order by added desc nulls last,question_id),'[]'::jsonb)
from base where (upper(btrim(coalesce(p_category,'ALL')))='ALL' or type_id=upper(btrim(p_category))) and (btrim(coalesce(p_source,'ALL'))='ALL' or source_name=btrim(p_source));
$function$;

create or replace function public.english_get_source_items(p_source_key text)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
declare uid uuid:=auth.uid(); v_key text:=btrim(coalesce(p_source_key,'')); v_date date; out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if v_key like 'THE_HINDU::%' then begin v_date:=substring(v_key from 12)::date; exception when others then v_date:=null; end; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',q.question_id,'question_id',q.question_id,'word',coalesce(q.word,''),'question',coalesce(q.question,''),
   'weak',coalesce(s.status,'New') in ('Persistent Weak','Weak','Fragile'),'started',coalesce(s.attempts,0)>0,'attempts',coalesce(s.attempts,0),
   'status',coalesce(s.status,'New'),'date',english.recent_content_date(q),'source',english.source_descriptor_name(q)
 ) order by english.recent_content_date(q) desc nulls last,q.question_id),'[]'::jsonb) into out
 from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
 where q.active and not coalesce(s.mastered,false) and english.recent_content_date(q)>='2026-08-15'
   and ((v_date is not null and english.source_descriptor_key(q)='THE_HINDU' and english.recent_content_date(q)=v_date)
        or (v_date is null and english.source_descriptor_key(q)=v_key));
 return out;
end $function$;
