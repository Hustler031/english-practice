"use client";
import { useEffect } from "react";

export default function PwaRegister(){
 useEffect(()=>{if(!("serviceWorker" in navigator))return;let active=true;const register=async()=>{try{const reg=await navigator.serviceWorker.register("/sw.js",{scope:"/"});if(active)void reg.update();}catch{}};void register();return()=>{active=false};},[]);
 return null;
}
