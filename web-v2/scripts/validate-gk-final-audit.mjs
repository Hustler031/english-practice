import fs from 'node:fs';
import path from 'node:path';
import ts from 'typescript';

const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const listSql=()=>fs.readdirSync(path.join(root,'../supabase/managed-migrations')).filter(x=>x.endsWith('.sql')).sort();
const sqlFiles=listSql();
const sql=sqlFiles.map(x=>read(`../supabase/managed-migrations/${x}`)).join('\n');
const correction=read('../supabase/managed-migrations/20260830074500_gk_v2_final_audit_corrections.sql');
const runtime=read('../supabase/managed-migrations/20260830073000_gk_v2_final_runtime_parity.sql');
const baseline=read('../supabase/recovery-baselines/gk_v2_reconstructed_pre25704_baseline.sql');
const ledger=read('../supabase/managed-migrations/GK_LEDGER.md');
const quiz=read('app/gk/quiz/page.tsx');
const entry=read('app/gk/page.tsx');
const legacyPath='app/gk/legacy-page.tsx';
const home=fs.existsSync(path.join(root,legacyPath))?read(legacyPath):entry;
const homeV2=fs.existsSync(path.join(root,'components/gk-home-v2.tsx'))?read('components/gk-home-v2.tsx'):'';
const layout=read('app/gk/layout.tsx');
const transport=read('lib/gk-rpc.ts');
const sessionSource=read('lib/gk-session.ts');
const options=read('lib/options.ts');
const supabase=read('lib/supabase.ts');

let failed=0;
const ok=(name,condition)=>condition?console.log(`✓ ${name}`):(console.error(`✗ ${name}`),failed++);

// Deterministic recovery is deliberately outside the live migration ledger path.
ok('reconstructed baseline is non-ledger recovery material',baseline.includes('NOT an original historical migration')&&baseline.includes('create table if not exists gk.questions')&&baseline.includes('create table if not exists gk.attempts'));
ok('baseline contains no user/question evidence rows',!/\binsert\s+into\s+gk\.(?:questions|attempts|exposures|question_state|sessions|user_notes)\b/i.test(baseline.replace(/create or replace function[\s\S]*$/i,'')));
ok('ledger documents reconstructed baseline truthfully',ledger.includes('reconstructed')||ledger.includes('baseline'));

const states=['New','Fragile','Learning','Weak','Persistent Weak','Strong','Proven Mastered'];
for(const state of states)ok(`learning state present: ${state}`,correction.includes(`'${state}'`));
ok('18-hour retention gate is exact',/>=\s*18\b/.test(correction));
ok('known same-session attempts cannot be spaced',correction.includes('o.session_id=o.prev_session_id')&&correction.includes('previous_session'));
ok('raw Attempts drive learning profiles',correction.includes('from gk.attempts a')&&correction.includes('gk.learning_profiles_v2'));
ok('raw Exposures drive exposure truth',correction.includes('from gk.exposures where user_id=p_user_id'));
ok('guessed remains unresolved until later confirming recall',correction.includes('last_confirming_at<=a.last_guess_at')&&correction.includes('m.spaced and m.is_correct and not coalesce(m.guessed,false)'));
for(const [state,days] of [['Persistent Weak',1],['Weak',1],['Fragile',2],['Learning',3],['Strong',7],['Proven Mastered',21]]){
  ok(`review cadence ${state}=${days}d`,new RegExp(`when '${state.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}' then ${days}\\b`).test(correction));
}
ok('Daily uses explicit ordered tiers',correction.indexOf("when e.st='Persistent Weak' then 7")<correction.indexOf("when e.st='Weak' then 6")&&correction.indexOf("when e.st='Weak' then 6")<correction.indexOf("when e.st='Fragile' then 5")&&correction.indexOf("when e.st='Fragile' then 5")<correction.indexOf('when e.due then 4')&&correction.indexOf('when e.due then 4')<correction.indexOf('when e.unconfirmed_guess then 3')&&correction.indexOf('when e.unconfirmed_guess then 3')<correction.indexOf('when e.difficult then 2')&&correction.indexOf('when e.difficult then 2')<correction.indexOf('when not e.exposed then 1'));
ok('Proven Mastered enters Daily only when due',correction.includes("when mode_name='daily' then b.due or (b.st<>'Proven Mastered'"));
ok('New selection remains exposure-authoritative',sql.includes("mode_name in ('new','unseen','new_v2','new_random') then not b.exposed"));
ok('Long Time No See remains oldest/never-seen rotation',sql.includes("mode_name='long_unseen'")&&sql.includes('last_seen_evidence,to_timestamp(0)'));

