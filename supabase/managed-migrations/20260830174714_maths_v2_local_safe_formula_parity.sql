create or replace function maths._select_by_kind(p_uid uuid,p_ids text[],p_kind text,p_count int default 20) returns text[] language plpgsql stable security definer set search_path=pg_catalog,public,maths as $$
declare k text:=lower(coalesce(p_kind,'random')); n int:=greatest(1,least(coalesce(p_count,20),100)); out_ids text[]; fresh_ids text[]; formula_pool boolean:=false;
begin
 select coalesce(array_length(p_ids,1),0)>0 and not exists(
   select 1 from unnest(coalesce(p_ids,array[]::text[])) z(id)
   left join maths.practice_set_items i on i.set_id='MOCK_FORMULA_REVISION' and i.question_id=z.id
   where i.question_id is null
 ) into formula_pool;
 if formula_pool then
   if k='new' then
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.state_attempts=0 order by random() limit n)x;
   elsif k='weak' then
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.last_state_result='wrong' order by random() limit n)x;
   elsif k='due' then
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and (r.state_attempts=0 or r.last_state_result='wrong' or r.difficult) order by random() limit n)x;
   elsif k in ('starred','important') then
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.starred order by random() limit n)x;
   elsif k='difficult' then
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) and r.difficult order by random() limit n)x;
   else
     select coalesce(array_agg(x.question_id),array[]::text[]) into out_ids from(select r.question_id from maths._user_runtime(p_uid) r where r.question_id=any(p_ids) order by random() limit n)x;
   end if;
   return out_ids;
 end if;
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


