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
const phrasalCap=read('supabase/managed-migrations/20260906033000_english_phrasal_context_fill_cap_six.sql');
const legacyHybrid=read('supabase/functions/_shared/english-hybrid-ai.ts');
const stage1=read('supabase/functions/_shared/english-antigravity-luna.ts');
const hindu=read('supabase/functions/english-content-task-bridge/generation.ts');
const saved=read('supabase/functions/english-saved-enrichment-worker/index.ts');
const phrasalWorker=read('supabase/functions/english-phrasal-worker/index.ts');
const singleSlot=read('supabase/functions/english-phrasal-worker/single-slot-generation.ts');
const rescueMigration=read('supabase/migrations/20260906040000_english_phrasal_single_slot_rescue.sql');
const rescueClaimFix=read('supabase/migrations/20260906040010_english_phrasal_single_slot_claim_ready_fix.sql');

// Existing deterministic foundation remains authoritative.
need(foundation,'enabled boolean not null default false','AI flags default off');
need(foundation,'coalesce((p_item->\'quality\'->>\'score\')::numeric,0) >= 85','DB quality threshold retained');
need(foundation,'requiredOptionsValid','DB family-aware option gate retained');
need(foundation,'english_ai_content_feature_enabled','Service-only flag read RPC retained');
need(metadata,'referenceVariant','Central-selected Phrasal reference variant retained');
need(metadata,'knownSenses','Known Phrasal senses reach generation');
need(phrasalCap,'eligible_rank<=6','Context-fill is capped at six');
forbid(phrasalCap,'eligible_rank<=8','Eight-slot context-fill cap is retired');
need(metadata,'public.english_get_phrasal_maintenance_batch(p_mode,p_count)','Central Intelligence remains upstream Phrasal selector');
need(materializer,'jsonb_array_length(p_items)<>20','Phrasal publication remains exact-20');
need(materializer,'v_expected_ids is distinct from v_given_ids','Exact Central concept-set gate retained');
need(materializer,"'Yaad tha'",'Recall A contract retained');
need(materializer,"'Confused'",'Recall B contract retained');
need(materializer,"'Bhool gaya'",'Recall C contract retained');
need(savedScheduler,"jobname='english-saved-enrichment'",'Saved hourly scheduler ownership retained');
need(savedScheduler,"'7 * * * *'",'Saved hourly cadence retained');

// Dedicated Stage-1 rollout flags remain for shared/Phrasal infrastructure.
need(stage1Flags,"'antigravity_writer_v1'",'Antigravity writer flag exists');
need(stage1Flags,"'luna_critic_v1'",'Luna flag exists');
need(stage1Flags,'"scope":["saved","phrasal"]','Historical flag scope remains auditable');
need(stage1Flags,'"reasoning":"high"','Writer reasoning intent recorded');
need(stage1Flags,'"reasoning":"low"','Critic reasoning intent recorded');

// Shared Antigravity/Luna helper remains intact for Phrasal. Saved no longer calls its retry pipeline.
need(stage1,'antigravity-preview-05-2026','Antigravity managed agent remains available to Phrasal');
need(stage1,'gemini-3.6-flash','Shared helper retains Flash fallback');
need(stage1,'https://generativelanguage.googleapis.com/v1beta/interactions','Antigravity uses Interactions API');
need(stage1,'environment:"remote"','Antigravity remote environment retained');
need(stage1,'store:true','Antigravity stateful interaction mode retained');
forbid(stage1,'store:false','Antigravity stateless mode is forbidden');
need(stage1,'max_total_tokens','Antigravity token budget remains bounded');
need(stage1,'english_claim_antigravity_request_budget','Every shared primary writer stage is request-budget guarded');
need(stage1,'BUDGET_GUARD_FAIL_CLOSED','Budget guard fails closed to Gemini');
need(stage1,'maxAttempts:1','Primary Antigravity transport gets one request attempt per writer stage');
need(stage1,'english_mark_antigravity_quota_exhausted','429 opens the Antigravity circuit for the day');
need(stage1,'geminiFallbackWriterJson','Shared helper can replace Antigravity as writer');
need(stage1,'gpt-5.6-luna','Luna 5.6 remains available to shared/Phrasal pipeline');
need(stage1,'reasoning:{effort:"low"}','Shared Luna reasoning remains low');
need(stage1,'q.score>=85','Shared runtime PASS threshold is 85');
need(stage1,'Object.values(q.hardGates||{}).every(Boolean)','Shared semantic hard gates must pass');
need(stage1,'First Luna non-PASS (REPAIR or REJECT) returns to the primary writer route.','Phrasal shared repair path retained');
need(stage1,'A second Luna non-PASS reaches Gemini 3.8 high-reasoning rescue exactly once.','Phrasal shared rare rescue retained');
need(stage1,'thinkingConfig:{thinkingLevel:"high"}','Shared Gemini rare rescue reasoning is high');
need(stage1,'antigravityRequests','Actual Antigravity request count is surfaced');
need(stage1,'geminiWriterRequests','Actual Gemini writer/rescue count is surfaced');
forbid(stage1,'GROQ_API_KEY','Saved/Phrasal shared helper does not use Groq');

