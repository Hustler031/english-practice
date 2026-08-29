import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./parity.css";
import "./phrasal-parity.css";
import "./starred-parity.css";
import "./remaining-parity.css";
import "./hindu-parity.css";
import "./mobile-parity-fixes.css";

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

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
