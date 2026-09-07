-- The legacy Sprint INSERT trigger turns startImmediately=false into status=ready.
-- Preserve that behavior only for the old default in_progress insertion path. A
-- ChatGPT-prepared critic_pending session must never become startable before Luna.
create or replace function english.defer_sprint_start_from_blueprint()
returns trigger
language plpgsql
set search_path to 'pg_catalog','english'
as $function$
begin
  if new.status='in_progress'
     and lower(coalesce(new.blueprint->>'startImmediately','true'))='false' then
    new.status:='ready';
    new.remaining_seconds:=900;
  end if;
  return new;
end
$function$;
