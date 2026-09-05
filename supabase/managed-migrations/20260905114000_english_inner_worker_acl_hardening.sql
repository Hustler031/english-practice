-- Stage 2 release hardening.
-- The Edge workers call service-role-only public wrappers. These inner English-schema
-- functions are implementation details and should not inherit PostgreSQL's default
-- PUBLIC EXECUTE privilege even though they also validate private worker tokens.

revoke all on function english.context_claim(text,integer) from public,anon,authenticated;
revoke all on function english.apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
revoke all on function english.fail_context_ai(text,uuid,text) from public,anon,authenticated;
revoke all on function english.transfer_claim(text,integer) from public,anon,authenticated;
revoke all on function english.apply_generated_transfer(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
revoke all on function english.fail_transfer_generation(text,uuid,text) from public,anon,authenticated;
revoke all on function english.question_quality_review_claim(text,integer) from public,anon,authenticated;
revoke all on function english.apply_question_quality_review_result(text,uuid,jsonb,text,jsonb) from public,anon,authenticated;
revoke all on function english.reconcile_context_worker_http() from public,anon,authenticated;
revoke all on function english.worker_lane_allowed(text) from public,anon,authenticated;

grant execute on function english.context_claim(text,integer) to service_role;
grant execute on function english.apply_context_ai_diagnosis(text,uuid,jsonb,text,jsonb) to service_role;
grant execute on function english.fail_context_ai(text,uuid,text) to service_role;
grant execute on function english.transfer_claim(text,integer) to service_role;
grant execute on function english.apply_generated_transfer(text,uuid,jsonb,text,jsonb) to service_role;
grant execute on function english.fail_transfer_generation(text,uuid,text) to service_role;
grant execute on function english.question_quality_review_claim(text,integer) to service_role;
grant execute on function english.apply_question_quality_review_result(text,uuid,jsonb,text,jsonb) to service_role;
grant execute on function english.reconcile_context_worker_http() to service_role;
grant execute on function english.worker_lane_allowed(text) to service_role;
