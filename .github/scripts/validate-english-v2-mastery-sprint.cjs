const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const exists=p=>fs.existsSync(path.join(root,p));
let failed=0,passed=0;
function ok(cond,msg){if(cond){console.log('PASS',msg);passed++;}else{console.error('FAIL',msg);failed++;}}
function has(text,parts,msg){ok(parts.every(x=>text.includes(x)),msg);}
function balancedDollar(text,name){const tags=[...text.matchAll(/\$[A-Za-z_0-9]*\$/g)].map(x=>x[0]);const counts=new Map();for(const t of tags)counts.set(t,(counts.get(t)||0)+1);for(const [tag,n] of counts)ok(n%2===0,`${name} balanced ${tag} quotes`);}

const files={
 baseline:'supabase/managed-migrations/20260831202500_english_learning_route_bootstrap_baseline.sql',
 route:'supabase/managed-migrations/20260831203000_english_fast_track_targeted_routing.sql',
 routeFix:'supabase/managed-migrations/20260831203500_english_fast_track_targeted_routing_fix.sql',
 sprint:'supabase/managed-migrations/20260831204000_english_exam_sprint.sql',
 sprintFix:'supabase/managed-migrations/20260831204500_english_exam_sprint_fix.sql',
 reconcile:'supabase/managed-migrations/20260831205000_english_route_reconciliation_and_views.sql',
 intent:'supabase/managed-migrations/20260831205500_english_fast_track_failure_intent.sql',
 optionMap:'supabase/managed-migrations/20260831206000_english_sprint_promotion_option_keys.sql',
 savedRoute:'supabase/managed-migrations/20260831206500_english_saved_route_eligibility.sql',
 predeploy:'supabase/managed-migrations/20260831207000_english_predeploy_sprint_readiness_fix.sql',
 edge:'supabase/functions/english-ssc-sprint/index.ts',
 home:'web-v2/app/english/page.tsx',
 exam:'web-v2/app/english/exam/page.tsx',
 fast:'web-v2/app/english/fast-track/page.tsx',
 routeView:'web-v2/app/english/route-view/page.tsx',
 revision:'web-v2/app/english/revision/page.tsx',
 runner:'web-v2/components/quiz-runner.tsx',
 context:'web-v2/components/learning-route-context.tsx',
 layout:'web-v2/app/layout.tsx',
 css:'web-v2/app/mastery-sprint.css'
};
for(const [name,p] of Object.entries(files))ok(exists(p),`${name} file exists: ${p}`);
if(failed)process.exit(1);
const T=Object.fromEntries(Object.entries(files).map(([k,p])=>[k,read(p)]));

// One canonical question + routing sidecar. No duplicate question copy for Fast Track.
has(T.route,['create table if not exists english.learning_route_state','primary key (user_id,question_id)','question_id text not null references english.questions(question_id)','route text not null'], 'Fast Track/Targeted are a per-user sidecar over canonical Question_ID');
ok(!/create table[^;]*fast_track_questions/i.test(T.route), 'No duplicate Fast Track question table');
has(T.route,["route in ('unclassified','starred_unresolved','fast_track','targeted')","fast_track_status in ('ready','waiting','mastered')"], 'Route and Fast Track state spaces are explicit');

// Targeted evidence must override clean Fast Track and Daily/Revision must not deep-drill FT.
has(T.route,['create or replace function english.route_targeted_reason','Persistent Weak','Weak','Fragile','Difficult','New wrong evidence'], 'Targeted evidence derives from existing learning signals');
has(T.route,['create or replace function english.daily_reason','or fast_track then'], 'Daily suppresses Fast Track candidates');
has(T.route,['create or replace function public.english_get_revision_batch',"r.route='fast_track'"], 'Revision excludes Fast Track candidates from deep revision');
has(T.reconcile,['route_recovery_origin','Recovered Weak','Recovered Persistent Weak','Recovered Difficult','Recovered Targeted'], 'Recovered Targeted provenance is explicit');

// Fast Track session and wrong-answer decision semantics.
has(T.fast,['10,20,30,50,100','english_get_fast_track_batch_session','p_nonce','fastTrackMode'], 'Fast Track supports 10/20/30/50/100 fresh on-demand sessions');
has(T.runner,['Add to Targeted Mastery?','Add to Targeted','Keep in Fast Track','english_resolve_fast_track_failure'], 'Fast Track wrong answer has explicit learner routing decision');
has(T.intent,['fast_track_failure_decision_intent',"decision in ('targeted','keep')",'spaced confirmation required',"r.kept_failure_count>=1"], 'Outbox-safe decision intent and repeated-failure escalation exist');
has(T.reconcile,["fast_track_status='waiting'","now()+interval '1 day'"], 'Keep-in-Fast-Track requires spaced confirmation');

