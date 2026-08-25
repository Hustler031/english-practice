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
const syntaxUi=n=>{try{new vm.Script(strip(read(n)),{filename:n});ok(`Frontend syntax: ${n}`)}catch(e){fail(`Frontend syntax failed ${n}: ${e.message}`)}};
const syntaxServer=n=>{try{new vm.Script(read(n),{filename:n});ok(`Server syntax: ${n}`)}catch(e){fail(`Server syntax failed ${n}: ${e.message}`)}};

const names=['FinalLearningUI.html','SavedUI.html','SmartMySavedUI.html','LearningCacheUX.html','NavigationPolishUI.html','MyWordsFinalUI.html','PhrasalMasteryUI.html','FastUI.html','AppJS.html','Index.html','MySavedRevision.gs','SmartMySaved.gs'];
names.forEach(n=>fs.existsSync(path.join(root,n))?ok(`File present: ${n}`):fail(`Missing file: ${n}`));
if(failed)process.exit(1);
['FinalLearningUI.html','SavedUI.html','SmartMySavedUI.html','LearningCacheUX.html','NavigationPolishUI.html','PhrasalMasteryUI.html'].forEach(syntaxUi);
['MySavedRevision.gs','SmartMySaved.gs'].forEach(syntaxServer);

const finalUi=read('FinalLearningUI.html'),savedUi=read('SavedUI.html'),smartUi=read('SmartMySavedUI.html'),cacheUi=read('LearningCacheUX.html'),navUi=read('NavigationPolishUI.html'),myWords=read('MyWordsFinalUI.html'),phrasalUi=read('PhrasalMasteryUI.html'),appUi=read('AppJS.html'),index=read('Index.html'),savedGs=read('MySavedRevision.gs'),smartGs=read('SmartMySaved.gs');

// Root ownership contract.
need(finalUi,"card.onclick=()=>EPApp.openSaved?.()",'FinalLearningUI delegates the Revision card to the authoritative route');
forbid(finalUi,'card.onclick=open;','FinalLearningUI cannot bind the legacy My Saved renderer directly');
forbid(finalUi,'EPApp.openSaved=open}','FinalLearningUI cannot steal EPApp.openSaved after DOMContentLoaded');
need(finalUi,'MySaved.injectRevision()','FinalLearningUI still runs its compatibility injection during the real DOMContentLoaded lifecycle');
need(finalUi,'(hub.groups||[])','Legacy compatibility renderer follows current groups contract');
forbid(finalUi,'(hub.days||[])','Obsolete hub.days renderer is removed');
forbid(cacheUi,'EPApp.openSaved=openSaved','LearningCacheUX cannot become a second primary My Saved owner');
forbid(cacheUi,'EPMySavedRevision.open=openSaved','LearningCacheUX cannot replace the Smart open function');
need(cacheUi,'window.EPSmartMySaved?.markDirty?.()','Durable central mutations dirty the Smart My Saved snapshot');
need(cacheUi,'window.EPPhrasalMastery?.markDirty?.()','Durable central mutations dirty the Phrasal snapshot');
need(smartUi,'EPApp.openSaved=open','SmartMySavedUI is the sole primary route installer');
need(smartUi,"CACHE_KEY='smartMySaved:snapshot:v2'",'Smart My Saved has one cache snapshot');
need(smartUi,"EPApp.call('getSmartMySavedSnapshotV2'",'Smart My Saved refresh uses one optimized snapshot RPC');
need(smartUi,'snapshot?.history?.groups||[]','Smart My Saved renders current groups hierarchy');
forbid(smartUi,'history?.days','Smart My Saved does not fall back to obsolete days contract');
need(smartUi,"view.dataset.smartMySavedShell!=='1'",'Smart My Saved ensure shell is idempotent');
need(smartUi,'Cached first · refreshes silently in background','Smart My Saved exposes cached-first silent refresh UX');
['Smart Revision','Weak','Difficult','Starred','Random','Practice All','Saved','Never Revised','Due','Mastered','Saved History','Manage Saved Words'].forEach(x=>need(smartUi,x,`Smart My Saved contains ${x}`));
need(smartUi,'EPSmartMySaved.startHistory','Saved History Practice/Weak belongs to Smart My Saved');
need(smartUi,'EPApp.showPracticeLoading?.(','My Saved server-dependent starts show existing loading overlay');
need(smartUi,'EPApp.hidePracticeLoading?.()','My Saved starts always have an explicit loader hide path');
need(myWords,'EPApp.openSaved()','Manage Saved Words return resolves through authoritative Smart route');
need(navUi,'EPMyWordsUX?.quickAdd?.()','Home Add Word remains wired to existing Add Word flow');
need(navUi,"function openSaved(origin){savedOrigin=origin||'revision';EPApp.openSaved?.()}",'Navigation polish delegates Home/Revision My Saved to authoritative route');
need(index,"include('FinalLearningUI')",'Index includes FinalLearningUI');
need(index,"include('SmartMySavedUI')",'Index includes SmartMySavedUI');
need(index,"include('LearningCacheUX')",'Index includes LearningCacheUX');
need(index,"include('NavigationPolishUI')",'Index includes NavigationPolishUI');

