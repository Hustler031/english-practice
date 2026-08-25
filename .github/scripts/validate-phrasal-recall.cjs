const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const strip=t=>t.replace(/<\/?script[^>]*>/gi,'');
let failed=false;
const ok=m=>console.log(`✅ ${m}`);
const fail=m=>{failed=true;console.error(`❌ ${m}`)};
const need=(t,s,m)=>t.includes(s)?ok(m):fail(`${m} — missing ${s}`);
const forbid=(t,s,m)=>!t.includes(s)?ok(m):fail(`${m} — forbidden ${s}`);

const required=['QuizJS.html','PhrasalMastery.gs','PhrasalMasteryUI.html','NavigationPolishUI.html','SaveReliabilityUI.html','AnswerBatchV4.gs','LearningIntelligence.gs'];
required.forEach(n=>fs.existsSync(path.join(root,n))?ok(`File present: ${n}`):fail(`Missing file: ${n}`));
if(failed)process.exit(1);
const quiz=read('QuizJS.html'),pv=read('PhrasalMastery.gs'),pvui=read('PhrasalMasteryUI.html'),nav=read('NavigationPolishUI.html'),save=read('SaveReliabilityUI.html'),batch=read('AnswerBatchV4.gs'),learning=read('LearningIntelligence.gs');
for(const [n,t] of [['QuizJS.html',quiz],['PhrasalMasteryUI.html',pvui],['NavigationPolishUI.html',nav],['SaveReliabilityUI.html',save]]){try{new vm.Script(strip(t),{filename:n});ok(`Frontend syntax: ${n}`)}catch(e){fail(`Frontend syntax failed ${n}: ${e.message}`)}}
for(const [n,t] of [['PhrasalMastery.gs',pv],['AnswerBatchV4.gs',batch],['LearningIntelligence.gs',learning]]){try{new vm.Script(t,{filename:n});ok(`Server syntax: ${n}`)}catch(e){fail(`Server syntax failed ${n}: ${e.message}`)}}

const originalIds=['PV0227','PV0228','PV0229','PV0230','PV0231','PV0232','PV0233','PV0234','PV0235','PV0236','PV0237','PV0238','PV0239','PV0240','PV0241'];
const originalConcepts=['PV_CALL_OFF','PV_FALL_BACK_ON','PV_GET_OVER','PV_LOOK_UP','PV_LOOK_FORWARD_TO','PV_PUT_ASIDE','PV_RUN_OUT','PV_SET_ASIDE','PV_CALL_IN','PV_BREAK_OFF','PV_SET_OUT','PV_FALL_TO','PV_GET_ACROSS','PV_BEAR_AWAY','PV_FALL_APART'];
const newIds=['PV0242','PV0243','PV0244','PV0245','PV0246'];
const newConcepts=['PV_LOOK_AFTER','PV_BREAK_WITH','PV_MAKE_UP','PV_BRING_OVER','PV_LOOK_ON'];
if(new Set([...originalIds,...newIds]).size===20)ok('Today’s 20 fixture has unique Question_IDs');else fail('Today’s 20 fixture has Question_ID collision');
if(new Set([...originalConcepts,...newConcepts]).size===20)ok('Today’s 20 fixture has 20 concept-distinct slots');else fail('Today’s 20 fixture leaks a Concept_ID between recognition and recall slots');
if(newConcepts.every(x=>!originalConcepts.includes(x)))ok('Five recall concepts exclude all original 15 concepts');else fail('A recall concept duplicates today’s original 15');

