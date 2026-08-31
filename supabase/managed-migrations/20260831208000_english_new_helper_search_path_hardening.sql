-- Pre-deployment security hardening for helper functions introduced by the 30-day mastery sprint.
-- These helpers use PostgreSQL built-ins only, so pg_catalog is sufficient and prevents role-mutable search_path resolution.

alter function english.route_add_origin(text[],text) set search_path = pg_catalog;
alter function english.sprint_expected_count(text) set search_path = pg_catalog;
alter function english.sprint_allowed_type(text) set search_path = pg_catalog;
alter function english.sprint_validate_options(jsonb,text) set search_path = pg_catalog;
alter function english.route_origin_matches(text[],text) set search_path = pg_catalog;
alter function english.route_origin_label(text) set search_path = pg_catalog;
alter function english.route_recovery_origin(text) set search_path = pg_catalog;
alter function english.sprint_option_text(jsonb,text) set search_path = pg_catalog;