ok('draft six-argument submit overload is removed',correction.includes('drop function if exists public.gk_submit_answer(text,text,boolean,text,text,text)'));
ok('canonical submit is live-compatible seven-argument signature',correction.includes('p_response_ms integer default null')&&correction.includes('public.gk_submit_answer('));
ok('answer idempotency is session/question scoped',correction.includes("uid::text||'|'||btrim(p_session_id)||'|'||q.question_id")&&correction.includes('on conflict do nothing'));
ok('exposure idempotency is session/question scoped',runtime.includes("uid::text||'|'||btrim(p_session_id)||'|'||qid")&&runtime.includes('on conflict(exposure_key) do nothing'));
ok('Demand Sets gain explicit owner',runtime.includes('add column if not exists user_id uuid')&&correction.includes('gk_demand_sets_own'));
ok('private learning tables are direct-DML closed',correction.includes('revoke all on gk.attempts,gk.exposures,gk.question_state,gk.sessions,gk.session_questions')&&correction.includes('gk.user_notes,gk.flags,gk.demand_sets from anon,authenticated'));
ok('active canonical answer key constraint exists',correction.includes('gk_questions_active_correct_option_check')&&correction.includes("in ('A','B','C','D')"));
ok('POL2-RR036 guarded correction exists',runtime.includes("question_id='POL2-RR036'")&&runtime.includes("correct_option='C'"));
ok('POL2-RR053 guarded correction exists',runtime.includes("question_id='POL2-RR053'")&&runtime.includes("correct_option='D'"));

