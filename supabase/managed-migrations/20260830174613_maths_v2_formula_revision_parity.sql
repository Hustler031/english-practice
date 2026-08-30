create or replace function maths._formula_metric(p_uid uuid,p_ids text[]) returns jsonb language sql stable security definer set search_path=pg_catalog,public,maths as $$
select (maths._metric(p_uid,p_ids) || jsonb_build_object(
  'wrong',count(*) filter(where r.last_state_result='wrong'),
  'weak',count(*) filter(where r.last_state_result='wrong')
))
from maths._user_runtime(p_uid) r where r.question_id=any(coalesce(p_ids,array[]::text[]))
$$;

create or replace function public.maths_get_formula_hub() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,maths as $$
declare uid uuid:=maths._require_uid(); ids text[]; chapters jsonb;
begin
 select coalesce(array_agg(question_id),array[]::text[]) into ids from maths._user_runtime(uid) where runtime_active and in_formula_revision;
 select coalesce(jsonb_agg(jsonb_build_object('chapter',chapter,'metric',maths._formula_metric(uid,cids)) order by chapter),'[]'::jsonb) into chapters
 from(select chapter,array_agg(question_id)cids from maths._user_runtime(uid) where runtime_active and in_formula_revision group by chapter)x;
 return jsonb_build_object('ok',true,'setId','MOCK_FORMULA_REVISION','overall',maths._formula_metric(uid,ids),
   'due',(select count(*) from maths._user_runtime(uid) r where r.question_id=any(ids) and (r.state_attempts=0 or r.last_state_result='wrong' or r.difficult)),
   'chapters',chapters);
end $$;

create or replace function public.maths_start_formula_revision(p_kind text default 'all',p_chapter text default null,p_count integer default 20) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,maths as $$
declare uid uuid:=maths._require_uid(); base text[]; ids text[]; k text:=lower(coalesce(p_kind,'all')); n int:=greatest(1,least(coalesce(p_count,20),100));
begin
 select coalesce(array_agg(question_id),array[]::text[]) into base from maths._user_runtime(uid) where runtime_active and in_formula_revision and (p_chapter is null or maths._norm(chapter)=maths._norm(p_chapter));
 if k='new' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) and r.state_attempts=0 order by random() limit n)x;
 elsif k='weak' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) and r.last_state_result='wrong' order by random() limit n)x;
 elsif k='due' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) and (r.state_attempts=0 or r.last_state_result='wrong' or r.difficult) order by random() limit n)x;
 elsif k in ('starred','important') then
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) and r.starred order by random() limit n)x;
 elsif k='difficult' then
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) and r.difficult order by random() limit n)x;
 else
   select coalesce(array_agg(x.question_id),array[]::text[]) into ids from(select r.question_id from maths._user_runtime(uid) r where r.question_id=any(base) order by random() limit n)x;
 end if;
 return maths._start_session(uid,ids,'formula_revision','Formula Revision · '||coalesce(p_chapter,'All')||' · '||initcap(k),jsonb_build_object('scope','formula_revision','setId','MOCK_FORMULA_REVISION','kind',k,'chapter',p_chapter),false);
end $$;


