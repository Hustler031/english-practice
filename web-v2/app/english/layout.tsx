import type { ReactNode } from "react";

import { EnglishFrame } from "@/components/english-frame";
import LearningRouteContext from "@/components/learning-route-context";

export default function EnglishLayout({ children }: Readonly<{ children: ReactNode }>) {
  return <EnglishFrame><LearningRouteContext/>{children}</EnglishFrame>;
}
