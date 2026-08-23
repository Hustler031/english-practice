const EP_STARRED_INTELLIGENCE_COOLDOWN_MS_V2=24*60*60*1000;
const EP_STARRED_INTELLIGENCE_SNAPSHOT_MAX_AGE_MS_V2=5*60*1000;
const EP_STARRED_INTELLIGENCE_SIZES_V2=[10,20,30,50];

function starredIntelligenceCooldownMsV2_(){
  return typeof EP_RETENTION_GAP_MS!=='undefined'?Number(EP_RETENTION_GAP_MS||EP_STARRED_INTELLIGENCE_COOLDOWN_MS_V2):EP_STARRED_INTELLIGENCE_COOLDOWN_MS_V2;
}

function starredIntelligenceAnnotateCooldownV2_(rows,now){
  now=now instanceof Date?now:new Date();const gap=starredIntelligenceCooldownMsV2_();
  return (rows||[]).map(x=>{const last=x.lastStarred instanceof Date?x.lastStarred:null,recent=!!(last&&!isNaN(last)&&now.getTime()-last.getTime()>=0&&now.getTime()-last.getTime()<gap);return Object.assign({},x,{recentStarredCooldown:recent});});
}

function starredIntelligenceStatePriorityV2_(x){
  const s=String(x&&x.profile&&x.profile.state||'New');
  if(s==='Persistent Weak')return 7;if(s==='Weak')return 6;if(s==='Fragile')return 5;if(s==='Learning'||s==='New')return 4;if(s==='Strong')return 3;return 2;
}

function starredIntelligenceExplicitSortV2_(a,b){
  const sa=starredIntelligenceStatePriorityV2_(a),sb=starredIntelligenceStatePriorityV2_(b);if(sb!==sa)return sb-sa;
  if(Number(!!a.recentStarredCooldown)!==Number(!!b.recentStarredCooldown))return Number(!!a.recentStarredCooldown)-Number(!!b.recentStarredCooldown);
  if(Number(!!b.due)!==Number(!!a.due))return Number(!!b.due)-Number(!!a.due);
  if(Number(!!b.difficult)!==Number(!!a.difficult))return Number(!!b.difficult)-Number(!!a.difficult);
  return starredIntelligenceLearningSortV1_(a,b);
}

function starredIntelligenceSmartSelectV2_(rows,count){
  rows=(rows||[]).slice();const n=Math.min(Math.max(1,Number(count||20)),rows.length);if(!n)return [];
  const fresh=rows.filter(x=>!x.recentStarredCooldown),recent=rows.filter(x=>x.recentStarredCooldown),out=[];
  if(fresh.length)out.push(...starredIntelligenceSmartSelectV1_(fresh,Math.min(n,fresh.length)));
  const remaining=n-out.length;if(remaining>0&&recent.length)out.push(...starredIntelligenceSmartSelectV1_(recent,Math.min(remaining,recent.length)));
  return out;
}

function starredIntelligenceSelectV2_(rows,mode,count){
  const m=String(mode||'smart').toLowerCase(),n=Math.max(1,Math.min(50,Number(count||20)));if(m==='smart'||m==='recommended')return starredIntelligenceSmartSelectV2_(rows,n);let pool=(rows||[]).slice();
  if(m==='notrevised')pool=pool.filter(x=>x.neverRevised).sort(starredIntelligenceRotationSortV1_);
  else if(m==='due')pool=pool.filter(x=>x.due).sort(starredIntelligenceExplicitSortV2_);
  else if(m==='weak')pool=pool.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).sort(starredIntelligenceExplicitSortV2_);
  else if(m==='difficult')pool=pool.filter(x=>x.difficult).sort(starredIntelligenceExplicitSortV2_);
  else if(m==='longest')pool=pool.sort((a,b)=>{if(Number(!!a.recentStarredCooldown)!==Number(!!b.recentStarredCooldown))return Number(!!a.recentStarredCooldown)-Number(!!b.recentStarredCooldown);return starredIntelligenceRotationSortV1_(a,b);});
  else throw new Error('Unknown Starred Intelligence mode: '+mode);
  return pool.slice(0,n).map(x=>starredIntelligenceMarkSelectionV1_(x,m==='longest'||m==='notrevised'?'rotation':'learning'));
}

function starredIntelligenceSelectionItemV2_(x){
  return {id:String(x.id||''),day:Number(x.day||1),selectionLane:String(x.selectionLane||''),selectionReason:String(x.selectionReason||'Smart Revision'),selectionSignals:(x.selectionSignals||[]).slice(),baselineState:String(x.profile&&x.profile.state||'New'),difficult:!!x.difficult,neverRevised:!!x.neverRevised,lastStarred:x.lastStarred instanceof Date&&!isNaN(x.lastStarred)?x.lastStarred.toISOString():'',recentStarredCooldown:!!x.recentStarredCooldown};
}

