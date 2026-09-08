alter function public.english_phrasal_task_claim() set statement_timeout = '120s';
alter function public.english_phrasal_task_apply(uuid, jsonb) set statement_timeout = '120s';