// One shared central read context powers Smart stats + complete history groups.
need(savedGs,'function mySavedRevisionContextV2_()','My Saved exposes a shared central-read context');
need(savedGs,'function mySavedRevisionItemsFromContextV2_(ctx)','My Saved items can reuse the shared context');
need(savedGs,'groups:mySavedRevisionHierarchyV2_','Backend hierarchy remains groups-based');
need(smartGs,'function smartMySavedSnapshotV2_()','Optimized Smart snapshot exists');
need(smartGs,'const ctx=mySavedRevisionContextV2_()','Smart snapshot performs one shared central-read context build');
need(smartGs,'history:{currentDay,stats:mySavedRevisionStatsV2_(u.base),categories:mySavedRevisionCategoriesV2_(u.base),groups:mySavedRevisionHierarchyV2_(u.base,currentDay)}','One Smart snapshot carries complete history hierarchy');

// Phrasal cache, date safety, prefetch, and loading UX.
need(phrasalUi,"HUB_KEY='phrasal:hub:v2'",'Phrasal hub is cached first');
need(phrasalUi,"TODAY_KEY='phrasal:today:v2'",'Phrasal Today’s 15 has its own date-safe cache');
need(phrasalUi,"cached&&cached.date===date&&cached.questions.length",'Today’s 15 cache is accepted only for the requested current date');
need(phrasalUi,'prefetchToday','Today’s 15 is prefetched');
need(phrasalUi,'Cached first · refreshes silently in background','Phrasal hub refresh is silent over valid cached content');
need(phrasalUi,"EPApp.showPracticeLoading?.('Starting Phrasal History…')",'Phrasal history start shows existing loading overlay');
need(phrasalUi,'EPApp.showPracticeLoading?.(mode===','All Smart/Weak/Difficult/Starred/Random/Practice All modes use the loading path');
need(phrasalUi,'EPApp.showPracticeLoading?.("Starting Today\'s 15 Phrasal Verbs…")','Today’s 15 gives immediate loading feedback when prefetch is unavailable or launch begins');
need(appUi,'showPracticeLoading','Existing application loading API remains the loading authority');
need(appUi,'hidePracticeLoading','Existing application loader hide API remains available');

