"use client";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { supabaseBrowser as englishSupabaseBrowserBase } from "./supabase";

const STUDY_FALLBACK_URL = "https://wylkaljwsrixrvvmtnak.supabase.co";
const STUDY_FALLBACK_PUBLISHABLE_KEY = "sb_publishable_5fyGfa5lKeysfoLBAT3QuQ_87ulGIsw";
const STUDY_AUTH_STORAGE_KEY = "revision-platform:study-auth:v1";

let studyClient: SupabaseClient | null = null;

function browserReady() {
  return typeof window !== "undefined";
}

export function isStudyRoute(pathname?: string) {
  const path = pathname ?? (browserReady() ? window.location.pathname : "");
  return path === "/maths" || path.startsWith("/maths/") || path === "/gk" || path.startsWith("/gk/");
}

export function getStudySupabaseConfig() {
  return {
    url: process.env.NEXT_PUBLIC_STUDY_SUPABASE_URL?.trim() || STUDY_FALLBACK_URL,
    publishableKey: process.env.NEXT_PUBLIC_STUDY_SUPABASE_PUBLISHABLE_KEY?.trim() || STUDY_FALLBACK_PUBLISHABLE_KEY,
  };
}

export function studySupabaseBrowser(): SupabaseClient {
  if (studyClient) return studyClient;
  const { url, publishableKey } = getStudySupabaseConfig();
  if (!url || !publishableKey) throw new Error("Study Supabase environment variables are not configured.");
  studyClient = createClient(url, publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storage: browserReady() ? window.localStorage : undefined,
      storageKey: STUDY_AUTH_STORAGE_KEY,
    },
  });
  return studyClient;
}

export function englishSupabaseBrowser(): SupabaseClient {
  return englishSupabaseBrowserBase();
}

export function studyAwareSupabaseBrowser(): SupabaseClient {
  return isStudyRoute() ? studySupabaseBrowser() : englishSupabaseBrowserBase();
}
