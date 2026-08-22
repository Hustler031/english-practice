const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
for(const f of ['DailyAdaptive.gs','DailySelectionWhyUI.html','Index.html'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const daily=read('DailyAdaptive.gs'),ui=read('DailySelectionWhyUI.html'),index=read('Index.html');
try{new vm.Script(daily,{filename:'DailyAdaptive.gs'});ok('Daily adaptive syntax')}catch(e){fail(`DailyAdaptive syntax: ${e.message}`)}
try{new vm.Script(ui.replace(/<\/?script[^>]*>/gi,''),{filename:'DailySelectionWhyUI.html'});ok('Daily selection UI syntax')}catch(e){fail(`DailySelectionWhyUI syntax: ${e.message}`)}
[
  ["EP_DAILY_RATIONALE_V4",'Daily rationale has one compact persistent snapshot'],
  ["selectionReason",'Served Daily questions carry frozen primary selection reason'],
  ["selectionReasonCode",'Served Daily questions carry compact reason code'],
  ["selectionSignals",'Served Daily questions carry secondary qualifying signals'],
  ["writeDailyRationaleV4_(batchDate",'New Daily batches freeze rationale at construction time'],
  ["dailyRationaleSnapshotV4_",'Existing active Daily batch can be repaired once without schema change'],
  ["s.getRange(2,1,out.length,7).setValues(out)",'Daily_Quiz schema remains seven existing columns'],
  ["dailyInfoAdaptiveV3_(rows,batchDate,true,target)",'Carry-forward Daily batches retain adaptive mix metadata'],
  ["flaggedCount",'Hero mix has combined Starred/Difficult primary count'],
  ["learningCount",'Hero mix has Learning primary count'],
  ["mixedCount",'Hero mix has Mixed primary count'],
  ["selectionMixTotal",'Hero mix exposes an exact primary-reason total'],
  ["carryForwardRemaining",'Carry-forward status is separate from primary mix totals']
].forEach(([n,l])=>need(daily,n,l));
[
  ["dailyWhyBadge",'Daily quiz has a dedicated selection-reason badge'],
  ["margin-left:auto",'Selection-reason badge is anchored to the far right of the meta row'],
  ["Why was this selected?",'Reason badge opens a detailed explanation sheet'],
  ["ALSO QUALIFIED AS",'Detailed sheet exposes secondary selector signals'],
  ["primary reason is frozen",'UI explains frozen selection semantics'],
  ["Today's Mix",'Daily hero shows the requested Today mix'],
  ["Active Batch Mix",'Carry-forward batches are labelled accurately'],
  ["ep:daily-selection-mix:v1",'Daily hero mix is cached client-side'],
  ["ep-quiz-daily-v5",'Question reason is read from the existing persisted Daily session'],
  ["Persistent Weak",'Persistent Weak has a visible reason label'],
  ["controlled fresh exposure",'Controlled New reason is explained']
].forEach(([n,l])=>need(ui,n,l));
if(ui.includes('google.script.run')||ui.includes('EPApp.call('))fail('Daily selection UI must not add any server request');else ok('Daily selection UI adds no server request');
if(ui.includes('submitAnswer')||ui.includes('Attempt_ID')||ui.includes('nextBtn.disabled'))fail('Daily selection UI must not touch saving/Next architecture');else ok('Daily selection UI does not touch saving or Next');
if(daily.includes('DAILY_TARGET=')||daily.includes('target=120;'))fail('Selection transparency must not replace the existing configurable Daily target');else ok('Existing configurable Daily target remains authoritative');
need(index,"<?!= include('DailySelectionWhyUI'); ?>",'Index loads Daily selection transparency UI');
if(index.indexOf("include('DailySelectionWhyUI')")>index.indexOf("include('RefreshStartupGuardUI')"))ok('Daily selection UI loads after existing compatibility layers');else fail('Daily selection UI must load after existing compatibility layers');
if(process.exitCode){console.error('\nDaily selection transparency validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Daily selection transparency contracts passed.');