class ClassList{
  constructor(owner){this.owner=owner;this.s=new Set(String(owner.className||'').split(/\s+/).filter(Boolean))}
  sync(){this.owner.className=[...this.s].join(' ')}
  add(...xs){xs.forEach(x=>this.s.add(x));this.sync()}
  remove(...xs){xs.forEach(x=>this.s.delete(x));this.sync()}
  contains(x){return this.s.has(x)}
  toggle(x,force){const on=force===undefined?!this.s.has(x):!!force;on?this.s.add(x):this.s.delete(x);this.sync();return on}
}
class FakeNode{
  constructor(doc,id='',className=''){this.doc=doc;this.id=id;this.className=className;this.classList=new ClassList(this);this.dataset={};this.style={};this.children=[];this.parentElement=null;this.textContent='';this.disabled=false;this.value='';this.onclick=null;this._html='';if(id)doc.nodes[id]=this}
  set innerHTML(v){this._html=String(v||'');const re=/id=["']([^"']+)["']/g;let m;while((m=re.exec(this._html))){if(!this.doc.nodes[m[1]])new FakeNode(this.doc,m[1])}}
  get innerHTML(){return this._html}
  appendChild(n){if(!n)return n;n.parentElement=this;this.children.push(n);if(n.id)this.doc.nodes[n.id]=n;return n}
  prepend(n){if(!n)return;n.parentElement=this;this.children.unshift(n);if(n.id)this.doc.nodes[n.id]=n}
  insertAdjacentElement(pos,n){if(!this.parentElement)return this.appendChild(n);const p=this.parentElement,i=p.children.indexOf(this);n.parentElement=p;if(pos==='afterend')p.children.splice(i+1,0,n);else if(pos==='beforebegin')p.children.splice(i,0,n);else this.appendChild(n);if(n.id)this.doc.nodes[n.id]=n;return n}
  remove(){if(this.parentElement){const i=this.parentElement.children.indexOf(this);if(i>=0)this.parentElement.children.splice(i,1)}if(this.id)delete this.doc.nodes[this.id]}
  querySelector(sel){if(sel==='.list')return this._list||null;if(sel==='button')return this.children.find(x=>x.tagName==='button')||null;if(sel===':scope > p.muted')return null;if(sel==='#topicGrid')return this.doc.nodes.topicGrid||null;return null}
  querySelectorAll(sel){if(sel==='.row.between')return this._rows||[];if(sel==='.quick-btn')return this._quicks||[];if(sel==='.list-card')return this._cards||[];if(sel==='h3')return[];return[]}
  closest(sel){if(sel==='[data-key]')return this.dataset.key?this:null;if(sel==='#bankCoverageQuick')return this.id==='bankCoverageQuick'?this:null;if(sel==='#revisionView .list-card')return this._revisionCard?this:null;if(sel==='button,[role="button"],a')return this;return null}
  focus(){}
}
function makeEnv(){
  const listeners={},timers=[],nodes={};let timerSeq=0;
  const doc={nodes,hidden:false,documentElement:{dataset:{theme:'light'}},addEventListener(ev,fn){(listeners[ev]||(listeners[ev]=[])).push(fn)},getElementById(id){return nodes[id]||null},createElement(tag){const n=new FakeNode(doc);n.tagName=tag;return n},querySelectorAll(sel){if(sel==='.app-page')return Object.values(nodes).filter(n=>n.classList?.contains('app-page'));if(sel==='#revisionView .list-card')return [revisionCard];if(sel==='#homeView .quick-btn')return [];if(sel==='button')return[];return[]},querySelector(){return null}};
  doc.head=new FakeNode(doc,'head');doc.body=new FakeNode(doc,'body');
  const main=new FakeNode(doc,'main');const bottom=new FakeNode(doc,'bottomNav');const revision=new FakeNode(doc,'revisionView','app-page content hidden');const revisionCard=new FakeNode(doc,'revisionMySaved','list-card');revisionCard.textContent='🔖 My Saved';revisionCard._revisionCard=true;revision._list=null;main.appendChild(revision);
  const store=new Map(),fast=new Map();
  const localStorage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v)),removeItem:k=>store.delete(k)};
  const EPFast={get:k=>fast.has(k)?fast.get(k):null,set:(k,v)=>{fast.set(k,v);return v},drop:k=>fast.delete(k)};
  const setTimeout=(fn,delay=0)=>{timers.push({fn,delay:Number(delay)||0,seq:timerSeq++});return timerSeq};
  const clearTimeout=()=>{};
  class MutationObserver{constructor(fn){this.fn=fn}observe(){}disconnect(){}}
  const calls=[];let loading=0,hiding=0,quizStarts=0,manage=0,quickAdd=0;
  const smartSnapshot={version:'V2',generatedAt:new Date().toISOString(),stats:{saved:24,eligible:20,neverRevised:7,due:3,weak:5,difficult:4,starred:6,mastered:4},available:{smart:20,weak:5,difficult:4,starred:6,random:20,all:20},history:{currentDay:24,stats:{saved:24,focus:20,weak:5,mastered:4},categories:[],groups:[{type:'day',label:'Day 24',fromDay:24,toDay:24,stats:{saved:3,focus:3,weak:1,mastered:0}},{type:'day',label:'Day 23',fromDay:23,toDay:23,stats:{saved:2,focus:2,weak:0,mastered:0}},{type:'block',label:'Days 11–20',fromDay:11,toDay:20,stats:{saved:10,focus:8,weak:2,mastered:2},days:[]},{type:'month',label:'Month 1 · Days 1–30',fromDay:1,toDay:30,stats:{saved:20,focus:16,weak:4,mastered:4},days:[]}]}};
  EPFast.set('smartMySaved:snapshot:v2',{data:smartSnapshot,ts:Date.now()});
  const EPApp={call(fn,...args){calls.push(fn);if(fn==='getSmartMySavedSnapshotV2')return Promise.resolve(smartSnapshot);if(fn==='getMySavedRevisionHub')return Promise.resolve(smartSnapshot.history);if(fn==='getPhrasalMasteryHubV1')return Promise.resolve({stats:{},available:{},today:{date:'2099-01-01',ready:false},history:[]});return Promise.resolve([])},showTab(){},toast(){},showPracticeLoading(){loading++},hidePracticeLoading(){hiding++},openHindu(){},openSources(){},openNewPractice(){}};
  const EPQuiz={start(){quizStarts++},resumeOther(){},resumeDaily(){},resumeHindu(){},next(){},hasSavedSessionFor(){return false},isSameRequested(){return false},replaceSavedFor(){},getOtherSummary(){return null}};
  const EPMyWordsUX={open(){manage++},quickAdd(){quickAdd++},back(){}};
  const sandbox={window:null,document:doc,console,Date,Math,Set,Map,Promise,JSON,Array,Object,String,Number,Boolean,RegExp,Error,EPApp,EPFast,EPQuiz,EPMyWordsUX,localStorage,setTimeout,clearTimeout,MutationObserver,confirm:()=>true,event:{stopPropagation(){}}};
  sandbox.window=sandbox;sandbox.scrollTo=()=>{};sandbox.window.scrollTo=()=>{};sandbox.window.EPFast=EPFast;sandbox.window.EPMyWordsUX=EPMyWordsUX;
  vm.createContext(sandbox);
  return {sandbox,listeners,timers,nodes,revisionCard,EPApp,EPFast,EPQuiz,smartSnapshot,calls,counts:()=>({loading,hiding,quizStarts,manage,quickAdd}),runTimers(maxDelay=Infinity){const batch=timers.splice(0).filter(t=>t.delay<=maxDelay).sort((a,b)=>a.delay-b.delay||a.seq-b.seq);batch.forEach(t=>t.fn())}};
}

