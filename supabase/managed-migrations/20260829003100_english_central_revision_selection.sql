create or replace function public.english_get_revision_hub() returns jsonb
language sql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
with c as (
 select q.question_id,coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.mastered,false) mastered,
   coalesce(d.difficult,false) difficult,coalesce(s.last_marked,false) starred,s.last_attempt,s.next_review,
   (s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due
 from english.questions q
 left join english.question_state s on s.user_id=auth.uid() and s.question_id=q.question_id
 left join english.difficult_state d on d.user_id=auth.uid() and d.question_id=q.question_id
 where auth.uid() is not null and q.active
)
select jsonb_build_object(
 'due',count(*) filter(where not mastered and attempts>0 and due),
 'weak',count(*) filter(where not mastered and status in ('Persistent Weak','Weak','Fragile')),
 'persistentWeak',count(*) filter(where not mastered and status='Persistent Weak'),
 'difficult',count(*) filter(where not mastered and difficult),
 'starred',count(*) filter(where not mastered and starred),
 'seenBefore',count(*) filter(where not mastered and attempts>0),
 'mastered',count(*) filter(where mastered),
 'learning',count(*) filter(where not mastered and status in ('Learning','New'))
) from c;
$$;
grant execute on function public.english_get_revision_hub() to authenticated;

create or replace function public.english_get_revision_batch(p_mode text default 'due',p_count integer default 30) returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();m text:=lower(btrim(coalesce(p_mode,'due')));n integer:=greatest(1,least(100,coalesce(p_count,30)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if m not in ('due','weak','recall','difficult','random') then raise exception 'Unknown revision mode: %',p_mode; end if;
 with base as (
  select q.question_id,coalesce(s.status,'New') status,coalesce(s.attempts,0) attempts,coalesce(s.wrong,0) wrong,
    coalesce(d.difficult,false) difficult,coalesce(s.last_marked,false) starred,s.last_attempt,s.next_review,
    (s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) due
  from english.questions q
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  left join english.difficult_state d on d.user_id=uid and d.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false)
 ), filtered as (
  select * from base where
    (m='due' and attempts>0 and due) or
    (m='weak' and status in ('Persistent Weak','Weak','Fragile')) or
    (m='recall' and attempts>0) or
    (m='difficult' and difficult) or m='random'
 ), ranked as (
  select question_id,row_number() over(order by
    case when m='random' then random() else 0 end,
    case status when 'Persistent Weak' then 6 when 'Weak' then 5 when 'Fragile' then 4 when 'Learning' then 3 when 'Strong' then 2 else 1 end desc,
    due desc,difficult desc,wrong desc,coalesce(next_review,'infinity'::timestamptz) asc,coalesce(last_attempt,'epoch'::timestamptz) asc,question_id
  )::int ord from filtered
 ), chosen as (select * from ranked order by ord limit n)
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id)||jsonb_build_object('centralRevisionMode',m) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end $$;
grant execute on function public.english_get_revision_batch(text,integer) to authenticated;

create or replace function public.english_get_difficult_items(p_count integer default 100) returns jsonb
language plpgsql stable security definer
set search_path='pg_catalog','public','english','auth'
as $$
declare uid uuid:=auth.uid();v_n integer:=greatest(1,least(1000,coalesce(p_count,100)));out jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 with ranked as (
  select q.question_id,row_number() over(order by
    case coalesce(s.status,'New') when 'Persistent Weak' then 6 when 'Weak' then 5 when 'Fragile' then 4 when 'Learning' then 3 when 'Strong' then 2 else 1 end desc,
    (s.next_review is not null and s.next_review <= (((now() at time zone 'Asia/Kolkata')::date+1)::timestamp at time zone 'Asia/Kolkata')) desc,
    coalesce(s.wrong,0) desc,coalesce(s.last_attempt,'epoch'::timestamptz) asc,q.question_id
  )::int ord
  from english.questions q join english.difficult_state d on d.user_id=uid and d.question_id=q.question_id and d.difficult
  left join english.question_state s on s.user_id=uid and s.question_id=q.question_id
  where q.active and not coalesce(s.mastered,false)
 ), chosen as (select * from ranked order by ord limit v_n)
 select coalesce(jsonb_agg(english.question_payload(uid,c.question_id) order by c.ord),'[]'::jsonb) into out from chosen c;
 return out;
end $$;
