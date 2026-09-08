const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '../..');
const read = (p) => fs.readFileSync(path.join(root,p),'utf8');
const bridge = read('supabase/functions/english-content-task-bridge/index.ts');
const phrasalSubmit = read('supabase/functions/english-content-task-bridge/submitted-phrasal.ts');
const grammarSubmit = read('supabase/functions/english-content-task-bridge/submitted-grammar.ts');
const migration = read('supabase/managed-migrations/20260905084500_english_phrasal_hindu_chatgpt_bridge.sql');
const mapping = read('supabase/managed-migrations/20260905084600_english_phrasal_task_central_mapping.sql');
const grammarFoundation = read('supabase/migrations/20260909012000_english_grammar_intelligence_foundation.sql');
const grammarPipeline = read('supabase/migrations/20260909013000_english_grammar_daily_pipeline.sql');
function need(t,n,l){if(!t.includes(n))throw new Error(`Missing ${l}: ${n}`)}
function forbid(t,n,l){if(t.includes(n))throw new Error(`Forbidden ${l}: ${n}`)}

need(bridge,'english-content-automation','shared private OIDC audience');
need(bridge,'Hustler031/telegram-media-bot','private transport repository');
need(bridge,'refs/heads/automation/english-phrasal','Phrasal ref binding');
need(bridge,'refs/heads/automation/english-hindu','Hindu ref binding');
need(bridge,'refs/heads/automation/english-grammar','Grammar ref binding');
need(bridge,'claimSubmittedPhrasal','modular Phrasal claim handler');
need(bridge,'ingestSubmittedPhrasal','modular Phrasal ingest handler');
need(bridge,'claimSubmittedGrammar','modular Grammar claim handler');
need(bridge,'ingestSubmittedGrammar','modular Grammar ingest handler');
need(bridge,'english_hindu_task_claim','Hindu claim RPC');
need(bridge,'english_hindu_task_check_candidates','Hindu candidate-check RPC');
need(bridge,'english_hindu_task_apply','Hindu apply RPC');
need(bridge,'Legacy/server-side Grammar AI generation is disabled','ChatGPT-owned Grammar generation boundary');
forbid(bridge,'OPENAI_API_KEY','OpenAI API generation');
forbid(bridge,'api.openai.com','OpenAI API generation');

need(phrasalSubmit,'english_phrasal_task_claim','Phrasal claim RPC');
need(phrasalSubmit,'english_phrasal_task_ingest','Phrasal generated-only ingest RPC');
need(phrasalSubmit,'selection.length !== 20','Phrasal exact-20 private claim');
need(grammarSubmit,'english_grammar_task_claim','Grammar claim RPC');
need(grammarSubmit,'english_grammar_task_ingest','Grammar generated-only ingest RPC');
need(grammarSubmit,'selection.length !== 20','Grammar exact-20 private claim');
need(grammarSubmit,'itemsRaw.length > 20','Grammar generated-only override cap');

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

need(grammarFoundation,"values('grammar_ai_v1',false",'Grammar disabled-until-deploy feature flag');
need(grammarFoundation,'english.grammar_rule_evidence','Grammar incremental CI evidence');
need(grammarFoundation,"source text not null check(source in ('grammar_daily','sprint'))",'Daily + Sprint Grammar evidence');
need(grammarFoundation,'english_sprint_answer_grammar_evidence','Sprint-to-Grammar evidence trigger');
need(grammarPipeline,'english.maintenance_grammar_batch(20)','Central-selected Grammar exact-20 batch');
need(grammarPipeline,'english.generated_item_hard_gates_pass(v_item)','Grammar deterministic hard gates');
need(grammarPipeline,'missing ChatGPT self-critic provenance','Grammar final-payload self-critic requirement');
need(grammarPipeline,'Grammar slot % canonical reuse identity mismatch','same permanent Question_ID reuse boundary');
need(grammarPipeline,"v_qid:='GRM'||lpad(nextval('english.grammar_question_seq')::text,6,'0')",'new permanent Grammar Question_ID');
need(grammarPipeline,'public.english_get_grammar_today()','Grammar app-facing exact-20 getter');
need(grammarPipeline,"'ready',(select count(*) from rows)=20",'Grammar getter exact-20 readiness');
forbid(grammarPipeline,'OPENAI_API_KEY','Grammar backend OpenAI API generation');
forbid(grammarPipeline,'api.openai.com','Grammar backend OpenAI API generation');

console.log('English Phrasal/Hindu/Grammar ChatGPT private bridge contract: PASS');
