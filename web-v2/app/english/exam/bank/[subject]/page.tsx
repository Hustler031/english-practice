import SprintBankSubjectPage from "@/components/sprint-bank-subject-page";

const sprintBankSubjects=[
  "grammar",
  "voice",
  "narration",
  "vocabulary",
  "phrasal-verbs",
  "idioms-ows",
  "spelling-usage",
] as const;

export function generateStaticParams(){
  return sprintBankSubjects.map(subject=>({subject}));
}

export const dynamicParams=false;

export default async function SprintBankSubjectRoute({params}:{params:Promise<{subject:string}>}){
  const {subject}=await params;
  return <SprintBankSubjectPage slug={subject}/>;
}
