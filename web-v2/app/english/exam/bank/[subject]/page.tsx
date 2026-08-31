import SprintBankSubjectPage from "@/components/sprint-bank-subject-page";

const subjectSlugs=["grammar","voice","narration","vocabulary","phrasal-verbs","idioms-ows","spelling-usage"];
export function generateStaticParams(){return subjectSlugs.map(subject=>({subject}));}

export default async function SprintBankSubjectRoute({params}:{params:Promise<{subject:string}>}){
  const {subject}=await params;
  return <SprintBankSubjectPage slug={subject}/>;
}
