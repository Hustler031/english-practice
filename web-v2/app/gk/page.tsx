"use client";

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import GkHomeV2 from "@/components/gk-home-v2";
import LegacyGkPage from "./legacy-page";

function GkRoute(){
 const params=useSearchParams();
 const tab=params.get("tab")||"home";
 return tab==="home"?<GkHomeV2/>:<LegacyGkPage/>;
}

export default function GkPage(){
 return <Suspense fallback={<main className="gk-v2-route-loading"><div className="loading-copy">Opening GK…</div></main>}><GkRoute/></Suspense>;
}
