/* Repository-side drift/ownership contract. It deliberately needs no production secret. */
const fs=require('fs');
const must=(path,needle)=>{const text=fs.readFileSync(path,'utf8');if(!text.includes(needle))throw new Error(`${path} is missing ${needle}`);return text};
const context=must('supabase/functions/english-context-worker/index.ts','english_context_diagnosis');
const revision=must('supabase/functions/english-revision-worker/index.ts','english_question_revision_claim_dedicated');
if(/english_question_revision_claim\b/.test(context)||/english_question_quality_review_claim/.test(context))throw new Error('context worker still owns quality/revision jobs');
for(const code of ['AI_TIMEOUT','RATE_LIMIT','PROVIDER_5XX','NETWORK_TRANSIENT','MALFORMED_OUTPUT','QUALITY_REJECTED','STALE_INPUT','AUTH_CONFIG','RETRIES_EXHAUSTED'])must('supabase/managed-migrations/20260905090000_english_ai_architecture_stage1.sql',code);
must('supabase/managed-migrations/MANIFEST.md','20260904193504');
console.log('English AI architecture ownership and lifecycle contracts passed.');
