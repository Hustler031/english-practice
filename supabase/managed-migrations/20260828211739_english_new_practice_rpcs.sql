create or replace function public.english_get_new_practice_hub()
returns jsonb language sql stable security definer set search_path=pg_catalog,public,english,auth as $$
with pool as (
 select q.question_id,english.new_practice_type(auth.uid(),q) type_id,english.new_practice_source(auth.uid(),q) source_name,coalesce(s.status,'New') st,coalesce(s.attempts,0) attempts,coalesce(s.last_marked,false) starred
 from english.questions q left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 where auth.uid() is not null and q.active and not coalesce(s.mastered,false)
   and (english.recent_content_date(q) is not null or exists(select 1 from english.hindu_vocab_registry h where h.user_id=auth.uid() and h.active and h.in_vocab and h.question_id=q.question_id) or exists(select 1 from english.saved_items si where si.user_id=auth.uid() and si.active and si.practice_question_id=q.question_id))
), fixed as (
 select * from (values(1,'VOC','Vocabulary'),(2,'IDIOM','Idioms & Phrases'),(3,'PHRASAL','Phrasal Verbs'),(4,'OWS','One Word Substitution'),(5,'SPELL','Spelling Mistakes')) v(ord,id,name)
), extras as (
 select 100+row_number() over(order by type_id)::int ord,type_id id,case type_id when 'CU' then 'Concept / Usage' when 'SPELLING' then 'Spelling Mistakes' else type_id end name
 from (select distinct type_id from pool where type_id not in ('VOC','IDIOM','PHRASAL','OWS','SPELL')) x
), ids as (select * from fixed union all select * from extras),
cat_stats as (
 select i.ord,i.id,i.name,count(p.question_id) total,count(p.question_id) filter(where p.st in ('Persistent Weak','Weak','Fragile')) weak,count(p.question_id) filter(where p.attempts=0) new_count,count(p.question_id) filter(where p.starred) starred
 from ids i left join pool p on p.type_id=i.id group by i.ord,i.id,i.name
), source_stats as (
 select type_id,jsonb_agg(jsonb_build_object('name',source_name,'total',total,'weak',weak,'newCount',new_count,'starred',starred) order by source_name) sources
 from (select type_id,source_name,count(*) total,count(*) filter(where st in ('Persistent Weak','Weak','Fragile')) weak,count(*) filter(where attempts=0) new_count,count(*) filter(where starred) starred from pool group by type_id,source_name) x group by type_id
)
select jsonb_build_object(
 'total',(select count(*) from pool),
 'weak',(select count(*) from pool where st in ('Persistent Weak','Weak','Fragile')),
 'newCount',(select count(*) from pool where attempts=0),
 'starred',(select count(*) from pool where starred),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'total',c.total,'weak',c.weak,'newCount',c.new_count,'starred',c.starred,'sources',coalesce(s.sources,'[]'::jsonb)) order by c.ord) from cat_stats c left join source_stats s on s.type_id=c.id),'[]'::jsonb)
); $$;

create or replace function public.english_get_new_practice_batch(p_category text default 'ALL',p_mode text default 'all',p_count integer default 10,p_source text default 'ALL')
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,english,auth as $$
declare uid uuid:=auth.uid();v_cat text:=upper(btrim(coalesce(p_category,'ALL')));v_mode text:=lower(btrim(coalesce(p_mode,'all')));v_source text:=btrim(coalesce(p_source,'ALL'));v_n integer:=greatest(1,least(100,coalesce(p_count,10)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with base as (
  select q.question_id,english.new_practice_type(uid,q) type_id,english.new_practice_source(uid,q) source_name,english.recent_content_date(q) added,coalesce(s.status,'New') st,coalesce(s.attempts,0) att,coalesce(s.last_marked,false) starred,s.last_attempt
  from english.questions q left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false)
    and (english.recent_content_date(q) is not null or exists(select 1 from english.hindu_vocab_registry h where h.user_id=uid and h.active and h.in_vocab and h.question_id=q.question_id) or exists(select 1 from english.saved_items si where si.user_id=uid and si.active and si.practice_question_id=q.question_id))
 ), filtered as (
  select * from base where (v_cat='ALL' or type_id=v_cat) and (v_source='ALL' or source_name=v_source)
   and (v_mode not in ('weak','starred') or (v_mode='weak' and st in ('Persistent Weak','Weak','Fragile')) or (v_mode='starred' and starred))
 ), ranked as (
  select question_id,row_number() over(order by
    case when v_mode in ('new','newwords') and att=0 and added is not null then 0 when v_mode in ('new','newwords') and att=0 then 1 when v_mode in ('new','newwords') and st in ('Persistent Weak','Weak','Fragile') then 2 when v_mode in ('new','newwords') then 3 when v_mode='random' and st in ('Persistent Weak','Weak','Fragile') then 0 when v_mode='random' and added>=((now() at time zone 'Asia/Kolkata')::date-6) then 1 when v_mode='random' and starred then 2 when v_mode='random' and att>0 then 3 else 4 end,
    case when v_mode in ('weak','random','starred') then random() else 0 end,
    added desc nulls last,last_attempt desc nulls last,question_id)::int ord from filtered
 ), chosen as (select * from ranked order by ord limit v_n)
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end; $$;

revoke all on function public.english_get_new_practice_hub() from public;
revoke all on function public.english_get_new_practice_batch(text,text,integer,text) from public;
grant execute on function public.english_get_new_practice_hub() to authenticated;
grant execute on function public.english_get_new_practice_batch(text,text,integer,text) to authenticated;
