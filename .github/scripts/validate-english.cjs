const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(process.cwd(), 'apps-script');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const fail = msg => { console.error(`\n❌ ${msg}`); process.exitCode = 1; };
const ok = msg => console.log(`✅ ${msg}`);
const requireText = (text, needle, label) => text.includes(needle) ? ok(label) : fail(`${label} — missing: ${needle}`);
const requireRegex = (text, rx, label) => rx.test(text) ? ok(label) : fail(`${label} — pattern not found: ${rx}`);

const requiredFiles = ['Code.gs','Demand.gs','NewPractice.gs','Index.html','Styles.html','AppJS.html','QuizJS.html','appsscript.json'];
for (const file of requiredFiles) {
  if (!fs.existsSync(path.join(root, file))) fail(`Required Apps Script file missing: ${file}`);
  else ok(`File present: ${file}`);
}

if (process.exitCode) process.exit(process.exitCode);

const code = read('Code.gs');
const demand = read('Demand.gs');
const newPractice = read('NewPractice.gs');
const index = read('Index.html');
const app = read('AppJS.html');
const quiz = read('QuizJS.html');
const manifestRaw = read('appsscript.json');

// JavaScript syntax validation. HTML modules are script wrappers, so strip the wrapper only.
for (const file of ['Code.gs','Demand.gs','NewPractice.gs']) {
  try { new vm.Script(read(file), { filename: file }); ok(`Server JavaScript syntax: ${file}`); }
  catch (e) { fail(`Server JavaScript syntax failed in ${file}: ${e.message}`); }
}
for (const file of ['AppJS.html','QuizJS.html']) {
  const js = read(file).replace(/^\s*<script[^>]*>/i, '').replace(/<\/script>\s*$/i, '');
  try { new vm.Script(js, { filename: file }); ok(`Frontend JavaScript syntax: ${file}`); }
  catch (e) { fail(`Frontend JavaScript syntax failed in ${file}: ${e.message}`); }
}

// Manifest regression protection.
let manifest;
try { manifest = JSON.parse(manifestRaw); ok('appsscript.json is valid JSON'); }
catch (e) { fail(`appsscript.json JSON parse failed: ${e.message}`); manifest = {}; }
if (manifest.runtimeVersion === 'V8') ok('Apps Script V8 runtime preserved'); else fail('appsscript.json must use V8 runtime');
if (manifest.webapp?.access === 'ANYONE') ok('Web app access preserved as ANYONE'); else fail('appsscript.json webapp.access must be ANYONE');
if (manifest.webapp?.executeAs === 'USER_DEPLOYING') ok('Web app executes as deploying user'); else fail('appsscript.json webapp.executeAs must be USER_DEPLOYING');

// Existing live database connection: fail before deploy if accidentally removed/changed.
requireText(code, "spreadsheetId: '1IgUGQZu6sp1STBCX6gyI5pHayLGVpmYYrkKGYdwkjak'", 'Live English spreadsheet connection preserved');
requireText(code, "daily: 'Daily_Quiz'", 'Daily_Quiz sheet contract preserved');
requireText(code, "performance: 'Performance'", 'Performance history sheet contract preserved');
requireText(code, "status: 'Question_Status'", 'Question status sheet contract preserved');
requireText(code, "hindu: 'Hindu_Words'", 'Hindu_Words sheet contract preserved');
requireText(code, "mastered: 'Mastered_Log'", 'Mastered_Log sheet contract preserved');
requireText(demand, "const DEMAND_SHEET = 'Demanded_Practice'", 'Demanded_Practice sheet contract preserved');