function starredIntelligenceFullPoolV2_(rows,mode){
  rows=(rows||[]).slice();if(!rows.length)return [];const m=String(mode||'smart').toLowerCase();
  if(m==='smart'||m==='recommended')return starredIntelligenceSmartSelectV2_(rows,rows.length).map(starredIntelligenceSelectionItemV2_);
  let pool=rows;
  if(m==='notrevised')pool=pool.filter(x=>x.neverRevised).sort(starredIntelligenceRotationSortV1_).map(x=>starredIntelligenceMarkSelectionV1_(x,'rotation'));
  else if(m==='due')pool=pool.filter(x=>x.due).sort(starredIntelligenceExplicitSortV2_).map(x=>starredIntelligenceMarkSelectionV1_(x,'learning'));
  else if(m==='weak')pool=pool.filter(x=>['Persistent Weak','Weak','Fragile'].includes(String(x.profile&&x.profile.state||''))).sort(starredIntelligenceExplicitSortV2_).map(x=>starredIntelligenceMarkSelectionV1_(x,'learning'));
  else if(m==='difficult')pool=pool.filter(x=>x.difficult).sort(starredIntelligenceExplicitSortV2_).map(x=>starredIntelligenceMarkSelectionV1_(x,'learning'));
  else if(m==='longest')pool=pool.sort((a,b)=>{if(Number(!!a.recentStarredCooldown)!==Number(!!b.recentStarredCooldown))return Number(!!a.recentStarredCooldown)-Number(!!b.recentStarredCooldown);return starredIntelligenceRotationSortV1_(a,b);}).map(x=>starredIntelligenceMarkSelectionV1_(x,'rotation'));
  else throw new Error('Unknown Starred Intelligence mode: '+mode);
  return pool.map(starredIntelligenceSelectionItemV2_);
}

function starredIntelligenceSnapshotV2_(scope){
  const u=starredIntelligenceUniverseV1_(),sc=starredIntelligenceScopeV1_(scope),scoped=starredIntelligenceApplyScopeV1_(u.rows,sc),rows=starredIntelligenceAnnotateCooldownV2_(scoped,u.now),coverage=starredIntelligenceCoverageV1_(rows),health=starredIntelligenceHealthV1_(rows),rotation=starredIntelligenceRotationV1_(rows),smartBySize={};
  EP_STARRED_INTELLIGENCE_SIZES_V2.forEach(size=>{const selected=starredIntelligenceSmartSelectV2_(rows,size);smartBySize[size]={requested:size,count:selected.length,composition:starredIntelligenceCompositionV1_(selected),items:selected.map(starredIntelligenceSelectionItemV2_)};});
  const modePools={smart:starredIntelligenceFullPoolV2_(rows,'smart'),notRevised:starredIntelligenceFullPoolV2_(rows,'notRevised'),due:starredIntelligenceFullPoolV2_(rows,'due'),weak:starredIntelligenceFullPoolV2_(rows,'weak'),difficult:starredIntelligenceFullPoolV2_(rows,'difficult'),longest:starredIntelligenceFullPoolV2_(rows,'longest')};
  return {version:'V2',generatedAt:new Date().toISOString(),scope:sc,scopeOptions:starredIntelligenceScopeOptionsV1_(u.rows),coverage,health,rotation,focus:starredIntelligenceFocusV1_(health,rotation),recommendation:starredIntelligenceRecommendationV1_(health,coverage,rotation),cooldown:{hours:24,recent:rows.filter(x=>x.recentStarredCooldown).length},smartBySize,modePools,available:{smart:modePools.smart.length,notRevised:modePools.notRevised.length,due:modePools.due.length,weak:modePools.weak.length,difficult:modePools.difficult.length,longest:modePools.longest.length}};
}

function getStarredIntelligenceSnapshotV2(scope){return starredIntelligenceSnapshotV2_(scope);}

function starredIntelligenceServePreparedV2_(item,q,difficultNow){
  const out=serveQuestion_(q);out.marked=true;out.difficult=!!difficultNow;out.smartStarred=true;out.smartStarredReason=String(item.selectionReason||'Smart Revision');out.smartStarredSignals=Array.isArray(item.selectionSignals)?item.selectionSignals.slice():[];out.smartStarredLane=String(item.selectionLane||'');out.smartStarredBaselineState=String(item.baselineState||'New');out.smartStarredNeverRevised=!!item.neverRevised;out.smartStarredLastRevision=String(item.lastStarred||'');return out;
}

function getStarredIntelligencePreparedBatchV2(scope,mode,count,candidates,snapshotGeneratedAt){
  const generated=new Date(snapshotGeneratedAt||0);if(isNaN(generated)||Date.now()-generated.getTime()>EP_STARRED_INTELLIGENCE_SNAPSHOT_MAX_AGE_MS_V2)return {ok:false,needsRefresh:true,reason:'snapshot-stale',questions:[]};
  const sc=starredIntelligenceScopeV1_(scope),requested=Math.max(1,Math.min(50,Number(count||20))),items=Array.isArray(candidates)?candidates.slice(0,1000):[],target=Math.min(requested,items.length);if(!target)return {ok:true,needsRefresh:false,questions:[]};
  const qmap=Object.fromEntries(allQuestions_().map(q=>[String(q.id||'').trim(),q])),stars=currentStarredMapV2_(),mastered=currentMasteredMapV2_(),diff=starredIntelligenceDifficultMapV1_(),events=starredIntelligenceEventMapV1_(),m=String(mode||'smart').toLowerCase(),seen=new Set(),picked=[];
  for(const item of items){if(picked.length>=target)break;const id=String(item&&item.id||'').trim();if(!id||seen.has(id))continue;seen.add(id);const q=qmap[id];if(!q||!stars[id]||!isActive_(q)||mastered[id])continue;const eventDay=events[id]&&Number(events[id].day)>0?Number(events[id].day):Number(item.day||0);if(!sc.all&&(eventDay<sc.fromDay||eventDay>sc.toDay))continue;if(m==='difficult'&&!diff[id])continue;picked.push(starredIntelligenceServePreparedV2_(item,q,!!diff[id]));}
  if(picked.length<target)return {ok:false,needsRefresh:true,reason:'eligibility-changed',questions:picked};
  return {ok:true,needsRefresh:false,verifiedAt:new Date().toISOString(),questions:picked};
}
