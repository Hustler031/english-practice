const fs=require('fs');
const path=require('path');
const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const need=(t,s,m)=>{if(!t.includes(s))throw new Error(`${m}: missing ${s}`);console.log(`✅ ${m}`)};

const migration=read('supabase/managed-migrations/20260906025000_english_content_task_failure_release.sql');
const hindu=read('supabase/functions/english-content-task-bridge/generation.ts');
const phrasal=read('supabase/functions/english-content-task-bridge/phrasal-generation.ts');

need(migration,'english_release_content_task_claim','Service-only content task release RPC');
need(migration,"auth.role() <> 'service_role'",'Release RPC rejects non-service callers');
need(migration,"status in ('claimed','checked')",'Release only touches unfinished task claims');
need(migration,"status='superseded'",'Failed claim becomes retryable immediately');
need(migration,"updated_at < now()-interval '20 minutes'",'Rollout only recovers genuinely stale unfinished claims');
need(migration,"lane in ('hindu','phrasal')",'Rollout recovery is limited to content lanes');
need(migration,'grant execute on function public.english_release_content_task_claim(uuid,text,text) to service_role','Only service role receives execute');
need(migration,'revoke all on function public.english_release_content_task_claim(uuid,text,text) from public,anon,authenticated','Learner roles cannot release claims');

for(const [name,src,prefix,lane] of [['Hindu',hindu,'HINDU','hindu'],['Phrasal',phrasal,'PHRASAL','phrasal']]){
  need(src,'claim?.busy',`${name} checks for an active claim`);
  need(src,`${prefix}_BUSY:`,`${name} busy response is not reported as completion`);
  need(src,'async function releaseClaim',`${name} has bounded claim-release helper`);
  need(src,'english_release_content_task_claim',`${name} calls service release RPC on failure`);
  need(src,`p_lane:${JSON.stringify(lane)}`,`${name} release is lane-scoped`);
  need(src,'await releaseClaim(db,runId,e)',`${name} releases its own run before rethrow`);
}

console.log('\n✅ Content task busy/failure recovery contracts passed.');