// Required origin inventory and drill-down.
for(const origin of ['Bank Coverage','From Starred','From My Saved','Manual Fast Track','Recovered Weak','Recovered Persistent Weak','Recovered Difficult','Recovered Targeted'])ok(T.fast.includes(origin),`Fast Track view exposes origin ${origin}`);
has(T.routeView,['Status','Category','View All Questions','Correct Answer','Explanation','Learning Route','Route history'], 'Route viewer groups first and supports detailed evidence drill-down');
has(T.routeView,['const load=useCallback(async(nextStatus:string|null,nextCategory:string|null)','},[config]);'], 'Route drill-down filter fetch is stable and not recreated by filter state');
has(T.reconcile,['english_get_route_view','routeHistory','fastTrackMasteredAt'], 'Route drill-down RPC returns history and mastery evidence');
const savedBack=T.routeView.indexOf('config.origin==="From My Saved"');
const starredBack=T.routeView.indexOf('config.origin==="From Starred"');
const fastBack=T.routeView.indexOf('config.route==="fast_track"');
ok(savedBack>=0&&starredBack>savedBack&&fastBack>starredBack, 'Route drill-down Back returns to Starred/My Saved before generic Fast Track fallback');

// Starred and Saved remain semantic overlays, not duplicate learning states.
has(T.context,['Active Starred','Moved to Fast Track','Moved to Targeted','From%20Starred'], 'Starred indicators show active and historical routing');
has(T.context,['MY SAVED LEARNING STATUS','Fast Track','Targeted','Unclassified','From%20My%20Saved'], 'My Saved indicators separate permanent membership from learning route');
has(T.route,['english.route_is_saved','english.saved_items'], 'Saved membership is read independently from route state');
has(T.savedRoute,['saved_revision_candidates_all','saved_revision_candidates','r.route=\'fast_track\'','version\',\'V5\''], 'My Saved preserves permanent membership while excluding Fast Track from deep revision eligibility');
has(T.savedRoute,["'saved',sa.saved","'eligible',se.eligible","'fastTrack',greatest(0,sa.saved-sa.mastered-se.eligible)"], 'My Saved hub reports all membership but route-aware practice eligibility');

// Progress KPI / recovery.
has(T.context,['FAST TRACK MASTERY','Ready to Verify','Total Routed','Targeted Recovery'], 'Progress context shows Fast Track and Targeted recovery KPI');
has(T.reconcile,["interval '7 days'","interval '14 days'",'recoveryRate'], 'Targeted recovery KPI uses 7–14 day evidence window');

// Historical bootstrap baseline and reconciliation.
has(T.baseline,['learning_route_bootstrap_baseline','attempts_count','daily_rows','star_events_count','saved_rows','question_state_rows','active_question_ids'], 'Pre-bootstrap immutable evidence baseline exists');
ok(files.baseline<files.route, 'Baseline migration sorts before route bootstrap migration');
has(T.route,['bootstrap_learning_routes','Historical clean evidence; verification required','already-mastered'], 'Historical clean items are candidates, not directly Fast Track Mastered');
has(T.reconcile,['english_get_learning_route_bootstrap_reconciliation','totalEvaluated','fastTrackCandidates','targetedCandidates','starredUnresolved','insufficientEvidence','alreadyMastered','excludedCases','savedClean','savedTargeted','savedUnclassified'], 'Bootstrap reconciliation reports all required buckets');
has(T.reconcile,['attemptsUnchanged','dailyHistoryUnchanged','starHistoryPreserved','savedRowsUnchanged','questionStateRowsUnchanged','activeQuestionIdsUnique'], 'Bootstrap reconciliation asserts preserved evidence and canonical uniqueness');

// Home: exactly one compact Exam Preparation row, immediately before Quick Start, no Fast Track card.
const examRows=(T.home.match(/EXAM PREPARATION/g)||[]).length;
ok(examRows===1, 'Home contains exactly one EXAM PREPARATION entry');
ok(T.home.indexOf('exam-home-row')<T.home.indexOf('Quick Start') && T.home.indexOf('exam-home-row')>T.home.indexOf('paused&&'), 'Exam Preparation row is immediately in the pre-Quick-Start Home region');
ok(!T.home.includes('/english/fast-track'), 'Home has no Fast Track card/link');

// Revision placement: agreed final location is Personal Revision, immediately after My Saved.
has(T.revision,['Personal Revision','My Saved Words','Fast Track Mastery','/english/fast-track'], 'Fast Track lives inside Personal Revision under Revision');
ok(!T.revision.includes('Fast Verification'), 'No separate Fast Verification section clutters Revision');
const savedRow=T.revision.indexOf('<b>🔖 My Saved Words</b>');
const fastRow=T.revision.indexOf('<b>⚡ Fast Track Mastery</b>');
const masteredRow=T.revision.indexOf('<b>✓ Mastered / Don’t Repeat</b>');
ok(savedRow>=0&&fastRow>savedRow&&masteredRow>fastRow, 'Fast Track is immediately between My Saved and Mastered in Personal Revision');