// Today-specific budget reservation remains for routes that still use Antigravity.
need(rescueMigration,"values ('2026-09-06'::date, 'antigravity', 100, 12, 73, 0, now())",'2026-09-06 Antigravity budget starts from 73/100 with 12 reserved');
need(rescueMigration,'v_limit := greatest(0, r.max_requests - r.reserve_requests)','Reserve is excluded before Antigravity call');
need(rescueMigration,"'ANTIGRAVITY_BUDGET_RESERVED'",'Budget exhaustion routes away before provider call');
need(rescueMigration,"((v_day + 1)::timestamp at time zone 'Asia/Kolkata')",'Quota circuit expires at next IST day');

// Phrasal one-slot lifecycle: Central selects once, slots persist independently, publication still exact-20 atomic.
need(rescueMigration,'english.phrasal_generation_batches','Phrasal selection snapshot table exists');
need(rescueMigration,'english.phrasal_generation_slots','Independent slot checkpoint table exists');
need(rescueMigration,'english.maintenance_phrasal_batch(20)','Central Intelligence still creates the 20-concept selection');
need(rescueMigration,"status text not null default 'pending'",'Slot lifecycle starts pending');
need(rescueMigration,"status in ('pending','processing','ready','failed')",'Slot lifecycle is explicit');
need(rescueMigration,'unique (batch_date, concept_id)','One Central concept occupies one daily slot');
need(rescueClaimFix,'v_has_slot := found','No-slot completion check is not clobbered by later SQL');
need(rescueClaimFix,"order by case status when 'pending' then 0 else 1 end,slot_no",'Fresh pending slots progress before retrying a failed slot');
need(rescueClaimFix,"'publishReady',true,'items',v_items",'All 20 checkpointed items can resume atomic publication');
need(phrasalWorker,'english_phrasal_single_slot_claim','Worker claims one persisted slot');
need(phrasalWorker,'finalizeSinglePhrasalItem','Worker finalizes exactly one Central assignment');
need(phrasalWorker,'english_phrasal_single_slot_store','Success/failure is checkpointed per slot');
need(phrasalWorker,'body?.publish!==false','Manual validation can checkpoint without publishing');
need(phrasalWorker,'english_phrasal_task_apply','Existing exact-20 atomic apply remains publication authority');
need(phrasalWorker,'english_phrasal_single_slot_mark_applied','Staging lifecycle records final apply');
forbid(phrasalWorker,'english_release_content_task_claim','One slot failure must not release/regenerate the whole 20-slot batch');
need(singleSlot,'function legacyPhrasal','Serviceable canonical card can bypass AI');
need(singleSlot,'deterministicRecallFromCanonical','Recall can be built deterministically before writer escalation');
need(singleSlot,'runAntigravityLunaPipeline<any>','Only a real Phrasal gap/refinement enters bounded shared writer/critic pipeline');
need(singleSlot,'recentConceptStems','Anti-repeat evidence reaches writer');
need(singleSlot,'selectedVariantCooled','Central cooldown signal reaches writer');
need(singleSlot,'Reverse Recall front leaks the target phrasal verb','Recall target leak is code-gated');
need(singleSlot,'antigravityRequests:reviewed.antigravityRequests','Per-slot Antigravity usage is persisted');
forbid(singleSlot,'mapLimit','Single-slot worker must not fan out 20 AI jobs concurrently');
forbid(singleSlot,'GROQ_MODEL','Phrasal does not use Groq');

// Saved is now independent smart routing: no Antigravity and no blanket Luna critic.
need(saved,'english_saved_enrichment_worker_claim','Saved lease/claim contract retained');
need(saved,'SAVED_GEMINI_38_MODEL','Saved normal/confusion primary is Gemini 3.8');
need(saved,'SAVED_GEMINI_36_MODEL','Saved availability fallback is Gemini 3.6');
need(saved,'SAVED_GEMINI_35_MODEL','Saved easy meaning route uses Gemini 3.5');
need(saved,'function routeKind(item:any):RouteKind','Saved uses deterministic EASY/NORMAL/CONFUSION routing');
need(saved,'lunaRescueJson','Saved has a one-shot Luna rescue writer');
need(saved,'maxLunaCallsPerItem:1','Saved Luna spend is bounded to one rescue call per item');
need(saved,'criticRequests:0','Saved blanket critic calls are zero');
need(saved,'antigravityRequests:0','Saved Antigravity calls are zero');
need(saved,'items.map((item:any)=>enrichOne(item,forceModel))','Saved items remain independent one-item workflows');
need(saved,'english_saved_enrichment_worker_apply','Saved validated apply contract retained');
need(saved,'english_saved_enrichment_worker_finish','Saved finish/verification retained');
forbid(saved,'runAntigravityLunaPipeline<any>','Saved no longer enters shared Antigravity/Luna retry pipeline');
forbid(saved,'ANTIGRAVITY_AGENT','Saved no longer depends on Antigravity');
forbid(saved,'GROQ_MODEL','Saved does not use Groq');

// Hindu remains isolated.
need(legacyHybrid,'GEMINI_BULK_MODEL','Legacy Hindu helper remains available');
need(legacyHybrid,'openai/gpt-oss-120b','Legacy Hindu Groq critic remains available');
need(hindu,'TRUSTED_FEEDS','Hindu trusted-feed path remains intact');
need(hindu,'generateCriticRepair','Hindu retains its existing hybrid helper');
forbid(hindu,'english-antigravity-luna','Hindu is not coupled to the Saved/Phrasal helper');

console.log('\n✅ English hybrid contracts passed: Phrasal shared Antigravity/Luna retained; Saved smart-routed independently.');
