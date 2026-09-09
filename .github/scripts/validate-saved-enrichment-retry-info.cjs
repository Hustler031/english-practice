const fs=require('fs');
const path=require('path');
const root=path.join(__dirname,'../..');
const worker=fs.readFileSync(path.join(root,'supabase/functions/english-saved-enrichment-worker/index.ts'),'utf8');
const retryMigration=fs.readFileSync(path.join(root,'supabase/migrations/20260909133000_english_saved_one_minute_retry.sql'),'utf8');
const terminalMigration=fs.readFileSync(path.join(root,'supabase/migrations/20260909150000_english_saved_luna_manual_terminal.sql'),'utf8');
let bad=0;
const need=(s,x,m)=>s.includes(x)?console.log('✓ '+m):(bad++,console.error('✗ '+m+' :: '+x));
const forbid=(s,x,m)=>!s.includes(x)?console.log('✓ '+m):(bad++,console.error('✗ '+m+' :: '+x));

// Provider availability can fall back/retry, but content-quality failure never enters a critic loop.
need(worker,'SAVED_GEMINI_36_MODEL','Gemini 3.6 remains the Google availability fallback');
need(worker,'availabilityError','Worker distinguishes provider availability from content rejection');
need(worker,'status:"code_reject"','Deterministic content failure is explicitly traced');
need(worker,'return await rescue','Failed Google candidate escalates directly to Luna rescue');
need(worker,'SAVED_MANUAL_REVIEW_REQUIRED','Failed Luna rescue exposes terminal manual-review reason');
need(worker,'maxLunaCallsPerItem:1','Luna is bounded to one rescue call per item');
need(worker,'criticRequests:0','Blanket Luna critic is disabled');
forbid(worker,'gemini36ReviewedFallback','Legacy Luna-reviewed fallback loop removed');
forbid(worker,'runAntigravityLunaPipeline','Legacy Antigravity/Luna retry pipeline removed');

// Current DB retry policy: transient provider failures can retry quickly.
need(retryMigration,'english_saved_enrichment_worker_finish_v2','Current Saved finish/retry controller exists');
need(retryMigration,"state='retrying'",'Transient provider failures enter retry state');
need(retryMigration,"next_attempt_at=now()+interval '1 minute'",'Transient provider failures use one-minute retry cadence');
need(retryMigration,"not (coalesce(es.state,'')='retrying'",'Cooling-down retries are excluded from claims');
need(retryMigration,"coalesce(es.state,'') not in ('processing','failed')",'Terminal failed items are excluded from claims');

// New hard stop: one-shot Luna failure is manual, not another automatic generation cycle.
need(terminalMigration,'SAVED_MANUAL_REVIEW_REQUIRED:%','One-shot rescue terminal marker exists');
need(terminalMigration,"new.state:='failed'",'One-shot Luna failure becomes failed immediately');
need(terminalMigration,'new.next_attempt_at:=null','Manual-review item has no scheduled retry');
need(terminalMigration,"new.last_error_class:='manual'",'Manual-review state is distinguishable from transient provider errors');
need(terminalMigration,'trg_saved_enrichment_manual_terminal_guard','Terminal guard is installed on Saved item state');

if(bad){console.error(`\nSaved enrichment retry contracts failed with ${bad} defect(s).`);process.exit(1)}
console.log('\n✅ Saved enrichment retry contract passed: transient provider retry only; Luna rescue failure is terminal/manual.');