// Sprint exam contract and answer leak guard.
has(T.exam,['25 Questions · 15 Minutes · 50 Marks','−0.50 per wrong','no Reading Comprehension','results only after submission'], 'Exam page states exact SSC Sprint contract');
has(T.sprint,["when 'standard' then 25",'durationLimitSeconds',"score:=c*2-w*.5",'readingComprehension',"false"], 'Backend enforces 25Q / 15m metadata / +2 / -0.5 / no RC');
has(T.sprint,['case when (select status from s)=\'completed\' then','correctKey','else jsonb_build_object(\'position\',position,\'category\',category,\'questionType\',question_type,\'question\',question,\'options\',options)'], 'Sprint session hides correct answer/explanation before completion');
ok(!/correctKey.*sprint-card/.test(T.exam), 'Sprint question card does not render correct key mid-Sprint');

// Readiness must be based on full Standard Sprints only; practice modes retain their own max marks.
has(T.predeploy,['standard_hist',"s.mode='standard'",'fiveSprintAverage','goalStreak'], '45+ readiness is derived from SSC Standard Sprints only');
has(T.predeploy,['maxMarks','question_count*2','recentSprints'], 'Recent practice Sprints expose their true maximum marks');
has(T.exam,['SSC Standard only','x.maxMarks??modeMaxMarks','const maxMarks=result?.maxMarks??session.questionCount*2'], 'Exam UI keeps readiness standard-only and renders per-mode max marks');
ok(!T.exam.includes('<b>{x.score} / 50</b>'), 'Secondary practice history is not falsely displayed out of 50');

// Completed Sprint review must be auditable: learner answer + correct option text.
has(T.predeploy,['selectedKey','selected_key','english_get_sprint_session'], 'Completed Sprint session returns learner selected option without leaking it pre-completion');
has(T.exam,['Your answer','Correct answer','optionText(x.options,x.selectedKey)','optionText(x.options,x.correctKey)'], 'Sprint review shows learner answer and full correct option text');

// Sprint navigation safety and explicit abandonment.
has(T.predeploy,['english_abandon_sprint',"status='abandoned'"], 'Explicitly exited in-progress Sprint is marked abandoned');
has(T.exam,['englishSprintGuard','beforeunload','english_abandon_sprint','Leave this Sprint? Unsubmitted answers will not be scored.'], 'Sprint protects browser Back/refresh and cleans explicit exits');

// GPT quality + source truthfulness + ephemeral-by-default behavior.
has(T.edge,['Reading Comprehension','passage-dependent','exactly one defensible answer','ambiguous','qualityScore','minimum: 0.8'], 'GPT generator rejects RC/ambiguity and enforces quality floor');
has(T.edge,['GPT Generated','GPT Variant of Known Concept'], 'GPT generator uses truthful generated source labels');
ok(!T.edge.includes('sourceType: { type: "string", enum: ["SSC PYQ"'), 'GPT cannot self-label generated content as SSC PYQ');
has(T.sprint,['english.sprint_items','canonical_question_id','GPT SSC Sprint','if act=\'Targeted Mastery\''], 'Sprint items are separate and only genuine Targeted action promotes a GPT item canonically');
has(T.optionMap,['sprint_option_text','i.options,\'A\'','i.options,\'B\'','i.options,\'C\'','i.options,\'D\'','Sprint option mapping incomplete'], 'GPT Sprint promotion maps options by A-D keys rather than JSON array position');
has(T.edge,['Careless','Time Pressure','Misread','Targeted Mastery','No Route Change'], 'GPT analyst separates execution errors from learning gaps');

// Read freshness + Local Safe.
has(T.fast,['localProductionSafetyMode','disabled={!ft?.readyToVerify||localSafe}','english_get_fast_track_batch_session'], 'Fast Track honors Local Safe and requests a fresh session');
has(T.exam,['supabaseBrowser().rpc("english_get_exam_preparation")','supabaseBrowser().rpc("english_get_sprint_session"'], 'Exam summaries/results use authoritative fresh reads after writes');
has(T.intent,['queuedDecision','zz_english_fast_track_failure_decision'], 'Fast Track decision remains durable when answer submission is still in outbox');

// UI integration and CSS.
has(T.layout,['./mastery-sprint.css'], 'Mastery Sprint CSS loaded last in root layout');
has(T.css,['env(safe-area-inset-bottom)','@media(max-width:720px)','sprint-palette','route-context-links-three'], 'Mobile safe-area and responsive polish included');

// SQL delimiter sanity for new migrations.
for(const key of ['baseline','route','routeFix','sprint','sprintFix','reconcile','intent','optionMap','savedRoute','predeploy'])balancedDollar(T[key],key);

console.log(`\nEnglish V2 mastery-sprint contracts: ${passed} passed, ${failed} failed`);
if(failed)process.exit(1);
