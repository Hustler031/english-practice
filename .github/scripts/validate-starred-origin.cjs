const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
for(const f of ['StarredOriginStable.gs','SaveReliabilityUI.html','StarredRevision.gs']){if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);}
if(process.exitCode)process.exit(process.exitCode);
try{new vm.Script(read('StarredOriginStable.gs'),{filename:'StarredOriginStable.gs'});ok('Stable Starred origin server syntax')}catch(e){fail(`StarredOriginStable.gs syntax: ${e.message}`)}
try{new vm.Script(read('SaveReliabilityUI.html').replace(/<\/?script[^>]*>/gi,''),{filename:'SaveReliabilityUI.html'});ok('Reliability bridge syntax')}catch(e){fail(`SaveReliabilityUI.html syntax: ${e.message}`)}
const stable=read('StarredOriginStable.gs'),ui=read('SaveReliabilityUI.html');
[
  ['STARRED_ORIGIN_REPAIR_V4','one-time orphan migration key'],
  ["h.indexOf('last_marked')",'repair reads actual Last_Marked column'],
  ['starredPerformanceOriginV4_','historical marked-state origin reconstruction'],
  ['a[a.length-1].marked','historical evidence is trusted only for the active marked run'],
  ['starredPreviousActiveAnchorV4_','no-evidence orphans anchor to the previous visible day'],
  ['Math.max(1,currentDay-1)','repair cannot anchor old orphans to the new current day'],
  ['repairExistingStarredOrphansV4_','existing orphan repair'],
  ['healFutureStarredOrphansV4_','future missing-origin self-heal'],
  ['if(!ev||!ev.date||!ev.day)return','stable index refuses dynamic current-day fallback'],
  ['getStarredRevisionHubStableV4','stable Starred hub'],
  ['getStarredRevisionGroupStableV4','stable Starred group drilldown'],
  ['getStarredRevisionItemsStableV4','stable Starred browse list'],
  ['getStarredRevisionBatchStableV4','stable Starred practice batch'],
  ['getStarredOriginAuditV4','origin integrity audit endpoint']
].forEach(([n,l])=>need(stable,n,l));
if(/starredRevisionIndexStableV4_[\s\S]*?starredRevisionActiveDay_\(\)/.test(stable))fail('Stable index must never assign missing events to the current active day');else ok('Stable index has no current-day fallback');
[
  ["getStarredRevisionHub:'getStarredRevisionHubStableV4'",'UI hub routed to stable origin API'],
  ["getStarredRevisionGroup:'getStarredRevisionGroupStableV4'",'UI grouped days routed to stable origin API'],
  ["getStarredRevisionItems:'getStarredRevisionItemsStableV4'",'UI browse routed to stable origin API'],
  ["getStarredRevisionBatch:'getStarredRevisionBatchStableV4'",'UI practice routed to stable origin API'],
  ["STAR_ORIGIN_CACHE='ep:starred-origin-ui:v4'",'old Starred hub cache is version-busted once'],
  ["EPFast.drop('starred:hub')",'stale day distribution cache is cleared after upgrade']
].forEach(([n,l])=>need(ui,n,l));
if(process.exitCode){console.error('\nStarred origin-day validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ Starred origin-day contracts passed.');
