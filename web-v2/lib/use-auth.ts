"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "./supabase";

export function useAuthGuard() {
  const router = useRouter();
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const supabase = supabaseBrowser();
    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return;
      if (!data.session) router.replace("/login");
      else setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session) router.replace("/login");
    });
    return () => { active = false; sub.subscription.unsubscribe(); };
  }, [router]);

  return ready;
}