const frontendFiles=[quiz,home,homeV2];
const consumed=new Set();
for(const source of frontendFiles){for(const m of source.matchAll(/gkRpc(?:<[^>]+>)?\(\s*["'](gk_[a-z0-9_]+)["']/g))consumed.add(m[1]);}
for(const name of [...consumed].sort())ok(`frontend RPC has SQL definition: ${name}`,new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`,'i').test(sql));
const mutating=[...consumed].filter(x=>!x.startsWith('gk_get_'));
const mutationPrefix=/^gk_(?:submit_|record_|mark_|set_|save_|start_|create_|finish_|complete_)/;
for(const name of mutating)ok(`Local Safe catches mutation: ${name}`,mutationPrefix.test(name));
ok('transport mutation regex matches audited prefixes',transport.includes('const MUTATION=/^gk_(?:submit_|record_|mark_|set_|save_|start_|create_|finish_|complete_)/'));

// Execute pure resume helpers from the actual TypeScript module, not a duplicate model.
const transpiled=ts.transpileModule(sessionSource,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const module={exports:{}};
new Function('exports','module','require',transpiled)(module.exports,module,()=>{throw new Error('Unexpected runtime import in gk-session');});
const {normalizeGkQuizQuery,canAutoRestoreGkPaused}=module.exports;
const paused={sessionId:'S1',title:'Quiz',lane:'MIXED',mode:'weak',index:3,questions:[{id:'Q1',question:'Q',options:[]}],answers:{},query:'?mode=weak&count=20&lane=MIXED',savedAt:1};
ok('reload resume accepts exact route identity',canAutoRestoreGkPaused(paused,'?lane=MIXED&count=20&mode=weak&_refresh=99',true)===true);
ok('normal navigation does not auto-hijack stored quiz',canAutoRestoreGkPaused(paused,'?mode=weak&count=20&lane=MIXED',false)===false);
ok('different quiz route cannot auto-resume',canAutoRestoreGkPaused(paused,'?mode=random&count=20&lane=MIXED',true)===false);
ok('ephemeral refresh params are excluded from identity',normalizeGkQuizQuery('?mode=weak&_refresh=1')===normalizeGkQuizQuery('?mode=weak&_refresh=2'));
ok('quiz consumes reload intent before auto-restore',quiz.includes('consumeGkReloadIntent()')&&quiz.includes('canAutoRestoreGkPaused(stored,window.location.search,reloadIntent)'));
ok('hard refresh records explicit intent',layout.includes('markGkHardRefreshIntent()'));
ok('hard refresh clears read cache only',transport.includes('k.includes(":rpc-cache:")')&&!/export function clearGkPrivateCache\(\)[\s\S]{0,500}removeItem\(outboxKey/.test(transport));

const hasIndex=quiz.indexOf('submitLocks.current.has(q.id)');
const addIndex=quiz.indexOf('submitLocks.current.add(questionId)');
const setAnswerIndex=quiz.indexOf('setAnswers(a=>({...a,[questionId]');
ok('client answer lock is synchronous before optimistic state',hasIndex>=0&&addIndex>hasIndex&&setAnswerIndex>addIndex);
ok('server remains second idempotency layer',correction.includes('submission_key')&&correction.includes('deduped'));

ok('stable option order restore remains wired',quiz.includes('restoreDisplayOptions')&&quiz.includes('optionOrders:optionOrders(qs)'));
ok('unsafe option shuffle guards remain',options.includes('all of the above')&&options.includes('none of the above')&&options.includes('chronological'));
ok('browser Back still opens Pause',quiz.includes('popstate')&&quiz.includes('setPauseOpen(true)'));
ok('visible GK quiz Back still uses browser Back/Pause path',layout.includes('window.history.back()'));

const tabMatch=home.match(/const tabs:Array<\[Tab,string,string\]>=\[(.*?)\];/s);
const tabs=tabMatch?.[1]||'';
ok('exactly five GK legacy top-level tabs',((tabs.match(/\["(?:home|content|practice|demand|progress)"/g)||[]).length===5));
for(const label of ['Home','Content','Practice','On Demand','Progress'])ok(`legacy tab preserved: ${label}`,tabs.includes(`"${label}"`));
ok('Main/Rapid stay lanes, not top-level tabs',!tabs.includes('"Main"')&&!tabs.includes('"Rapid"'));
if(homeV2){
 ok('new GK entry uses split presentation without deleting legacy views',entry.includes('GkHomeV2')&&entry.includes('LegacyGkPage')&&entry.includes('tab==="home"'));
 ok('new GK Home reuses authoritative snapshot',homeV2.includes('gk_get_home_snapshot')&&homeV2.includes('subscribeGkFresh'));
 ok('new GK Home contains no learning mutation RPC',!/gkRpc(?:<[^>]+>)?\(\s*["']gk_(?:submit_|record_|mark_|set_|save_|start_|create_|finish_|complete_)/.test(homeV2));
}

function hasDirectSupabaseTableAccess(source){
  const sf=ts.createSourceFile('gk-browser-audit.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
  const factories=new Set(['supabaseBrowser']);
  const clients=new Set();
  for(const statement of sf.statements){
    if(!ts.isImportDeclaration(statement)||!ts.isStringLiteral(statement.moduleSpecifier)||!statement.moduleSpecifier.text.endsWith('/lib/supabase'))continue;
    const bindings=statement.importClause?.namedBindings;
    if(ts.isNamedImports(bindings))for(const item of bindings.elements){
      const imported=item.propertyName?.text||item.name.text;
      if(imported==='supabaseBrowser')factories.add(item.name.text);
    }
  }
  const isFactoryCall=node=>ts.isCallExpression(node)&&ts.isIdentifier(node.expression)&&factories.has(node.expression.text);
  let changed=true;
  while(changed){
    changed=false;
    const scan=node=>{
      if(ts.isVariableDeclaration(node)&&ts.isIdentifier(node.name)&&node.initializer){
        const init=node.initializer;
        const client=isFactoryCall(init)||(ts.isIdentifier(init)&&clients.has(init.text));
        if(client&&!clients.has(node.name.text)){clients.add(node.name.text);changed=true;}
      }
      ts.forEachChild(node,scan);
    };
    scan(sf);
  }
  const isClientExpr=node=>{
    if(ts.isIdentifier(node))return clients.has(node.text);
    if(isFactoryCall(node))return true;
    if(ts.isCallExpression(node))return isClientExpr(node.expression);
    if(ts.isPropertyAccessExpression(node))return isClientExpr(node.expression);
    if(ts.isParenthesizedExpression(node))return isClientExpr(node.expression);
    return false;
  };
  let direct=false;
  const visit=node=>{
    if(direct)return;
    if(ts.isCallExpression(node)&&ts.isPropertyAccessExpression(node.expression)&&node.expression.name.text==='from'&&isClientExpr(node.expression.expression)){direct=true;return;}
    ts.forEachChild(node,visit);
  };
  visit(sf);
  return direct;
}

ok('English shared transport remains present',supabase.includes('english_submit_answer')&&supabase.includes('prefetchEnglishCore'));
ok('GK transport has no browser service-role secret',![quiz,entry,home,homeV2,layout,transport,sessionSource,options].some(x=>/service[_-]?role/i.test(x)));
ok('GK browser code has no direct Supabase table access',![quiz,entry,home,homeV2,layout,transport,sessionSource].some(hasDirectSupabaseTableAccess));

if(failed){console.error(`\n${failed} final GK audit contract(s) failed.`);process.exit(1);}
console.log(`\nFinal GK audit contracts passed (${consumed.size} frontend RPCs checked).`);