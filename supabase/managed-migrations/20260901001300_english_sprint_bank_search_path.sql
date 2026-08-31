-- Lock the Sprint Bank classifier helper to PostgreSQL built-ins only.
alter function english.sprint_bank_subject(text,text) set search_path = pg_catalog;
