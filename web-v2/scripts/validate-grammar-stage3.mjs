import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const cwd=process.cwd();
const repoRoot=fs.existsSync(path.join(cwd,'web-v2','app','english','page.tsx'))?cwd:path.resolve(cwd,'..');
const at=(p)=>path.join(repoRoot,p);
const read=(p)=>fs.readFileSync(at(p),'utf8');
const fail=(m)=>{throw new Error(`Grammar Stage 3 validation failed: ${m}`)};
const has=(text,needle,label=needle)=>{if(!text.includes(needle))fail(`missing ${label}`)};
const notHas=(text,needle,label=needle)=>{if(text.includes(needle))fail(`forbidden ${label}`)};

// Stage 2 is the valid superset boundary: it already includes the Stage 1 foundation plus the approved Grammar UI.
execFileSync(process.execPath,[at('web-v2/scripts/validate-grammar-stage2.mjs')],{cwd:repoRoot,stdio:'inherit'});

const deploymentPath='web-v2/data/grammar-deployment-manifest.json';
const curriculumPath='web-v2/data/grammar-curriculum-manifest.json';
const aliasesPath='web-v2/data/grammar-sprint-aliases.json';
const bridgePath='supabase/functions/english-content-task-bridge/index.ts';
const submittedPath='supabase/functions/english-content-task-bridge/submitted-grammar.ts';
const foundationPath='supabase/migrations/20260909012000_english_grammar_intelligence_foundation.sql';
const pipelinePath='supabase/migrations/20260909013000_english_grammar_daily_pipeline.sql';
for(const p of [deploymentPath,curriculumPath,aliasesPath,bridgePath,submittedPath,foundationPath,pipelinePath])if(!fs.existsSync(at(p)))fail(`required file missing: ${p}`);

const d=JSON.parse(read(deploymentPath));
const c=JSON.parse(read(curriculumPath));
const aliases=JSON.parse(read(aliasesPath));
const bridge=read(bridgePath),submitted=read(submittedPath),foundation=read(foundationPath),pipeline=read(pipelinePath);

if(d.dailyTarget!==20||c.dailyTarget!==20)fail('exact-20 invariant drift');
if(d.curriculum?.ruleCount!==260||c.ruleCount!==260)fail('260-rule curriculum invariant drift');
if(d.curriculum?.keySha256!==c.keySha256)fail('deployment/curriculum checksum mismatch');
if(d.curriculum?.version!==c.version)fail('deployment/curriculum version mismatch');
if(d.transport?.repository!=='Hustler031/telegram-media-bot')fail('unexpected transport repository');
if(d.transport?.baseBranch!=='automation/english-grammar-base')fail('unexpected Grammar transport base branch');
if(d.transport?.activeBranch!=='automation/english-grammar')fail('unexpected Grammar transport active branch');
if(!/^[a-f0-9]{40}$/.test(String(d.transport?.baseHead||'')))fail('Grammar transport base head missing');
for(const [key,want] of Object.entries({productionFeatureFlagInitiallyOff:true,schedulerInitiallyOff:true,noGoogleRuntimeDependency:true,readOnlyBrowsingWritesEvidence:false,canonicalReusePreservesQuestionId:true,partialDailyPublicationAllowed:false,mathsOrGkChangesAllowed:false})){
 if(d.guards?.[key]!==want)fail(`deployment guard drift: ${key}`);
}

const expectedMigrations=['20260909011500_english_grammar_preflight.sql','20260909012000_english_grammar_intelligence_foundation.sql','20260909012500_english_grammar_curriculum_sync.sql','20260909013000_english_grammar_daily_pipeline.sql','20260909013100_english_grammar_owner_resolution_fix.sql','20260909013200_english_grammar_selector_alias_fix.sql','20260909020000_english_grammar_world_read_model.sql'];
if(JSON.stringify(d.migrationOrder)!==JSON.stringify(expectedMigrations))fail('migration order is not frozen');
for(const name of expectedMigrations)if(!fs.existsSync(at(`supabase/migrations/${name}`)))fail(`deployment migration missing: ${name}`);

// Critical Stage 1 invariants are re-asserted directly because the Stage 1 validator intentionally forbids the now-approved Stage 2 UI.
has(foundation,"values('grammar_ai_v1',false",'feature flag starts false');
notHas(foundation,"values('grammar_ai_v1',true",'feature flag true in foundation');
has(foundation,'alter table english.grammar_rule_evidence enable row level security','Grammar evidence RLS');
has(foundation,'create or replace function english.recompute_grammar_rule_evidence','incremental evidence engine');
has(pipeline,"if p_count<>20 then raise exception 'Grammar Daily invariant requires exactly 20 slots'",'exact-20 selector');
has(pipeline,'missing ChatGPT self-critic provenance','final self-critic gate');
has(pipeline,'canonical reuse identity mismatch','canonical identity guard');
has(pipeline,"if v_existing<>0 then raise exception 'Partial Grammar daily membership exists",'partial publication refusal');

has(bridge,'GRAMMAR_REF = "refs/heads/automation/english-grammar"','Grammar OIDC ref');
has(bridge,'claimSubmittedGrammar','Grammar claim route');
has(bridge,'ingestSubmittedGrammar','Grammar ingest route');
has(bridge,'Legacy/server-side Grammar AI generation is disabled','server-side Grammar AI disabled');
has(submitted,'planner: "central_intelligence_plus_chatgpt"','bounded AI planner contract');
has(submitted,'selection.length !== 20','exact-20 transport guard');

if(!Array.isArray(aliases.aliases)||aliases.aliases.length<40)fail('curated Sprint alias seed unexpectedly small');
if(new Set(aliases.aliases.map(x=>x.aliasKey)).size!==aliases.aliases.length)fail('duplicate Sprint alias keys');
if(aliases.aliases.some(x=>Number(x.confidence)<0.9))fail('low-confidence Sprint alias slipped into seed');
if(fs.existsSync(at('web-v2/data/grammar-curriculum-snapshot.json')))fail('ad-hoc curriculum snapshot present; use checksum-gated Stage 3 sync instead');

let changed=[];
try{changed=execFileSync('git',['diff','--name-only','origin/main...HEAD'],{cwd:repoRoot,encoding:'utf8'}).split(/\r?\n/).filter(Boolean)}catch{}
for(const p of changed)if(/(^|\/)(maths?|gk)(\/|[-_.])/i.test(p))fail(`Stage 3 crossed Maths/GK boundary: ${p}`);

console.log(JSON.stringify({ok:true,stage:'grammar-intelligence-stage3-readiness',ruleCount:c.ruleCount,chapters:Object.keys(c.chapters||{}).length,dailyTarget:c.dailyTarget,sprintAliases:aliases.aliases.length,migrationCount:expectedMigrations.length,transportBase:d.transport.baseBranch,transportBaseHead:d.transport.baseHead,activationLast:d.activationOrder?.at(-1),changedFilesChecked:changed.length},null,2));
