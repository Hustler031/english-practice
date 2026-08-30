import fs from "node:fs";
import path from "node:path";
import {execFileSync} from "node:child_process";

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const exists=p=>fs.existsSync(path.join(root,p));
const app=read("components/maths-app.tsx");
const frame=read("components/maths-frame.tsx");
const rpc=read("lib/maths-rpc.ts");
const diagram=read("components/maths-diagram.tsx");
const css=read("app/maths/maths.css");
const launcher=read("app/page.tsx");
const failures=[];
const has=(label,text,needle)=>{if(!text.includes(needle))failures.push(`${label}: missing ${needle}`)};
const hasRegex=(label,text,regex,description)=>{if(!regex.test(text))failures.push(`${label}: missing ${description}`)};
const lacks=(label,text,needle)=>{if(text.includes(needle))failures.push(`${label}: must not contain ${needle}`)};

for(const label of ["Home","Chapters","Library","On Demand","Progress"])has("Maths nav",frame,`label:\"${label}\"`);
const staticRoutes=["","chapters","library","ondemand","progress","mocks","formulas","calculation","concepts","demand","new","starred","generated","session","resume"];
for(const name of staticRoutes){const p=name?`app/maths/${name}/page.tsx`:"app/maths/page.tsx";if(!exists(p))failures.push(`Static route missing: ${p}`);else has(`Static route ${name||"home"}`,read(p),"MathsApp");}
if(exists("app/maths/[[...slug]]/page.tsx"))failures.push("Dynamic catch-all must not exist under output: export");
for(const section of ["chapters","library","ondemand","progress","mocks","formulas","calculation","concepts","demand","new","starred","generated","session","resume"]){
  const escaped=section.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
  hasRegex("Route controller",app,new RegExp(`section\\s*={2,3}\\s*[\"']${escaped}[\"']`),`section === \"${section}\"`);
}
for(const rpcName of ["maths_get_home_snapshot","maths_get_chapters_hub","maths_get_chapter","maths_get_library_hub","maths_get_ondemand_hub","maths_get_progress","maths_get_mocks_hub","maths_get_formula_hub","maths_get_calculation_hub","maths_get_concepts_hub","maths_get_demand_hub","maths_start_daily","maths_start_practice_more","maths_start_focused_practice","maths_start_mock_practice","maths_start_formula_revision","maths_start_calculation","maths_start_concepts","maths_start_demand_set","maths_get_session","maths_save_session_position","maths_submit_answer","maths_finish_session","maths_set_starred","maths_set_difficult","maths_set_concept"])has("RPC integration",app+rpc,rpcName);
for(const marker of ["maths_get_local_safe_start","mathsLocalSafe","OUTBOX_PREFIX","BACKOFF","visibilitychange","maths:v2-sync-change","maths:v2-owner-change","RPC_TIMEOUT_MS","cacheEpoch","readInflight","queueMutation","failedMathsWrites","p_client_attempt_key"])has("Reliability",rpc,marker);
for(const marker of ["answerMode","Reveal Answer","☆ Starred","◆ Difficult","＋ Concept","Ⅱ Pause","Jump to question","Previous","Finish"])has("Quiz",app,marker);
for(const marker of ["REVEAL","localSafeStart","queueAnswer"])has("Runtime",rpc,marker);
for(const marker of ["MathsDiagram","math-diagram","structured_json_untyped","Not drawn to scale"])has("Diagram renderer",app+diagram,marker);
lacks("Diagram renderer",app,"Diagram payload preserved");
for(const message of ["Answer this question first.","Reveal the answer first."])has("Quiz navigation guard",app,message);
for(const file of ["20260830191345_maths_v2_final_audit_hardening.sql","20260830192647_maths_v2_restore_diagram_ledger.sql","20260830193148_maths_v2_session_snapshot_repair.sql","20260830193522_maths_v2_chapter_group_boundary_fix.sql"]){
  if(!exists(`../supabase/managed-migrations/${file}`))failures.push(`Maths migration mirror missing: ${file}`);
}
for(const marker of ["MOCK_QUESTIONS","MOCK_FORMULA_REVISION","MEMORY","METHOD","DRILL","Weak & Slow","Major Topics","Practice More"])has("Maths semantics",app+rpc,marker);
has("Static export session identity",app,'search.get("id")');
has("Static export chapter identity",app,'search.get("chapter")');
has("Static export topic identity",app,'search.get("topic")');
has("Root launcher",launcher,'href="/maths"');
has("Safe area",css,"env(safe-area-inset-bottom)");
lacks("Maths UI",app,"Add Word");
lacks("Maths UI",app,"Hindu");
lacks("Maths UI",app,"Phrasal");

try{
 const base="6a529afb470bf6056ed9e42785605f8c9b4c67ba";
 const changed=execFileSync("git",["diff","--name-only",`${base}...HEAD`],{cwd:path.resolve(root,".."),encoding:"utf8"}).trim().split(/\r?\n/).filter(Boolean);
 const forbidden=changed.filter(p=>p.startsWith("web-v2/app/english/")||p.startsWith("web-v2/components/english-")||p.startsWith("web-v2/app/gk/")||p.startsWith("web-v2/lib/gk"));
 if(forbidden.length)failures.push(`English/GK regression boundary violated: ${forbidden.join(", ")}`);
}catch(e){failures.push(`Unable to verify regression boundary: ${e.message}`)}

if(failures.length){console.error("Maths V2 contract validation FAILED\n- "+failures.join("\n- "));process.exit(1)}
console.log("Maths V2 contract validation PASS");
