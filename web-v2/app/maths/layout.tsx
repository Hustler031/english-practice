import type { ReactNode } from "react";
import { MathsFrame } from "@/components/maths-frame";
import "./maths.css";

export default function MathsLayout({children}:{children:ReactNode}){return <MathsFrame>{children}</MathsFrame>;}
