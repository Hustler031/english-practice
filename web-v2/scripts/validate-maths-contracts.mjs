import fs from "node:fs";
import path from "node:path";
import {execFileSync} from "node:child_process";

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const app=read("components/maths-app.tsx");
const frame=read("components/maths-frame.tsx");
const rpc=read("lib/maths-rpc.ts");
const css=read("app/maths/maths.css");
const route=read("app/maths/[[...slug]]/page.tsx");
const launcher=read("app/page.tsx");
const failures=[];
const has=(label,text,needle)=>{if(!text.includes(needle))failures.push(`${label}: missing ${needle}`)};
const lacks=(label,text,needle)=>{if(text.includes(needle))failures.push(`${label}: must not contain ${needle}`)};

for(const label of ["Home","Chapters","Library","On Demand","Progress"])has("Maths nav",frame,`label:\"${label}\"`);
for(const routeName of ["chapters","library","ondemand","progress","mocks","formulas","calculation","concepts","demand","new","starred","session","resume"])has("Route controller",app,`first===\"${routeName}\"`);
for(const rpcName of ["maths_get_home_snapshot","maths_get_chapters_hub","maths_get_chapter","maths_get_library_hub","maths_get_ondemand_hub","maths_get_progress","maths_get_mocks_hub","maths_get_formula_hub","maths_get_calculation_hub","maths_get_concepts_hub","maths_get_demand_hub","maths_start_daily","maths_start_practice_more","maths_start_focused_practice","maths_start_mock_practice","maths_start_formula_revision","maths_start_calculation","maths_start_concepts","maths_start_demand_set","maths_get_session","maths_save_session_position","maths_submit_answer","maths_finish_session","maths_set_starred","maths_set_difficult","maths_set_concept"])has("RPC integration",app+rpc,rpcName);
for(const marker of ["maths_get_local_safe_start","mathsLocalSafe","OUTBOX_KEY","BACKOFF","visibilitychange","maths:v2-sync-change","p_client_attempt_key"])has("Reliability",rpc,marker);
for(const marker of ["answerMode","Reveal Answer","☆ Starred","◆ Difficult","＋ Concept","Ⅱ Pause","Jump to question","Previous","Finish"])has("Quiz",app,marker);
for(const marker of ["REVEAL","localSafeStart","queueAnswer"])has("Runtime",rpc,marker);
for(const marker of ["MOCK_QUESTIONS","MOCK_FORMULA_REVISION","MEMORY","METHOD","DRILL","Weak & Slow","Major Topics","Practice More"])has("Maths semantics",app+rpc,marker);
has("Root launcher",launcher,'href="/maths"');
has("Catch-all route",route,"MathsApp");
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
