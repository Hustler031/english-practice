import type { Metadata } from "next";
import "./globals.css";
import "./parity.css";

export const metadata: Metadata = {
  title: "Revision Platform",
  description: "Fast SSC revision platform",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
