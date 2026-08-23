const fs=require('fs'),vm=require('vm');
function read(p){return fs.readFileSync(p,'utf8')}
function ok(v,m){if(!v)throw new Error(m)}
function jsFromHtml(s){return s.replace(/^\s*<script>\s*/,'').replace(/\s*<\/script>\s*$/,'')}
const save=read('apps-script/SaveReliabilityUI.html');
const sync=read('apps-script/ModuleSyncUI.html');
const hindu=read('apps-script/HinduFastPath.gs');
const compat=read('apps-script/LearningHinduCompat.gs');
const index=read('apps-script/Index.html');
new vm.Script(jsFromHtml(save));new vm.Script(jsFromHtml(sync));new vm.Script(hindu);new vm.Script(compat);
ok(save.includes("CustomEvent('ep:answer-durable'"),'durable answer event missing');
ok(save.includes('emitDurableAck(item,res)'),'durable ack not emitted after server confirmation');
ok(sync.includes("window.addEventListener('ep:answer-durable'"),'module sync listener missing');
ok(sync.includes("module==='mySavedRevision'"),'My Saved durable sync missing');
ok(sync.includes("module==='bankCoverage'"),'Bank Coverage durable sync missing');
ok(sync.includes("module==='hindu'"),'Hindu durable sync missing');
ok(sync.includes("EPMySavedCacheUX?.refresh"),'visible My Saved refresh missing');
ok(sync.includes("getHinduPracticeProgressCentral"),'Hindu progress refresh missing');
ok(sync.includes("EPApp.call('getHinduQuizFastV4')"),'Hindu fast quiz launch missing');
ok(sync.includes("const rawOpen=typeof EPApp.openHindu"),'Hindu open prefetch wrapper missing');
ok(sync.includes("EPQuiz.start(qs,{mode:'hindu'"),'Hindu fast launch does not preserve quiz mode');
ok(hindu.includes('function getHinduQuizFastV4()'),'fast Hindu endpoint missing');
ok(hindu.includes('hinduFastCentralMapV4_'),'batch Hindu-to-central mapping missing');
ok(hindu.includes('allQuestions_()'),'central questions are not loaded for batch mapping');
ok(!/centralDifficultMapV2_|starredRevisionDifficultMap_/.test(hindu),'Hindu fast path must not build Difficult state');
ok(hindu.includes('currentStarredMapV2_()'),'Hindu fast path must preserve central Star state');
ok(hindu.includes('cache.put(key,JSON.stringify(out),21600)'),'Hindu central-id map cache missing');
ok(compat.includes("typeof getHinduPracticeProgressFastV4_==='function'"),'central Hindu progress not routed through fast batch path');
ok(index.includes("include('ModuleSyncUI')"),'ModuleSyncUI include missing');
ok(index.indexOf("include('ModuleSyncUI')")>index.indexOf("include('DailyFinishBackgroundUI')"),'ModuleSyncUI must load after compatibility/finalization layers');
ok(!sync.includes('nextBtn.disabled'),'module sync must not block Next');
ok(!sync.includes('submitAnswerV3'),'module sync must not replace answer saving');
console.log('Module sync and Hindu fast-path contracts passed.');
