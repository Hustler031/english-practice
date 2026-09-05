const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '../..');
const bridge = fs.readFileSync(path.join(root,'supabase/functions/english-content-task-bridge/index.ts'),'utf8');
const migration = fs.readFileSync(path.join(root,'supabase/managed-migrations/20260905084500_english_phrasal_hindu_chatgpt_bridge.sql'),'utf8');
const mapping = fs.readFileSync(path.join(root,'supabase/managed-migrations/20260905084600_english_phrasal_task_central_mapping.sql'),'utf8');
function need(t,n,l){if(!t.includes(n))throw new Error(`Missing ${l}: ${n}`)}
function forbid(t,n,l){if(t.includes(n))throw new Error(`Forbidden ${l}: ${n}`)}

need(bridge,'english-content-automation','shared private OIDC audience');
need(bridge,'Hustler031/telegram-media-bot','private transport repository');
need(bridge,'refs/heads/automation/english-phrasal','Phrasal ref binding');
need(bridge,'refs/heads/automation/english-hindu','Hindu ref binding');
need(bridge,'english_phrasal_task_claim','Phrasal claim RPC');
need(bridge,'english_phrasal_task_apply','Phrasal apply RPC');
need(bridge,'english_hindu_task_claim','Hindu claim RPC');
need(bridge,'english_hindu_task_check_candidates','Hindu candidate-check RPC');
need(bridge,'english_hindu_task_apply','Hindu apply RPC');
forbid(bridge,'OPENAI_API_KEY','OpenAI API generation');
forbid(bridge,'api.openai.com','OpenAI API generation');

need(migration,'english.maintenance_phrasal_batch(20)','Central-selected Phrasal batch');
need(migration,'english.maintenance_apply_phrasal_daily','atomic Phrasal materialization');
need(migration,'english.maintenance_verify_phrasal_daily','Phrasal verification');
need(migration,'english.maintenance_hindu_check_candidates','server-side Hindu duplicate check');
need(migration,"regexp_replace(lower(v_word),'[^a-z0-9]','','g')",'lowercase-first Hindu normalization');
need(migration,'Historical family collision requires documented distinct-sense exception','family collision gate');
need(migration,"'The Hindu Vocabulary'",'canonical Hindu topic');
need(migration,"'Daily News Vocabulary'",'canonical Hindu subtopic');
need(migration,'english.question_concept_mappings','Hindu Central Intelligence mapping');
need(migration,'english.concepts','Hindu concept registration');
need(migration,"grant execute on function public.english_phrasal_task_claim() to service_role",'Phrasal service-role boundary');
need(migration,"grant execute on function public.english_hindu_task_apply(uuid,jsonb) to service_role",'Hindu service-role boundary');

need(mapping,'centralMapped','Phrasal Central Intelligence verification');
need(mapping,'v_mapped<>20','exact 20 Phrasal mapping invariant');
need(mapping,"mapping_method='deterministic_metadata'",'deterministic Phrasal mapping');

console.log('English Phrasal/Hindu ChatGPT private bridge contract: PASS');
