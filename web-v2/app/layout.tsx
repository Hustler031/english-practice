import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./parity.css";
import "./phrasal-parity.css";
import "./starred-parity.css";
import "./remaining-parity.css";
import "./hindu-parity.css";
import "./mobile-parity-fixes.css";
import "./final-polish.css";

export const metadata: Metadata = {
  title: "Revision Platform",
  description: "Fast SSC revision platform",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  interactiveWidget: "resizes-content",
};

const themeBoot = `try{const t=localStorage.getItem('english-theme');document.documentElement.dataset.theme=t==='light'?'light':'dark'}catch(e){document.documentElement.dataset.theme='dark'}`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head><script dangerouslySetInnerHTML={{ __html: themeBoot }} /></head>
      <body>{children}</body>
    </html>
  );
}
