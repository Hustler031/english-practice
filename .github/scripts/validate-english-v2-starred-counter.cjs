const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const migration=path.join(root,'supabase/managed-migrations/20260831207500_english_starred_route_counter_reconciliation.sql');
let failed=0;
function ok(cond,msg){if(cond)console.log('PASS',msg);else{console.error('FAIL',msg);failed++;}}
ok(fs.existsSync(migration),'Starred route counter reconciliation migration exists');
if(fs.existsSync(migration)){
 const sql=fs.readFileSync(migration,'utf8');
 for(const marker of ["PROVENANCE_RECONCILE","'From Starred'","entered_fast_track_at","targeted_at","starred-origin-reconcile:","on conflict(event_key) do nothing"]){
  ok(sql.includes(marker),`Starred counter reconciliation includes ${marker}`);
 }
 ok(!/update\s+english\.learning_route_state/i.test(sql),'Counter reconciliation does not mutate route state');
 ok(!/delete\s+from\s+english\.(attempts|question_state|saved_items|star_events)/i.test(sql),'Counter reconciliation does not delete learning evidence');
}
if(failed)process.exit(1);
console.log('English V2 Starred route counter reconciliation contracts PASS');
