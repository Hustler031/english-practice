"use client";

import type { ReactNode } from "react";
import { StudyAuthGate } from "@/components/study-auth-gate";

export default function GkTemplate({ children }: { children: ReactNode }) {
  return <StudyAuthGate subject="GK">{children}</StudyAuthGate>;
}
