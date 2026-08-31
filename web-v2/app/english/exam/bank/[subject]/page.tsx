import SprintBankSubjectPage from "@/components/sprint-bank-subject-page";

export default async function SprintBankSubjectRoute({params}:{params:Promise<{subject:string}>}){
  const {subject}=await params;
  return <SprintBankSubjectPage slug={subject}/>;
}
