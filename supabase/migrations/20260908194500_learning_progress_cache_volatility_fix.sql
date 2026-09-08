-- The cached learning-progress wrapper writes the refreshed snapshot on a
-- bucket miss, so PostgreSQL must treat the wrapper as VOLATILE. The internal
-- heavy aggregation remains STABLE and read-only.

alter function public.english_get_learning_progress() volatile;
