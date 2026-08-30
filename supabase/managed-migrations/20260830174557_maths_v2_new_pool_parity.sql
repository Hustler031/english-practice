create or replace function maths._new_ids(p_uid uuid,p_ids text[]) returns text[] language sql stable security definer set search_path=pg_catalog,public,maths as $$
with pool as (
  select r.question_id,r.added_at
  from maths._user_runtime(p_uid) r
  where r.question_id=any(coalesce(p_ids,array[]::text[])) and r.state_attempts=0
), mx as (select max(added_at) max_added from pool), chosen as (
  select p.question_id,p.added_at
  from pool p cross join mx
  where mx.max_added is null or p.added_at is null or p.added_at >= mx.max_added - (greatest(1,coalesce(nullif(maths._setting('new_content_window_days','60'), '')::int,60))||' days')::interval
)
select coalesce(array_agg(question_id order by added_at desc nulls last,question_id desc),array[]::text[]) from chosen
$$;

create or replace function maths._select_by_kind(p_uid uuid,p_ids text[],p_kind text,p_count int default 20) returns text[] language plpgsql stable security definer set search_path=pg_catalog,public,maths as $$
declare k text:=lower(coalesce(p_kind,'random')); n int:=greatest(1,least(coalesce(p_count,20),100)); out_ids text[]; fresh_ids text[];
begin
 if k='all' then
   select coalesce(array_agg(r.question_id order by md5(r.question_id||current_date::text)),array[]::text[]) into out_ids from maths._user_runtime(p_uid) r where r.question_id=any(p_ids);
 elsif k='new' then
   fresh_ids:=maths._new_ids(p_uid,p_ids);
   select coalesce(array_agg(x.id order by x.ord),array[]::text[]) into out_ids from (select id,ord from unnest(fresh_ids) with ordinality u(id,ord) order by ord limit n)x;
 elsif k='weak' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.weak order by r.hard desc,(r.profile_last_result='wrong') desc,coalesce(r.profile_accuracy,1),r.profile_avg_sec desc,r.question_id limit n)x;
 elsif k='hard' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.hard order by r.wrong_streak desc,coalesce(r.profile_accuracy,1),r.profile_avg_sec desc,r.question_id limit n)x;
 elsif k in ('starred','important') then
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.starred and not r.mastered order by random() limit n)x;
 elsif k='difficult' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.difficult and not r.mastered order by random() limit n)x;
 elsif k='due' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and (r.state_attempts=0 or r.profile_last_result='wrong' or r.difficult or (r.profile_total>0 and r.age_days>=r.review_interval)) and not r.mastered order by (r.profile_last_result='wrong') desc,r.difficult desc,r.weak desc,r.age_days desc limit n)x;
 else
   select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and not r.mastered order by random() limit n)x;
 end if;
 return out_ids;
end $$;


