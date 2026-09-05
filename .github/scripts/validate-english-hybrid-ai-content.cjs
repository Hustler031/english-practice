const fs=require('fs');
const path=require('path');
const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const need=(t,s,m)=>{if(!t.includes(s))throw new Error(`${m}: missing ${s}`);console.log(`✅ ${m}`)};
const forbid=(t,s,m)=>{if(t.includes(s))throw new Error(`${m}: forbidden ${s}`);console.log(`✅ ${m}`)};

const foundation=read('supabase/managed-migrations/20260905231500_english_hybrid_ai_quality_foundation.sql');
const metadata=read('supabase/managed-migrations/20260905231800_english_phrasal_context_metadata.sql');
const apply=read('supabase/managed-migrations/20260905232100_english_phrasal_hybrid_apply.sql');
const sprint=read('supabase/managed-migrations/20260905232400_english_manual_chatgpt_sprint.sql');
const guards=read('supabase/managed-migrations/20260905232700_english_hybrid_apply_guards.sql');
const savedUpgrade=read('supabase/managed-migrations/20260905233000_english_editorial_tone_saved_upgrade.sql');
const materializer=read('supabase/managed-migrations/20260905235000_english_phrasal_context_materializer.sql');
const auditProv=read('supabase/managed-migrations/20260905235500_english_ai_audit_and_provenance.sql');
const savedScheduler=read('supabase/managed-migrations/20260905235930_english_saved_hybrid_scheduler.sql');
const ai=read('supabase/functions/_shared/english-hybrid-ai.ts');
const bridge=read('supabase/functions/english-content-task-bridge/index.ts');
const generation=read('supabase/functions/english-content-task-bridge/generation.ts');
const savedWorker=read('supabase/functions/english-saved-enrichment-worker/index.ts');
const savedPage=read('web-v2/app/english/saved/page.tsx');
const sprintHistory=read('web-v2/components/sprint-report-history.tsx');
const migrations=fs.readdirSync(path.join(root,'supabase/managed-migrations')).filter(x=>x.endsWith('.sql')).map(x=>read(`supabase/managed-migrations/${x}`)).join('\n');

need(foundation,'enabled boolean not null default false','AI flags default off');
for(const flag of ['gemini_content_v1','groq_critic_v1','phrasal_sense_v1','phrasal_context_fill_v1','chatgpt_sprint_v1','hindu_tone_v1'])need(foundation,`'${flag}'`,`Feature flag ${flag}`);
need(foundation,'coalesce((p_item->\'quality\'->>\'score\')::numeric,0) >= 85','85 quality threshold');
need(foundation,"requiredOptionsValid",'Family-aware option quality gate');
need(foundation,'english_ai_content_feature_enabled','Service-only flag read RPC');

need(metadata,'phrasal_concept_senses','Concept-sense registry');
need(metadata,'phrasal_question_variants','Variant registry');
need(metadata,"'context_fill'",'Context-fill family');
need(metadata,'eligible_rank<=8','Maximum eight bootstrap context slots');
need(metadata,'recentConceptStems','Semantic anti-repeat context');
need(metadata,'referenceVariant','Canonical reference variant supplied');
need(metadata,"public.english_get_phrasal_maintenance_batch(p_mode,p_count)",'Central selector remains upstream authority');
need(metadata,"first_attempt<activation",'Previously-seen immediate bootstrap');
need(metadata,"attempt_count>=3 and first_attempt<=now()-interval '7 days'",'New-concept maturity gate');

need(materializer,'jsonb_array_length(p_items)<>20','Hybrid exact-20 gate');
need(materializer,'v_expected_ids is distinct from v_given_ids','Exact Central concept set gate');
need(materializer,"v_requested_family='context_fill'",'Context family accepted separately');
need(materializer,"then 'recognition'",'Context uses legacy recognition-compatible storage');
need(materializer,"'I knew this'",'Legacy recall A label preserved');
need(materializer,"'Unsure'",'Legacy recall B label preserved');
need(materializer,"'Forgot'",'Legacy recall C label preserved');
need(materializer,"alreadyComplete",'Retry-safe already-complete branch');
need(apply,'centralMapped','Central mapping verification retained');