async function productionOrderRegression(){
  try{
    const e=makeEnv();
    // Exact relative order of the relevant production scripts in Index.html.
    for(const n of ['SavedUI.html','FinalLearningUI.html','SmartMySavedUI.html','LearningCacheUX.html','NavigationPolishUI.html'])vm.runInContext(strip(read(n)),e.sandbox,{filename:n});
    if(!vm.runInContext('EPApp.openSaved===EPSmartMySaved.open',e.sandbox))throw new Error('Smart route is not authoritative before DOMContentLoaded');
    ok('Before DOMContentLoaded Smart My Saved owns EPApp.openSaved');
    for(const fn of e.listeners.DOMContentLoaded||[])fn();
    e.runTimers(600); // executes LearningCache wire, Navigation init, and FinalLearning follow-up timers.
    await Promise.resolve();
    if(!vm.runInContext('EPApp.openSaved===EPSmartMySaved.open',e.sandbox))throw new Error('A late DOMContentLoaded path stole EPApp.openSaved');
    ok('After all production-order DOMContentLoaded handlers Smart My Saved still owns EPApp.openSaved');
    if(!vm.runInContext('EPMySavedRevision.open===EPSmartMySaved.open',e.sandbox))throw new Error('legacy compatibility object replaced Smart open');
    ok('FinalLearningUI and LearningCacheUX cannot steal the Smart open function');

    const callsBefore=e.calls.length;e.EPApp.openSaved();const body=e.nodes.mySavedRevisionBody;if(!body)throw new Error('Smart body was not created');const html=body.innerHTML;
    for(const x of ['Smart Revision','Weak','Difficult','Starred','Random','Practice All','Saved','Never Revised','Due','Mastered','Saved History'])if(!html.includes(x))throw new Error(`Smart screen missing ${x}`);
    ok('Smart My Saved renders all six actions, four metrics, and Saved History');
    for(const x of ['Day 24','Day 23','Days 11–20','Month 1 · Days 1–30'])if(!html.includes(x))throw new Error(`groups hierarchy missing ${x}`);
    ok('Saved History renders day, 10-day block, and month groups from history.groups');
    if(html.includes('Preparing Smart My Saved'))throw new Error('valid cached content was replaced by Preparing');
    e.EPApp.openSaved();if(e.calls.length!==callsBefore)throw new Error('cached repeated open made an immediate server call');
    if(body.innerHTML.includes('Preparing Smart My Saved'))throw new Error('repeated cached open flashed Preparing');
    ok('Repeated Smart My Saved open is immediate from cache with no Preparing flash');

    e.sandbox.EPUIPolish.openSaved('home');if(!e.nodes.mySavedRevisionView||e.nodes.mySavedRevisionView.classList.contains('hidden'))throw new Error('Home polish route did not open Smart view');
    ok('Home My Saved route opens Smart My Saved');
    if(typeof e.revisionCard.onclick!=='function')throw new Error('Revision card has no delegated handler');e.revisionCard.onclick();if(!vm.runInContext('EPApp.openSaved===EPSmartMySaved.open',e.sandbox))throw new Error('Revision card did not preserve Smart route');
    ok('Revision Centre My Saved route opens Smart My Saved');
    e.sandbox.EPSmartMySaved.manage();if(e.counts().manage!==1)throw new Error('Manage Saved Words did not open My Words manager');
    ok('Manage Saved Words still opens existing My Words management');
    if(!navUi.includes('EPMyWordsUX?.quickAdd?.()'))throw new Error('Home Add Word was removed');
    ok('Add Word remains wired through the existing My Words quick-add flow');
  }catch(e){fail('Production-order My Saved ownership regression — '+e.message)}
}

