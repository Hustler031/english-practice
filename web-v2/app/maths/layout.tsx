import type { ReactNode } from "react";
import { MathsFrame } from "@/components/maths-frame";
import { MathsRuntimeWarmup } from "@/components/maths-runtime-warmup";
import "./maths.css";
import "./quiz-old-layout.css";
import "./old-app-parity.css";
import "./maths-coach.css";
import "./maths-lively.css";
import "./maths-english-parity.css";
import "./maths-final-polish.css";
import "./maths-mocks-nav-fix.css";
import "./maths-exam-prep.css";
import "./maths-exam-v2.css";

export default function MathsLayout({children}:{children:ReactNode}){return <MathsFrame><MathsRuntimeWarmup/>{children}</MathsFrame>;}
