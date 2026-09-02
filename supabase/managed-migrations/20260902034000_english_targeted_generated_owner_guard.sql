-- Keep every user-owned generated question out of shared or foreign practice sets.
create or replace function english.enforce_practice_set_question_owner()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','english','auth'
as $$
declare
  q_owner uuid;
  q_kind text;
  s_owner uuid;
begin
  select origin_kind,owner_user_id into q_kind,q_owner
  from english.question_origins
  where question_id=new.question_id;

  if q_kind in ('saved_generated','targeted_generated') then
    select owner_user_id into s_owner
    from english.practice_sets
    where set_id=new.set_id;

    if s_owner is distinct from q_owner then
      raise exception 'Private generated question cannot enter a shared or foreign practice set';
    end if;
  end if;

  return new;
end $$;