need(quiz,"function isRecallCard(q)",'Existing EPQuiz recognises Reverse Recall Card');
need(quiz,'reverse recall card','Recall type is driven by existing Question_Type');
need(quiz,'Think of the Phrasal Verb first.','Recall prompt asks for independent retrieval before reveal');
need(quiz,'View Answer','Recall card has explicit answer reveal');
need(quiz,'✓ Yaad tha','Recall card exposes successful-recall self rating');
need(quiz,'~ Confused','Recall card exposes partial/uncertain self rating');
need(quiz,'✕ Bhool gaya','Recall card exposes forgotten self rating');
need(quiz,'data-key="A"','Yaad tha maps to A');
need(quiz,'data-key="B"','Confused maps to B');
need(quiz,'data-key="C"','Bhool gaya maps to C');
forbid(quiz,'data-key="D"','Recall card has no fourth self-rating button');
need(quiz,'q.options.forEach','Normal MCQ rendering path remains present');
need(quiz,"EPApp.call('submitAnswer'",'Recall ratings reuse the existing central answer call');
need(save,"OUTBOX_KEY='ep-answer-outbox-v3'",'Existing answer outbox remains authoritative');
need(save,"p.module=fn.indexOf('Hindu')>=0?'hindu':moduleForQuestion(id)",'Outbox derives Module from the existing quiz session');
need(save,'p.attemptId=String(p.attemptId||\'\').trim()||makeAttemptId(id)','Outbox still creates one stable Attempt_ID before retry');
need(save,"direct('submitAnswerBatchV4'",'Outbox still drains through submitAnswerBatchV4');
need(batch,"if(!['A','B','C','D'].includes(selected))",'Existing batch endpoint accepts A/B/C without a new save protocol');
need(batch,'Selected_Answer:x.selected','Performance keeps selected A/B/C distinctly');
need(batch,'Concept_ID:x.q.conceptId','Performance keeps Concept_ID');
need(batch,'Attempt_ID:x.attemptId','Performance keeps stable Attempt_ID');

need(pv,'phrasalQuestionFamilyV2_','Phrasal normalises Question_Type into learning families');
need(pv,"return'recall'",'Reverse Recall is an independent-recall family');
need(pv,"return'confusion'",'Confusion/discrimination has a separate family');
need(pv,"return'recognition'",'Existing application/meaning questions remain recognition evidence');
need(pv,'recallConfused','Confused evidence remains separately countable');
need(pv,'recallForgotten','Forgotten evidence remains separately countable');
need(pv,'recallWeak','Recognised-but-not-retrievable signal exists');
need(pv,'phrasalPreferredFamilyV2_','Smart Phrasal chooses the learning family before variant rotation');
need(pv,"if(e.recallWeak&&e.recognitionStrong)return'recall'",'Recognition-strong + Recall-weak prioritises a recall variant');
need(pv,'phrasalChooseVariantV1_','Existing permanent Question_ID variant chooser remains authoritative');
forbid(pv,'appendRow(','Phrasal intelligence adds no second attempt writer');
forbid(pv,'insertSheet','Phrasal intelligence adds no schema');
forbid(pv,'Recall_Performance','No Recall_Performance sheet is introduced');
need(pv,"EP_PHRASAL_DAILY_TARGET=20",'Future Phrasal daily target is 20');
need(pvui,'function dailyTarget(t)','Today UI derives the visible count from permanent batch data');
need(pvui,'actual>0?actual','Actual permanent source count overrides the target label');
need(pvui,'Practice ${esc(label)}','Today practice button uses the derived count');
need(nav,'Smart + Today’s 20','Home quick status reflects Today’s 20');
need(nav,'Today’s 20 · Smart Revision','Library Phrasal entry reflects Today’s 20');

