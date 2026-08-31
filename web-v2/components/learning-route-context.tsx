"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase";

type Overview={
 ok:boolean;
 fastTrack:{total:number;readyToVerify:number;waiting:number;mastered:number;remaining:number};
 starred:{active:number;movedFastTrack:number;movedTargeted:number;fastTrackMastered:number;fastTrackRemaining:number};
 saved:{total:number;fastTrack:number;fastTrackMastered:number;fastTrackRemaining:number;targeted:number;everTargeted:number;recoveredStable:number;stillLearning:number;unclassified:number};
 targeted?:{active:number;eligible7Day:number;recovered7To14Day:number;recoveryRate:number|null};
};

export default function LearningRouteContext(){
 const path=usePathname();const[data,setData]=useState<Overview|null>(null);const[error,setError]=useState("");
 const relevant=path==="/english/progress"||path==="/english/starred"||path==="/english/saved";
 useEffect(()=>{if(!relevant)return;let alive=true;supabaseBrowser().rpc("english_get_learning_route_overview").then(({data:out,error:e})=>{if(!alive)return;if(e)setError(e.message);else setData(out as Overview)});return()=>{alive=false}},[relevant,path]);
 if(!relevant)return null;
 if(error)return <div className="route-context-error" title={error}>Learning-route status will refresh when the backend is available.</div>;
 if(!data)return <div className="route-context route-context-loading"><span>Syncing learning routes…</span></div>;
 if(path==="/english/progress")return <section className="route-context route-progress-context"><Link href="/english/fast-track"><span><small>FAST TRACK MASTERY</small><b>Verified / Mastered {data.fastTrack.mastered}</b><em>Ready to Verify {data.fastTrack.readyToVerify} · Total Routed {data.fastTrack.total}</em></span><i>›</i></Link>{data.targeted&&<div className="route-recovery-kpi"><span>Targeted Recovery</span><b>{data.targeted.recoveryRate==null?"Building 7–14d evidence":`${data.targeted.recoveryRate}%`}</b></div>}</section>;
 if(path==="/english/starred")return <section className="route-context route-starred-context"><div className="route-context-title"><small>STARRED ROUTING</small><b>Active Starred {data.starred.active}</b></div><div className="route-context-links"><Link href="/english/route-view?route=fast_track&origin=From%20Starred"><span>Moved to Fast Track</span><b>{data.starred.movedFastTrack}</b><small>{data.starred.fastTrackMastered} mastered · {data.starred.fastTrackRemaining} remaining</small><i>›</i></Link><Link href="/english/route-view?route=targeted&origin=From%20Starred"><span>Moved to Targeted</span><b>{data.starred.movedTargeted}</b><small>Real weakness / failure evidence</small><i>›</i></Link></div></section>;
 return <section className="route-context route-saved-context"><div className="route-context-title"><small>MY SAVED LEARNING STATUS</small><b>{data.saved.total} permanent saved items</b></div><div className="route-context-links route-context-links-three"><Link href="/english/route-view?route=fast_track&origin=From%20My%20Saved"><span>Fast Track</span><b>{data.saved.fastTrack}</b><small>{data.saved.fastTrackMastered} mastered · {data.saved.fastTrackRemaining} remaining</small><i>›</i></Link><Link href="/english/route-view?route=targeted&origin=From%20My%20Saved"><span>Targeted</span><b>{data.saved.targeted}</b><small>{data.saved.recoveredStable} recovered/stable · {data.saved.stillLearning} still learning</small><i>›</i></Link><Link href="/english/route-view?route=unclassified&origin=From%20My%20Saved"><span>Unclassified</span><b>{data.saved.unclassified}</b><small>Insufficient route evidence</small><i>›</i></Link></div></section>;
}
