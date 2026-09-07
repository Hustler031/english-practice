const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const migration=fs.readFileSync(path.join(root,'supabase/migrations/20260907213000_english_saved_capture_origin.sql'),'utf8');
function need(s,n,l){if(!s.includes(n))throw new Error(`Missing ${l}: ${n}`)}
need(migration,"add column if not exists capture_origin",'capture-origin column');
need(migration,"('AUTO','USER_EXPLICIT','LEGACY_UNKNOWN')",'capture-origin enum');
need(migration,"v_capture_origin:=case when v_requested_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end",'new-save explicit intent');
need(migration,"v_capture_origin:=case when v_capture='AUTO' then 'AUTO' else 'USER_EXPLICIT' end",'category-editor explicit intent');
need(migration,"v_capture:=v_existing_capture",'duplicate AUTO preserves explicit category');
need(migration,"v_capture_origin:=coalesce(v_existing_origin,'LEGACY_UNKNOWN')",'duplicate AUTO preserves category provenance');
need(migration,"english.resolve_saved_type_authoritative(v_capture,s.word,s.context,v_origin_topic)",'resolved family stays separate from capture intent');
console.log('English Saved explicit capture provenance contract: PASS');
