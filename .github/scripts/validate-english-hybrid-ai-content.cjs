const fs=require('fs');
const path=require('path');
const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const need=(t,s,m)=>{if(!t.includes(s))throw new Error(`${m}: missing ${s}`);console.log(`✅ ${m}`)};
const forbid=(t,s,m)=>{if(t.includes(s))throw new Error(`${m}: forbidden ${s}`);console.log(`✅ ${m}`)};

const foundation=read('supabase/managed-migrations/20260905231500_english_hybrid_ai_quality_foundation.sql');
const metadata=read('supabase/managed-migrations/20260905231800_english_phrasal_context_metadata.sql');
const materializer=read('supabase/managed-migrations/20260905235000_english_phrasal_context_materializer.sql');
const savedScheduler=read('supabase/managed-migrations/20260905235930_english_saved_hybrid_scheduler.sql');
const stage1Flags=read('supabase/managed-migrations/20260906031000_english_antigravity_luna_stage1_flags.sql');
const legacyHybrid=read('supabase/functions/_shared/english-hybrid-ai.ts');
const stage1=read('supabase/functions/_shared/english-antigravity-luna.ts');
const bridge=read('supabase/functions/english-content-task-bridge/index.ts');
const phrasal=read('supabase/functions/english-content-task-bridge/phrasal-generation.ts');
const hindu=read('supabase/functions/english-content-task-bridge/generation.ts');
const saved=read('supabase/functions/english-saved-enrichment-worker/index.ts');

// Existing deterministic foundation remains authoritative.
need(foundation,'enabled boolean not null default false','AI flags default off');
need(foundation,'coalesce((p_item->\'quality\'->>\'score\')::numeric,0) >= 85','DB quality threshold retained');
need(foundation,'requiredOptionsValid','DB family-aware option gate retained');
need(foundation,'english_ai_content_feature_enabled','Service-only flag read RPC retained');
need(metadata,'referenceVariant','Central-selected Phrasal reference variant retained');
need(metadata,'knownSenses','Known Phrasal senses reach generation');
need(metadata,'eligible_rank<=8','Context-fill remains capped at eight');
need(metadata,'public.english_get_phrasal_maintenance_batch(p_mode,p_count)','Central Intelligence remains upstream Phrasal selector');
need(materializer,'jsonb_array_length(p_items)<>20','Phrasal publication remains exact-20');
need(materializer,'v_expected_ids is distinct from v_given_ids','Exact Central concept-set gate retained');
need(materializer,"'Yaad tha'",'Recall A contract retained');
need(materializer,"'Confused'",'Recall B contract retained');
need(materializer,"'Bhool gaya'",'Recall C contract retained');
need(savedScheduler,"jobname='english-saved-enrichment'",'Saved hourly scheduler ownership retained');
need(savedScheduler,"'7 * * * *'",'Saved hourly cadence retained');

// Dedicated Stage-1 rollout flags isolate Saved/Phrasal from Hindu.
need(stage1Flags,"'antigravity_writer_v1'",'Antigravity writer flag exists');
need(stage1Flags,"'luna_critic_v1'",'Luna critic flag exists');
need(stage1Flags,'"scope":["saved","phrasal"]','Flags are scoped to Saved/Phrasal');
need(stage1Flags,'"reasoning":"high"','Writer reasoning intent recorded');
need(stage1Flags,'"reasoning":"low"','Critic reasoning intent recorded');

// Antigravity writer + Luna critic helper.
need(stage1,'antigravity-preview-05-2026','Antigravity managed agent is the primary writer');
need(stage1,'gemini-3.6-flash','Antigravity uses current supported full Flash model');
need(stage1,'https://generativelanguage.googleapis.com/v1beta/interactions','Antigravity uses Gemini Interactions API');
need(stage1,'environment:"remote"','Antigravity provisions the required remote environment');
need(stage1,'store:true','Antigravity uses the required stateful interaction mode');
forbid(stage1,'store:false','Antigravity stateless mode is forbidden');
need(stage1,'max_total_tokens','Antigravity agent budget is bounded');
need(stage1,'Work carefully with high reasoning effort','High-effort writer instruction is explicit');
need(stage1,'gpt-5.6-luna','Luna 5.6 is the independent critic');
need(stage1,'https://api.openai.com/v1/responses','Luna uses OpenAI Responses API');
need(stage1,'reasoning:{effort:"low"}','Luna reasoning is low');
need(stage1,'type:"json_schema"','Luna uses structured output');
need(stage1,'decision:"PASS"|"REPAIR"|"REJECT"','Luna decision contract is explicit');
need(stage1,'q.score>=85','Runtime PASS threshold is 85');
need(stage1,'Object.values(q.hardGates||{}).every(Boolean)','All semantic hard gates must pass');
need(stage1,'fourOptionCodeGate','Deterministic pre/post structural gate exists');
need(stage1,'GEMINI_RARE_RESCUE_MODEL','Rare specialist rescue model is explicit');
need(stage1,'gemini-3.8-flash','Rare rescue uses Gemini 3.8 Flash');
need(stage1,'thinkingConfig:{thinkingLevel:"high"}','Rare rescue reasoning is HIGH');
need(stage1,'Only a second Luna REPAIR reaches the rare Gemini 3.8 Flash HIGH rescue path.','3.8 is second-REPAIR-only');
need(stage1,'repairCount:2','Rare rescue remains bounded to second semantic repair');
forbid(stage1,'GROQ_API_KEY','Stage-1 helper no longer depends on Groq');

