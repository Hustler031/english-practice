import ChatgptSprintSets from "@/components/chatgpt-sprint-sets";
import SprintReportHistory from "@/components/sprint-report-history";
import SprintSubjectBank from "@/components/sprint-subject-bank";
import SprintBankCapture from "@/components/sprint-bank-capture";

export default function ExamPreparationPage(){
  return <>
    <ChatgptSprintSets/>
    <SprintReportHistory/>
    <SprintSubjectBank/>
    <SprintBankCapture/>
  </>;
}
