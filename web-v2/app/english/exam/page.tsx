import ChatgptSprintSets from "@/components/chatgpt-sprint-sets";
import SprintReportHistory from "@/components/sprint-report-history";
import SprintSubjectBank from "@/components/sprint-subject-bank";
import SprintBankCapture from "@/components/sprint-bank-capture";

// ChatgptSprintSets is now the focused Exam Preparation owner; after Luna PASS it
// delegates the actual timed attempt to the existing ExamPreparationFinal runner.
export default function ExamPreparationPage(){
  return <>
    <ChatgptSprintSets/>
    <SprintReportHistory/>
    <SprintSubjectBank/>
    <SprintBankCapture/>
  </>;
}
