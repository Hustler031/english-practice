const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const file=path.join(root,'supabase/managed-migrations/20260831208000_english_new_helper_search_path_hardening.sql');
let failed=0;
function ok(cond,msg){if(cond)console.log('PASS',msg);else{console.error('FAIL',msg);failed++;}}
ok(fs.existsSync(file),'New English helper search-path hardening migration exists');
if(fs.existsSync(file)){
 const sql=fs.readFileSync(file,'utf8').toLowerCase();
 const sigs=[
  'english.route_add_origin(text[],text)',
  'english.sprint_expected_count(text)',
  'english.sprint_allowed_type(text)',
  'english.sprint_validate_options(jsonb,text)',
  'english.route_origin_matches(text[],text)',
  'english.route_origin_label(text)',
  'english.route_recovery_origin(text)',
  'english.sprint_option_text(jsonb,text)'
 ];
 for(const sig of sigs) ok(sql.includes(`alter function ${sig} set search_path = pg_catalog`),`${sig} locks search_path to pg_catalog`);
 ok(!/drop\s+(table|function|schema)/i.test(sql),'Search-path hardening is non-destructive');
 ok(!/(insert|update|delete)\s+/i.test(sql),'Search-path hardening does not mutate learning data');
}
if(failed)process.exit(1);
console.log('English V2 new-helper search-path hardening contracts PASS');
