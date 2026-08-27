Warning: truncated output (original token count: 2545)
Total output lines: 68

const fs=require('fs');
const path=require('path');
const vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script');
const read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`\n❌ ${m}`);process.exitCode=1};
const ok=m=>console.log(`✅ ${m}`);
const need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
const required=['Code.gs','DailyV2.gs','Demand.gs','NewPractice.gs','NewPracticeLive.gs','SourcePractice.gs','TopicPractice.gs','HinduVocab.gs','DashboardStats.gs','ProgressStats.gs','Saved.gs','StarredRevision.gs','MyWordTypes.gs','MyWordReconcile.gs','StarredRevisionDetail.gs','Index.html','Styles.html','AppJS.html','QuizJS.html','FastUI.html','TopicUI.html','NewPracticeUI.html','HinduUI.html','SourceUI.html','DemandUI.html','DashboardUI.html','SavedUI.html','MyWordsFinalUI.html','StarredRevisionUI.html','AddWordTypeUI.html','StarredViewDetailUI.html','appsscript.json'];
required.forEach(f=>fs.existsSync(path.join(root,f))?ok(`File present: ${f}`):fail(`Required Apps Script file missing: ${f}`));
if(process.exitCode)process.exit(process.exitCode);
const server=['Code.gs','DailyV2.gs','Demand.gs','NewPractice.gs','NewPracticeLive.gs','SourcePractice.gs','TopicPractice.gs','HinduVocab.gs','DashboardStats.gs','ProgressStats.gs','Saved.gs','StarredRevision.gs','MyWordTypes.gs','MyWordReconcile.gs','StarredRevisionDetail.gs'];
const front=['AppJS.html','QuizJS.html','FastUI.html','TopicUI.html','NewPracticeUI.html','HinduUI.html','SourceUI.html','DemandUI.html','DashboardUI.html','SavedUI.html','MyWordsFinalUI.html','StarredRevisionUI.html','AddWordTypeUI.html','StarredViewDetailUI.html'];
server.forEach(f=>{try{new vm.Script(read(f),{filename:f});ok(`Server JavaScript syntax: ${f}`)}catch(e){fail(`Server JavaScript syntax failed in ${f}: ${e.message}`)}});
front.forEach(f=>{try{const js=read(f).replace(/<\/?script[^>]*>/gi,'');new vm.Script(js,{filename:f});ok(`Frontend JavaScript syntax: ${f}`)}catch(e){fail(`Fron…1545 tokens truncated…nclick="EPSaved.addToPractice','openCapture'].forEach(x=>need(savedui,x,x));
['Pending enrichment','In Practice','quickAdd','saveQuick','saveEdit','Edit Saved Word'].forEach(x=>need(mwui,x,x));
['All Starred Revision','Day-wise Focus','Practice All','Practice New','Weak','Random','Mastered','getStarredRevisionHub','getStarredRevisionBatch','logStarredRevisionFromUi','__starredRevisionWrapped'].forEach(x=>need(srui,x,x));
['AUTO','Auto','V','SM','OWS','PV','I/P','captureMyWordTyped','Dashboard Quick Add','EPSaved.saveCapture',"let quickType='AUTO',captureType='AUTO'"].forEach(x=>need(awt,x,x));
if(/\['CU'|>CU<|\bCU\b/.test(awt))fail('Add Word UI must not expose CU');else ok('Add Word UI keeps CU internal');
try{
  const ctx={};vm.createContext(ctx);vm.runInContext(typed,ctx,{filename:'MyWordTypes.gs'});
  const cases=[
    [{Word:'Demur'},'AUTO','V'],
    [{Word:'Brush aside',Part_of_Speech:'Phrasal Verb'},'AUTO','PV'],
    [{Word:'feedback is uncountable noun'},'AUTO','CU'],
    [{Word:'belief vs believe usage'},'AUTO','CU'],
    [{Word:'feedback is uncountable noun'},'V','V'],
    [{Word:'Demur',Part_of_Speech:'Noun'},'','V']
  ];
  cases.forEach(([row,selected,wanted])=>{const got=ctx.resolveMyWordType_(row,selected);if(got===wanted)ok(`My Word type: ${row.Word} → ${wanted}`);else fail(`My Word type: ${row.Word} expected ${wanted}, got ${got}`)});
  const cu=ctx.myWordPracticeSpec_('CU');if(cu.topic==='Grammar / Usage'&&cu.questionType==='Concept / Usage')ok('CU practice routing');else fail('CU practice routing is incorrect');
}catch(e){fail(`Auto/CU classification validator failed: ${e.message}`)}
['tap any question to view answer','getStarredRevisionQuestionDetail','View only · does not affect attempts or accuracy','EPStarredRevision.view=view'].forEach(x=>need(srv,x,x));
if(process.exitCode){console.error('\nValidation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ English application contract validation passed.');