function intelligenceRegression(){
  try{
    const ctx={console,Date,Set,Math};vm.createContext(ctx);vm.runInContext(learning,ctx,{filename:'LearningIntelligence.gs'});vm.runInContext(pv,ctx,{filename:'PhrasalMastery.gs'});
    ctx.questions=[{id:'R1',questionType:'Meaning'},{id:'R2',questionType:'Fill in the blank'},{id:'R3',questionType:'Contextual meaning'},{id:'C1',questionType:'Reverse Recall Card'}];
    ctx.facts={byId:{R1:[{ts:new Date('2026-08-20T00:00:00Z'),correct:true,selected:'A'}],R2:[{ts:new Date('2026-08-22T00:00:00Z'),correct:true,selected:'B'}],R3:[{ts:new Date('2026-08-24T00:00:00Z'),correct:true,selected:'C'}],C1:[{ts:new Date('2026-08-25T00:00:00Z'),correct:false,selected:'B'},{ts:new Date('2026-08-25T01:00:00Z'),correct:false,selected:'C'}]}};
    const e=vm.runInContext('phrasalConceptTypeEvidenceV2_(questions,facts)',ctx);ctx.e=e;
    if(!e.recognitionStrong)throw new Error('recognition evidence should be strong');
    if(!e.recallWeak)throw new Error('B/C recall evidence should produce recallWeak');
    if(e.recallConfused!==1||e.recallForgotten!==1)throw new Error('Confused and Bhool gaya were not distinguished');
    if(vm.runInContext("phrasalPreferredFamilyV2_({typeEvidence:e})",ctx)!=='recall')throw new Error('recallWeak concept did not prefer a recall variant');
    ok('Recognition-correct + Recall-failed produces recallWeak and prioritises Reverse Recall');
    const immediate=vm.runInContext("phrasalConceptMasteredV1_(learningProfileV2_([{ts:new Date('2026-08-25T00:00:00Z'),correct:true,selected:'A'},{ts:new Date('2026-08-25T01:00:00Z'),correct:true,selected:'A'},{ts:new Date('2026-08-25T02:00:00Z'),correct:true,selected:'A'}]))",ctx);
    if(immediate)throw new Error('immediate Yaad tha ratings created spaced mastery');
    ok('Immediate Yaad tha ratings cannot create spaced-retention mastery');
  }catch(e){fail('Type-aware intelligence regression — '+e.message)}
}
intelligenceRegression();

