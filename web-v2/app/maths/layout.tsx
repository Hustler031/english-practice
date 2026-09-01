import type { ReactNode } from "react";
import { MathsFrame } from "@/components/maths-frame";
import "./maths.css";
import "./quiz-old-layout.css";
import "./old-app-parity.css";
import "./maths-coach.css";
import "./maths-lively.css";
import "./maths-english-parity.css";

export default function MathsLayout({children}:{children:ReactNode}){return <MathsFrame>{children}</MathsFrame>;}
