import type { ReactNode } from "react";

import { EnglishFrame } from "@/components/english-frame";
import DailyRolloverSync from "@/components/daily-rollover-sync";
import LearningRouteContext from "@/components/learning-route-context";

export default function EnglishLayout({ children }: Readonly<{ children: ReactNode }>) {
  return <EnglishFrame><DailyRolloverSync/><LearningRouteContext/>{children}</EnglishFrame>;
}