class CL{constructor(){this.s=new Set()}add(...x){x.forEach(v=>this.s.add(v))}remove(...x){x.forEach(v=>this.s.delete(v))}toggle(x,f){const on=f===undefined?!this.s.has(x):!!f;on?this.s.add(x):this.s.delete(x);return on}contains(x){return this.s.has(x)}}
class Node{
  constructor(doc,id=''){this.doc=doc;this.id=id;this.className='';this.classList=new CL();this.style={};this.dataset={};this.disabled=false;this.textContent='';this.children=[];this.onclick=null;this._html='';this.recallButtons=[];this.optionText={textContent:''};if(id)doc.nodes[id]=this}
  set innerHTML(v){this._html=String(v||'');this.children=[];this.recallButtons=[];if(this._html.includes('recall-rate'))for(const k of ['A','B','C']){const b=new Node(this.doc);b.dataset.key=k;b.classList=new CL();this.recallButtons.push(b)}}
  get innerHTML(){return this._html}
  appendChild(n){this.children.push(n);return n}
  querySelector(sel){if(sel==='.option-text')return this.optionText;return null}
  querySelectorAll(sel){if(sel==='.recall-rate')return this.recallButtons;return[]}
}
function quizEnv(){
  const doc={nodes:{},getElementById(id){return this.nodes[id]||null},createElement(){return new Node(this)},querySelectorAll(sel){return sel==='.app-page'?[]:[]}};doc.head=new Node(doc,'head');doc.body=new Node(doc,'body');
  ['quizView','bottomNav','quizMode','quizCounter','quizBar','qCategory','qId','qText','qWord','prevBtn','nextBtn','markBtn','masteredBtn','vocabBtn','optionList','feedback','explanation'].forEach(id=>new Node(doc,id));
  const store=new Map(),calls=[];const localStorage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v)),removeItem:k=>store.delete(k)};
  const EPApp={call(fn,payload){calls.push({fn,payload:Object.assign({},payload)});return Promise.resolve({ok:true,correctKey:'A'})},toast(){},showTab(){},refreshResumeCard(){}};
  const sandbox={document:doc,window:null,localStorage,EPApp,console,Date,Math,JSON,Object,Array,String,Number,Boolean,RegExp,Set,Map,Promise,Error,confirm:()=>true,setTimeout:fn=>{fn();return 1}};sandbox.window=sandbox;sandbox.window.scrollTo=()=>{};vm.createContext(sandbox);vm.runInContext(strip(quiz),sandbox,{filename:'QuizJS.html'});const quizApi=vm.runInContext('EPQuiz',sandbox);return {sandbox,doc,calls,quiz:quizApi};
}
async function recallUiRegression(){
  try{
    const e=quizEnv(),q={id:'PV0242',topic:'Phrasal Verb',word:'Look After',question:'To take care of someone or something = ?',questionType:'Reverse Recall Card',correctKey:'A',options:[{key:'A',text:'Yaad tha'},{key:'B',text:'Confused'},{key:'C',text:'Bhool gaya'},{key:'D',text:''}],explanation:'Take care of or tend.',example:'She looks after her grandmother.'};
    e.quiz.start([q],{mode:'phrasalDaily',batchId:'phrasal-today-2026-08-25'});
    let list=e.doc.nodes.optionList;
    if(!list.innerHTML.includes('View Answer')||!list.innerHTML.includes('Think of the Phrasal Verb first.'))throw new Error('initial recall state is missing retrieval prompt/reveal control');
    if(list.innerHTML.includes('Look After')||list.innerHTML.includes('Yaad tha')||list.innerHTML.includes('Confused')||list.innerHTML.includes('Bhool gaya'))throw new Error('answer/self-rating leaked before View Answer');
    if(!e.doc.nodes.qWord.classList.contains('hidden'))throw new Error('Word field leaked the answer before reveal');
    ok('Reverse Recall initially shows prompt only with no answer or semantic options');
    e.quiz.revealRecall();list=e.doc.nodes.optionList;
    if(!list.innerHTML.includes('Look After')||!list.innerHTML.includes('Take care of or tend.')||!list.innerHTML.includes('She looks after her grandmother.'))throw new Error('reveal is missing target/meaning/example');
    if(list.recallButtons.length!==3||list.recallButtons.map(x=>x.dataset.key).join('')!=='ABC')throw new Error('self-rating controls are not exactly A/B/C');
    ok('View Answer reveals word, compact learning text, example, and exactly three A/B/C ratings');
    list.recallButtons[1].onclick();await Promise.resolve();await Promise.resolve();
    const b=e.calls.find(x=>x.fn==='submitAnswer');if(!b||b.payload.selectedKey!=='B')throw new Error('Confused did not save as B through submitAnswer');
    ok('Confused saves selected answer B through the existing answer call');
    for(const [key,id] of [['A','PV0243'],['C','PV0244']]){const x=quizEnv(),qq=Object.assign({},q,{id,word:key==='A'?'Break With':'Make Up'});x.quiz.start([qq],{mode:'phrasalDaily'});x.quiz.revealRecall();x.doc.nodes.optionList.recallButtons.find(b=>b.dataset.key===key).onclick();await Promise.resolve();const c=x.calls.find(v=>v.fn==='submitAnswer');if(!c||c.payload.selectedKey!==key)throw new Error(`${key} rating did not keep its selected answer`)}
    ok('Yaad tha saves A and Bhool gaya saves C distinctly');
    const n=quizEnv(),mcq={id:'PV0001',topic:'Phrasal Verb',word:'Bear Away',question:'What does Bear Away mean?',questionType:'Meaning',correctKey:'B',options:[{key:'A',text:'A1'},{key:'B',text:'B1'},{key:'C',text:'C1'},{key:'D',text:'D1'}]};n.quiz.start([mcq],{mode:'phrasalRevision'});if(n.doc.nodes.optionList.children.length!==4)throw new Error('normal MCQ did not render four existing options');if(n.doc.nodes.optionList.innerHTML.includes('View Answer'))throw new Error('normal MCQ entered recall rendering');ok('Normal MCQ rendering remains the existing four-option path');
  }catch(e){fail('Reverse Recall EPQuiz behavioral regression — '+e.message)}
}

recallUiRegression().then(()=>{if(failed){console.error('\nPhrasal active-recall validation failed.');process.exit(1)}console.log('\n✅ Phrasal Today’s 20 + Reverse Recall behavioral contracts passed.')}).catch(e=>{console.error(e);process.exit(1)});
