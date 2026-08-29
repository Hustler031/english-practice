"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "./supabase";

let authReady = false;
let authCheck: Promise<boolean> | null = null;
const AUTH_BOOT_TIMEOUT_MS = 8000;

function ensureSession() {
  if (authReady) return Promise.resolve(true);
  if (authCheck) return authCheck;
  authCheck = (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const sessionRequest = supabaseBrowser().auth.getSession();
      const result = await Promise.race([
        sessionRequest,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("Authentication bootstrap timed out.")), AUTH_BOOT_TIMEOUT_MS);
        }),
      ]);
      authReady = !!result.data.session;
      return authReady;
    } catch {
      // A failed or unavailable session check must resolve to the safe,
      // unauthenticated path so protected pages cannot remain in limbo.
      authReady = false;
      return false;
    } finally {
      if (timer) clearTimeout(timer);
      authCheck = null;
    }
  })();
  return authCheck;
}

export function useAuthGuard() {
  const router = useRouter();
  const [ready, setReady] = useState(authReady);

  useEffect(() => {
    const supabase = supabaseBrowser();
    let active = true;
    if (!authReady) ensureSession().then(ok => {
      if (!active) return;
      if (!ok) router.replace("/login");
      else setReady(true);
    });
    else setReady(true);

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (!active) return;
      if ((event === "SIGNED_IN" || event === "TOKEN_REFRESHED" || event === "INITIAL_SESSION") && session) {
        authReady = true;
        setReady(true);
      }
      if (event === "SIGNED_OUT") {
        authReady = false;
        setReady(false);
        router.replace("/login");
      }
    });
    return () => { active = false; sub.subscription.unsubscribe(); };
  }, [router]);

  return ready;
}
