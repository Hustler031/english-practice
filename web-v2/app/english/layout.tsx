import type { ReactNode } from "react";

import { EnglishFrame } from "@/components/english-frame";

export default function EnglishLayout({ children }: Readonly<{ children: ReactNode }>) {
  return <EnglishFrame>{children}</EnglishFrame>;
}
