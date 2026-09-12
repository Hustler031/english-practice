"use client";

import type { ReactNode } from "react";
import { StudyAuthGate } from "@/components/study-auth-gate";

export default function MathsTemplate({ children }: { children: ReactNode }) {
  return <StudyAuthGate subject="Maths">{children}</StudyAuthGate>;
}