// Server application contracts.
for (const [fn, label] of [
  ['function doGet(', 'Web-app doGet entry point'],
  ['function getBootstrap(', 'Home/bootstrap API'],
  ['function getPracticeBatch(', 'Practice question loader'],
  ['function submitAnswer(', 'Answer submission API'],
  ['function setMarked(', 'Marked-question API'],
  ['function markMastered(', 'Mastered API'],
  ['function restoreMastered(', 'Mastered restore API'],
  ['function getSources(', 'Source/PDF API'],
  ['function getHinduToday(', 'Hindu Today API'],
  ['function getHinduQuiz(', 'Hindu quiz API']
]) requireText(code, fn, label);
requireText(code, 'markDaily_(id)', 'Daily completion is written during answer submission');
for (const [fn, label] of [
  ['function getDemandBatches(', 'Demanded batch history API'],
  ['function getDemandBatch(', 'Demanded batch loader'],
  ['function createDemandBatch(', 'Demanded batch creation'],
  ['function getHinduQuizSynced(', 'Cross-device Hindu resume API'],
  ['function submitHinduAnswer(', 'Cross-device Hindu progress save']
]) requireText(demand, fn, label);
for (const [fn, label] of [
  ['function getNewPracticeHub(', 'New Practice category hub API'],
  ['function getNewPracticeBatch(', 'New Practice batch loader'],
  ['function recentContentDate_(', 'Recent-content date detection'],
  ['NOT_SPECIFIED', 'New Practice uncategorized fallback']
]) requireText(newPractice, fn, label);

// Mobile and page-shell protection.
requireRegex(index, /<meta\s+name=["']viewport["'][^>]*width=device-width[^>]*initial-scale=1[^>]*viewport-fit=cover/i, 'Mobile viewport contract preserved');
for (const [needle, label] of [
  ["include('Styles')", 'Styles include'],
  ["include('QuizJS')", 'QuizJS include'],
  ["include('AppJS')", 'AppJS include'],
  ['id="homeView"', 'Home screen'],
  ['id="practiceView"', 'Practice screen'],
  ['id="revisionView"', 'Revision screen'],
  ['id="libraryView"', 'Library screen'],
  ['id="newView"', 'New Practice screen'],
  ['onclick="EPApp.openNewPractice()"', 'New Practice home entry'],
  ['id="dailyStartBtn"', 'Daily start control'],
  ['id="dailyResumeBtn"', 'Daily resume control'],
  ['id="quizView"', 'Quiz screen'],
  ['onclick="EPQuiz.previous()"', 'Previous control'],
  ['onclick="EPQuiz.next()"', 'Next control'],
  ['onclick="EPQuiz.pause()"', 'Pause control'],
  ['onclick="EPQuiz.toggleMark()"', 'Mark control'],
  ['onclick="EPQuiz.mastered()"', 'Mastered control'],
  ['id="explanation"', 'Explanation container'],
  ['id="themeBtn"', 'Dark-mode control']
]) requireText(index, needle, label);

// Frontend feature contracts.
for (const [needle, label] of [
  ["gas('getPracticeBatch','daily'", 'Daily 120 always refreshes from server'],
  ["gas('getHinduQuizSynced'", 'Hindu quiz always refreshes from server'],
  ["gas('getNewPracticeHub'", 'New Practice hub refreshes from server'],
  ["gas('getNewPracticeBatch'", 'New Practice category practice uses server'],
  ['function openNewPractice()', 'New Practice UI'],
  ['function startNewPractice(', 'New Practice start UI'],
  ['function openDemanded()', 'Demanded Practice UI'],
  ['function startDemandBatch(', 'Demanded batch start UI'],
  ['function openSources()', 'Source/PDF UI'],
  ['function openMastered()', 'Mastered Library UI'],
  ['function restoreMastered(', 'Mastered restore UI'],
  ['function toggleTheme()', 'Dark mode logic'],
  ['function refreshDashboard()', 'Dashboard refresh logic']
]) requireText(app, needle, label);

for (const [needle, label] of [
  ["const DAILY_KEY=", 'Separate Daily pause/resume storage'],
  ["HINDU_KEY=", 'Separate Hindu pause/resume storage'],
  ["OTHER_KEY=", 'Separate extra-practice pause/resume storage'],
  ["EPApp.call('submitAnswer'", 'Background answer save'],
  ["EPApp.call('submitHinduAnswer'", 'Background Hindu progress save'],
  ['function renderExplanation(', 'Explanation rendering'],
  ['function previous()', 'Previous question logic'],
  ['function next()', 'Next question logic'],
  ['function pause()', 'Pause logic'],
  ['function mastered()', 'Mastered logic'],
  ["function resumeDaily(){EPApp.startDirect('daily')}", 'Cross-device Daily resume uses server state']
]) requireText(quiz, needle, label);

if (process.exitCode) {
  console.error('\nValidation failed. Deployment must not proceed.');
  process.exit(process.exitCode);
}
console.log('\n✅ English application contract validation passed.');
