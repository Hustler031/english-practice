"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase";

type Overview={
 ok:boolean;
 fastTrack:{total:number;readyToVerify:number;waiting:number;retentionWatch:number;retentionDue:number;mastered:number;remaining:number};
 starred:{active:number;movedFastTrack:number;movedTargeted:number;fastTrackMastered:number;fastTrackRemaining:number};
 saved:{total:number;fastTrack:number;fastTrackMastered:number;retentionWatch:number;fastTrackRemaining:number;targeted:number;everTargeted:number;recoveredStable:number;stillLearning:number;unclassified:number};
 targeted?:{active:number;eligible7Day:number;recovered7To14Day:number;recoveryRate:number|null};
};

let overviewCache:Overview|null=null;

export default function LearningRouteContext(){
 const path=usePathname();
 const[data,setData]=useState<Overview|null>(()=>overviewCache);
 const[error,setError]=useState("");
 const relevant=path==="/english/progress"||path==="/english/starred"||path==="/english/saved";

 useEffect(()=>{
  if(!relevant)return;
  let alive=true;
  supabaseBrowser().rpc("english_get_learning_route_overview").then(({data:out,error:e})=>{
   if(!alive)return;
   if(e){setError(e.message);return;}
   const next=out as Overview;
   overviewCache=next;
   setData(next);
   setError("");
  });
  return()=>{alive=false};
 },[relevant,path]);

 if(!relevant)return null;
 if(!data&&error)return null;
 if(!data)return <div className="route-context route-context-loading" aria-label="Loading learning route status"><i/><i/><i/></div>;

 if(path==="/english/progress")return <section className="route-context route-context-compact" aria-label="FAST TRACK MASTERY: Total Routed, Ready to Verify, Retention Watch, Proven, Targeted Recovery">
  <span className="route-context-label">Routes</span>
  <Link className="route-context-chip" href="/english/fast-track" title={`${data.fastTrack.total} total Fast Track items`}><b>{data.fastTrack.mastered}</b><small>Proven</small></Link>
  <Link className="route-context-chip" href="/english/fast-track" title={`${data.fastTrack.retentionDue} spaced retention checks are due now`}><b>{data.fastTrack.retentionWatch}</b><small>Retention</small></Link>
  <Link className="route-context-chip" href="/english/fast-track" title="Ready to verify now"><b>{data.fastTrack.readyToVerify}</b><small>Ready</small></Link>
  {data.targeted&&<span className="route-context-chip route-context-static" title="Targeted recovery based on 7–14 day evidence"><b>{data.targeted.recoveryRate==null?"—":`${data.targeted.recoveryRate}%`}</b><small>Recovery</small></span>}
 </section>;

 if(path==="/english/starred")return <section className="route-context route-context-compact" aria-label="Active Starred routing: Moved to Fast Track, Moved to Targeted">
  <span className="route-context-label">Routing</span>
  <span className="route-context-chip route-context-static" title="Current active Starred questions"><b>{data.starred.active}</b><small>Active</small></span>
  <Link className="route-context-chip" href="/english/route-view?route=fast_track&origin=From%20Starred" title={`${data.starred.movedFastTrack} Starred questions have ever moved to Fast Track · ${data.starred.fastTrackMastered} Proven · ${data.starred.fastTrackRemaining} still verifying/retaining`}><b>{data.starred.movedFastTrack}</b><small>→ Fast</small></Link>
  <Link className="route-context-chip" href="/english/route-view?route=targeted&origin=From%20Starred" title={`${data.starred.movedTargeted} Starred questions have ever moved to Targeted from real weakness / failure evidence`}><b>{data.starred.movedTargeted}</b><small>→ Targeted</small></Link>
 </section>;

 return <section className="route-context route-context-compact" aria-label="MY SAVED LEARNING STATUS: Fast Track, Targeted, Unclassified">
  <span className="route-context-label">Saved</span>
  <span className="route-context-chip route-context-static" title="Permanent saved items"><b>{data.saved.total}</b><small>Total</small></span>
  <Link className="route-context-chip" href="/english/route-view?route=fast_track&origin=From%20My%20Saved" title={`${data.saved.fastTrackMastered} Proven · ${data.saved.retentionWatch} Retention Watch · ${data.saved.fastTrackRemaining} not yet Proven`}><b>{data.saved.fastTrack}</b><small>Fast</small></Link>
  <Link className="route-context-chip" href="/english/route-view?route=targeted&origin=From%20My%20Saved" title={`${data.saved.recoveredStable} recovered/stable · ${data.saved.stillLearning} still learning`}><b>{data.saved.targeted}</b><small>Targeted</small></Link>
  <Link className="route-context-chip" href="/english/route-view?route=unclassified&origin=From%20My%20Saved" title="Insufficient route evidence"><b>{data.saved.unclassified}</b><small>Other</small></Link>
 </section>;
}
