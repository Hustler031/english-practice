import { SprintPicksSubjectPage } from "@/components/sprint-picks-library";

const subjects=["grammar","voice","narration","vocabulary","phrasal-verbs","idioms-ows","spelling-usage"] as const;
export function generateStaticParams(){return subjects.map(subject=>({subject}))}
export const dynamicParams=false;

export default async function SprintPicksSubjectRoute({params}:{params:Promise<{subject:string}>}){
  const {subject}=await params;
  return <SprintPicksSubjectPage slug={subject}/>;
}
