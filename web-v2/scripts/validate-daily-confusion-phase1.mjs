import fs from "node:fs";
import path from "node:path";

const root=path.resolve(process.cwd(),"..");
const read=(p)=>fs.readFileSync(path.join(root,p),"utf8");
const requireText=(text,needle,label)=>{if(!text.includes(needle))throw new Error(`${label}: missing ${needle}`)};
const forbidText=(text,needle,label)=>{if(text.includes(needle))throw new Error(`${label}: forbidden ${needle}`)};

const page=read("web-v2/app/english/hindu/page.tsx");
const home=read("web-v2/app/english/page.tsx");
const bridge=read("supabase/functions/english-content-task-bridge/index.ts");
const submitted=read("supabase/functions/english-content-task-bridge/submitted-confusion.ts");
const migration=read("supabase/migrations/20260912180000_english_daily_confusion_phase1.sql");

requireText(page,"Daily Confusion 15","confusion page");
requireText(page,'rpc<Q[]>("english_get_confusion_quiz")',"confusion page");
requireText(page,'rpc<any>("english_submit_confusion_answer"',"confusion page");
requireText(page,'rpc("english_set_starred"',"confusion page");
requireText(page,'module:"confusion"',"confusion context");
forbidText(page,"Save Vocab","confusion page");
forbidText(page,"english_add_hindu_to_vocab","confusion page");
forbidText(page,"english_set_hindu_vocab","confusion page");
forbidText(page,"english_get_hindu_quiz","confusion page");
forbidText(page,"The Hindu · Round","confusion page");

requireText(home,'"Daily Confusion 15"',"home");
requireText(home,'"english_confusion_progress"',"home");

requireText(bridge,'ingestSubmittedConfusionItems',"content bridge");
requireText(bridge,'items.length>15',"content bridge");
requireText(bridge,'Legacy Hindu/current-news generation is disabled',"content bridge");
forbidText(bridge,'runHinduGeneration',"content bridge");

requireText(submitted,'"Confusable Words"',"submitted confusion");
requireText(submitted,'"Phrasal Verb Contrast"',"submitted confusion");
requireText(submitted,'"Look-alike / Spelling"',"submitted confusion");
requireText(submitted,'"Homophone / Homonym"',"submitted confusion");
requireText(submitted,'"Usage / Collocation"',"submitted confusion");
forbidText(submitted,"sourceUrl","submitted confusion");
forbidText(submitted,"articleTitle","submitted confusion");

requireText(migration,"create table if not exists english.daily_confusion_items","migration");
requireText(migration,"'Confusable Words' then 4","migration");
requireText(migration,"'Phrasal Verb Contrast' then 3","migration");
requireText(migration,"'Look-alike / Spelling' then 3","migration");
requireText(migration,"'Homophone / Homonym' then 2","migration");
requireText(migration,"'Usage / Collocation' then 3","migration");
requireText(migration,"'CONFUSION_'||v_bank_id","migration");
requireText(migration,"'deterministic_confusion_bank'","migration");
requireText(migration,"'confusion',v_id,now()","migration");
requireText(migration,"english.recompute_question_state(uid,v_qid)","migration");
requireText(migration,"exactDailyTarget',15","migration");
requireText(migration,"english.question_concept_mappings","migration");

console.log("Daily Confusion Phase 1 contracts: PASS");
