import type { Metadata, Viewport } from "next";
import PwaRegister from "@/components/pwa-register";
import "./globals.css";
import "./parity.css";
import "./phrasal-parity.css";
import "./starred-parity.css";
import "./remaining-parity.css";
import "./hindu-parity.css";
import "./mobile-parity-fixes.css";
import "./final-polish.css";
import "./quiz-safe-area-fix.css";
import "./final-batch.css";
import "./navigation-home-fixes.css";
import "./quiz-mobile-dock-meta-fix.css";
import "./quiz-context-polish.css";
import "./module-hierarchy-polish.css";
import "./predeploy-polish.css";
import "./quiz-answer-leak-fix.css";
import "./blue-explanation-header-trial.css";
import "./session-rotation-ui-fixes.css";
import "./mastery-sprint.css";
import "./exam-final-polish.css";
import "./sprint-report-history.css";
import "./sprint-subject-bank.css";
import "./route-context-compact-fix.css";
import "./exam-ui-followup.css";
import "./english-intelligence-reliability.css";
import "./targeted-intelligence-ui.css";
import "./learning-insights-final-ui.css";
import "./english-visual-harmony.css";

export const metadata: Metadata = {
  title: "English Mastery",
  description: "Fast SSC English practice and revision",
  manifest: "/manifest.webmanifest",
  icons: { icon: [{ url: "/icon-192.png", sizes: "192x192", type: "image/png" }, { url: "/icon-512.png", sizes: "512x512", type: "image/png" }], apple: [{ url: "/icon-192.png", sizes: "192x192", type: "image/png" }] },
  appleWebApp: { capable: true, statusBarStyle: "black-translucent", title: "English Mastery" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  interactiveWidget: "resizes-content",
  themeColor: "#0d1117",
};

const themeBoot = `try{const t=localStorage.getItem('english-theme');document.documentElement.dataset.theme=t==='light'?'light':'dark'}catch(e){document.documentElement.dataset.theme='dark'}`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en" suppressHydrationWarning><head><script dangerouslySetInnerHTML={{ __html: themeBoot }} /></head><body><PwaRegister/>{children}</body></html>;
}