async function phrasalCacheRegression(){
  try{
    const e=makeEnv(),d=(()=>{const x=new Date(),p=n=>String(n).padStart(2,'0');return `${x.getFullYear()}-${p(x.getMonth()+1)}-${p(x.getDate())}`})();
    const hub={version:'V1.1',stats:{totalConcepts:50,exposed:20,due:2,weak:3,mastered:4,eligible:46},available:{smart:46,weak:3,difficult:2,starred:5,random:46,all:46},today:{date:d,count:15,ready:true,sourceId:'PHRASAL_DAILY_TEST'},history:[{type:'day',label:'Today',fromDay:1,toDay:1,generated:15,practised:0,date:d}]};
    const today=[{id:'PV1'},{id:'PV2'}];e.EPFast.set('phrasal:hub:v2',{data:hub,ts:Date.now()});e.EPFast.set('phrasal:today:v2',{date:d,questions:today,ts:Date.now()});
    vm.runInContext(strip(phrasalUi),e.sandbox,{filename:'PhrasalMasteryUI.html'});
    const before=e.calls.length;e.sandbox.EPPhrasalMastery.open('home');e.sandbox.EPPhrasalMastery.open('home');if(e.calls.length!==before)throw new Error('repeated cached open performed immediate RPC');
    const body=e.nodes.phrasalMasteryBody;if(!body||body.innerHTML.includes('Preparing Phrasal Verb'))throw new Error('cached Phrasal open flashed Preparing');
    ok('Repeated Phrasal open renders cached hub immediately with silent refresh deferred');
    await e.sandbox.EPPhrasalMastery.startToday();const c=e.counts();if(c.loading!==1||c.hiding!==1)throw new Error(`Today loader imbalance ${c.loading}/${c.hiding}`);if(c.quizStarts!==1)throw new Error('Today cached batch did not launch quiz');if(e.calls.length!==before)throw new Error('date-valid prefetched Today batch still hit server');
    ok('Date-valid prefetched Today’s 15 launches with immediate loader response and no server wait');
  }catch(e){fail('Phrasal cached-first regression — '+e.message)}
}

(async()=>{await productionOrderRegression();await phrasalCacheRegression();if(failed){console.error('\nProduction-order My Saved/cache validation failed.');process.exit(1)}console.log('\n✅ Production-order My Saved ownership, groups history, cache, and Phrasal loading contracts passed.')})().catch(e=>{console.error(e);process.exit(1)});
