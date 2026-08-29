create or replace function public.english_get_mastered_items()
returns jsonb
language sql stable security definer
set search_path to 'pg_catalog','public','english','auth'
as $function$
select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
 'id',q.question_id,'question_id',q.question_id,'word',coalesce(q.word,''),'question',coalesce(q.question,''),
 'status',coalesce(s.status,'Proven Mastered'),'topic',coalesce(q.topic,''),'source',coalesce(q.source_file,'')
) order by coalesce(s.last_attempt,'epoch'::timestamptz) desc,q.question_id),'[]'::jsonb) end
from english.question_state s join english.questions q on q.question_id=s.question_id and q.active
where s.user_id=auth.uid() and coalesce(s.mastered,false);
$function$;
