const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(process.cwd(),'apps-script'),read=n=>fs.readFileSync(path.join(root,n),'utf8');
const fail=m=>{console.error(`❌ ${m}`);process.exitCode=1},ok=m=>console.log(`✅ ${m}`),need=(t,n,l)=>t.includes(n)?ok(l):fail(`${l} — missing: ${n}`);
for(const f of ['NavigationPolishUI.html','Index.html','SaveReliabilityUI.html','StarredOriginStable.gs'])if(!fs.existsSync(path.join(root,f)))fail(`Missing ${f}`);
if(process.exitCode)process.exit(process.exitCode);
const nav=read('NavigationPolishUI.html'),index=read('Index.html');
try{new vm.Script(nav.replace(/<\/?script[^>]*>/gi,''),{filename:'NavigationPolishUI.html'});ok('Navigation polish syntax')}catch(e){fail(`NavigationPolishUI syntax: ${e.message}`)}
[
  ["homeHinduQuick",'Home keeps The Hindu quick access'],
  ["homeStarredQuick",'Home keeps Starred quick access'],
  ["homeBankQuick",'Home keeps Bank Coverage quick access'],
  ["homeSavedQuick",'Home keeps My Saved quick access'],
  ["homeAddWordQuick",'Home keeps Add Word quick access'],
  ["Random Practice|Recall Check|New Practice",'Redundant Home shortcuts are removed by the polish layer'],
  ["uiPracticeExplore",'Practice has Explore section'],
  ["uiPracticeFocused",'Practice has Focused Practice section'],
  ["uiRevisionNeeds",'Revision has Needs Attention section'],
  ["uiRevisionPersonal",'Revision has Personal Revision section'],
  ["libraryMyWordsCard",'Library has My Words content entry'],
  ["Demanded Practice|Recall Check|Mastered",'Library redundant actions are removed'],
  ["hub.stats.difficult",'Starred Difficult count uses existing cached hub stats'],
  ["data-ui-difficult-count",'Starred Difficult count is visibly injected'],
  ["ep:bankCoverage:hub:v3",'Home Bank status uses existing Bank cache'],
  ["ep:mySavedRevision:hub:v3",'Home My Saved status uses existing Saved cache'],
  [".nav button.active",'Active bottom tab gets a stronger visual state'],
  [".progressbar{background:var(--line)!important}",'Progress track follows theme variables'],
  ["html[data-theme=\"dark\"] .hero",'Daily hero has dark-mode polish']
].forEach(([n,l])=>need(nav,n,l));
if(nav.includes('EPApp.call(')||nav.includes('google.script.run'))fail('UI polish must not add server/data calls');else ok('UI polish adds no server/data calls');
if(nav.includes('submitAnswer')||nav.includes('Attempt_ID')||nav.includes('performanceFacts'))fail('UI polish must not touch answer/performance architecture');else ok('UI polish does not touch answer/performance architecture');
need(index,"<?!= include('NavigationPolishUI'); ?>",'Index loads navigation polish');
if(index.indexOf("include('NavigationPolishUI')")>index.indexOf("include('SaveReliabilityUI')"))ok('Navigation polish loads after save/cache compatibility layers');else fail('Navigation polish must load after SaveReliabilityUI');
if(process.exitCode){console.error('\nUI polish validation failed. Deployment must not proceed.');process.exit(process.exitCode)}
console.log('\n✅ UI navigation polish contracts passed.');