// Phrasal: every Central-selected slot is generated and independently criticised one-item-at-a-time.
need(bridge,'runPhrasalGeneration','Private bridge still owns Phrasal run action');
need(phrasal,'antigravity_writer_v1','Phrasal checks writer rollout flag');
need(phrasal,'luna_critic_v1','Phrasal checks critic rollout flag');
need(phrasal,'runAntigravityLunaPipeline<any>','Phrasal uses new writer/critic pipeline');
need(phrasal,'referenceVariant','Phrasal remains grounded in Central-selected reference');
need(phrasal,'knownSenses','Phrasal retains sense registry context');
need(phrasal,'preferredSenseKey','Phrasal preserves selected sense identity');
need(phrasal,'recentConceptStems','Phrasal anti-repeat context retained');
need(phrasal,'const finalized = await mapLimit(items, 4, async (item: Json) => await generatePhrasal(item))','All 20 Central slots use item-wise generation');
forbid(phrasal,'legacyPhrasal','Legacy zero-AI shortcut removed from Stage 1');
need(phrasal,'items.length !== 20','Phrasal claim remains exact-20');
need(phrasal,'expectedContextCount > 8','Maximum eight context-fill slots remains enforced');
need(phrasal,'contextCount !== expectedContextCount','Generated mix must exactly match Central request');
need(phrasal,'new Set(finalized.map(x => x.conceptId)).size !== 20','All 20 concepts must remain distinct');
need(phrasal,'english_phrasal_task_apply','Atomic apply contract retained');
need(phrasal,'english_release_content_task_claim','Failure releases claim');
need(phrasal,'requestMode: "one_item_per_generation_request"','Phrasal audit records one-item request mode');
need(phrasal,'writerReasoning: "high"','Phrasal audit records writer reasoning intent');
need(phrasal,'criticReasoning: "low"','Phrasal audit records Luna low reasoning');
need(phrasal,'rareRescueModel: GEMINI_RARE_RESCUE_MODEL','Phrasal audit records rare rescue model');
need(phrasal,'schema.properties.optionA = { type: "string", enum: ["Yaad tha"] }','Recall A hard-lock retained');
need(phrasal,'schema.properties.optionD = { type: "string", enum: [""] }','Recall blank D hard-lock retained');
need(phrasal,'Reverse Recall front leaks the target phrasal verb','Recall target leak has deterministic code gate');
forbid(phrasal,'GROQ_MODEL','Phrasal no longer uses Groq');
forbid(phrasal,'GEMINI_BULK_MODEL','Phrasal no longer uses legacy Gemini bulk writer');

// Saved: claim first, then one item -> Antigravity -> code -> Luna; existing DB apply/finish stays intact.
need(saved,'antigravity_writer_v1','Saved checks writer rollout flag');
need(saved,'luna_critic_v1','Saved checks critic rollout flag');
need(saved,'english_saved_enrichment_worker_claim','Saved lease/claim contract retained');
need(saved,'runAntigravityLunaPipeline<any>','Saved uses new writer/critic pipeline');
need(saved,'items.map((item:any)=>enrichOne(item))','Saved items remain independent one-item workflows');
need(saved,'initialAntigravityRequests:0','Zero-pending response records zero writer calls');
need(saved,'english_saved_enrichment_worker_apply','Saved validated apply contract retained');
need(saved,'english_saved_enrichment_worker_finish','Saved lease finish/verification retained');
need(saved,'english_record_content_generation_audits','Saved audit writer retained');
need(saved,'requestMode:"one_item_per_generation_request"','Saved audit records one-item mode');
need(saved,'writerReasoning:"high"','Saved audit records writer reasoning intent');
need(saved,'criticReasoning:"low"','Saved audit records Luna low reasoning');
need(saved,'rareRescueModel:GEMINI_RARE_RESCUE_MODEL','Saved audit records rare rescue model');
forbid(saved,'GROQ_MODEL','Saved no longer uses Groq');
forbid(saved,'GEMINI_BULK_MODEL','Saved no longer uses legacy Gemini bulk writer');

// Hindu is intentionally isolated on the existing trusted-evidence Gemini/Groq implementation in Stage 1.
need(legacyHybrid,'GEMINI_BULK_MODEL','Legacy Hindu helper remains available');
need(legacyHybrid,'openai/gpt-oss-120b','Legacy Hindu Groq critic remains available');
need(hindu,'TRUSTED_FEEDS','Hindu existing trusted-feed path remains intact');
need(hindu,'generateCriticRepair','Hindu still uses its pre-existing hybrid helper');
forbid(hindu,'english-antigravity-luna','Hindu is not coupled to Stage-1 writer/critic helper');

console.log('\n✅ English Antigravity/Luna Stage-1 contracts passed.');