need(ai,'gemini-3.6-flash','Grounded structured Gemini stable default');
need(ai,'openai/gpt-oss-120b','Groq independent critic model');
need(ai,'repairs<2','Repair cap is two');
need(ai,'q.score>=85','Runtime quality threshold');
need(ai,'requiredOptionsValid','Runtime family-aware option gate');
forbid(ai,'OPENAI_API_KEY','Background shared helper must not use OpenAI');

need(bridge,'runPhrasalGeneration','Bridge owns automated Phrasal generation action');
need(bridge,'runHinduGeneration','Bridge owns automated Hindu generation action');
need(generation,'english_ai_content_feature_enabled','Runtime feature read through public service RPC');
need(generation,'english_record_content_generation_audits','Runtime AI audit RPC');
need(generation,'contextCount<6||contextCount>8','Phrasal 6-8 contextual mix hard gate');
need(generation,'referenceVariant','Phrasal generation grounded in canonical variant');
need(generation,'recentConceptStems','Semantic repeat context reaches critic');
need(generation,'A="I knew this", B="Unsure", C="Forgot", D=""','Generated recall preserves legacy contract');
need(generation,'googleSearch:true','Hindu current-news research uses Search grounding');
need(generation,'Never label a source The Hindu unless','Truthful The Hindu provenance prompt');
need(generation,'candidateType:{type:"string",enum:["vocabulary","discourse_marker"]}','Discourse-marker candidate lane');
forbid(generation,'OPENAI_API_KEY','Background content generator must not use OpenAI');

need(savedWorker,'generateCriticRepair','Saved uses writer-critic-repair path');
need(savedWorker,'genuinelyAmbiguous','Saved independent ambiguity gate');
need(savedWorker,'english_saved_enrichment_worker_apply','Saved existing apply contract retained');
need(savedWorker,'english_record_content_generation_audits','Saved audits through service RPC');
need(savedWorker,'AI_TIMEOUT','Saved timeout compatibility retained');
forbid(savedWorker,'OPENAI_API_KEY','Saved background worker no longer uses OpenAI');
need(savedScheduler,"jobname='english-saved-enrichment'",'Saved hybrid scheduler owns the existing hourly job name');
need(savedScheduler,"'7 * * * *'",'Saved hybrid scheduler remains hourly');
need(savedScheduler,'english.kick_saved_enrichment_worker(10)','Saved hybrid scheduler invokes the existing token-authorized worker launcher');
need(savedScheduler,'cron.unschedule','Saved scheduler replacement is idempotent');
need(savedUpgrade,'english_manual_upgrade_saved_item','Manual GPT Saved upgrade service RPC');
need(savedUpgrade,'manual ChatGPT upgraded/reviewed','Manual GPT provenance');
need(savedPage,'GPT Upgraded','Learner-visible GPT Upgraded marker');

need(guards,'english_hindu_task_apply','Hindu guarded existing apply RPC');
need(auditProv,'Gemini grounded current-news generation + Groq independent critic','Truthful Hindu source metadata');
need(auditProv,'english_record_content_generation_audits','Service-only generation audit writer');
need(savedUpgrade,'editorial_tone_items','Tone stored outside vocabulary concept identity');
need(savedUpgrade,'context_paraphrase','Tone uses paraphrased context');

need(sprint,'english_publish_chatgpt_sprint','Manual ChatGPT Sprint publication RPC');
need(sprint,'english_create_sprint_session','Manual publication reuses existing Sprint session validator');
need(sprint,'english_get_sprint_generation_context','Manual publication reuses existing generation context');
need(sprintHistory,'p_days:5','Sprint Reports preserve 5-day completed window');
need(migrations,'from hist_all where rn<=5','Exam readiness keeps latest five completed Sprint records');

console.log('\n✅ Hybrid AI content source contracts passed.');
