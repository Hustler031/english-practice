const fs=require('fs');
const path=require('path');
const root=process.cwd();
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const need=(t,s,m)=>{if(!t.includes(s))throw new Error(`${m}: missing ${s}`);console.log(`✅ ${m}`)};
const forbid=(t,s,m)=>{if(t.includes(s))throw new Error(`${m}: forbidden ${s}`);console.log(`✅ ${m}`)};

const rollover=read('web-v2/components/daily-rollover-sync.tsx');
const layout=read('web-v2/app/english/layout.tsx');

need(layout,'<DailyRolloverSync><LearningRouteContext/>{children}</DailyRolloverSync>','English routes are gated by Daily rollover sync');
need(rollover,'localProductionSafetyMode()','Local Safe mutation boundary is preserved');
need(rollover,'ep:v2:rpc-cache:english_resume_daily:{}','Previous-day Daily resume cache is explicitly evicted');
need(rollover,'supabaseBrowser().rpc("english_resume_daily")','Rollover owner is called live, bypassing cache-first rpc');
need(rollover,'supabaseBrowser().rpc("english_get_home_snapshot")','Home read model refreshes after rollover');
need(rollover,'setBootReady(true)','English children are released after the first live rollover attempt');
need(rollover,'window.addEventListener("focus", onWake)','Window focus retries rollover');
need(rollover,'document.addEventListener("visibilitychange", onWake)','Visibility wake retries rollover');
need(rollover,'OPEN_APP_HEARTBEAT_MS = 5 * 60_000','Open app has bounded rollover heartbeat');
need(rollover,'batchDate !== previousBatchDate','Daily page refreshes only after a real batch-date change');
need(rollover,'window.location.pathname === "/english/daily"','Midnight refresh is scoped to Daily route');
forbid(rollover,'rpc("english_resume_daily")','Rollover component must not use the cache-first rpc helper');

console.log('\n✅ Daily rollover client regression contracts passed.');
