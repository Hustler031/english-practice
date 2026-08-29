create table if not exists legacy.english_performance_raw (
  source_row bigint generated always as identity primary key,
  "Timestamp" text, "Question_ID" text, "Selected_Answer" text, "Correct" text,
  "Time_Seconds" text, "Marked_Revision" text, "Attempt_ID" text, "Topic" text,
  "Concept_ID" text, "Module" text
);
create table if not exists legacy.english_starred_revision_log_raw (
  source_row bigint generated always as identity primary key,
  "Question_ID" text, "Event_At" text, "Starred_Date" text, "Day_No" text, "Action" text
);
create table if not exists legacy.english_starred_revision_difficult_raw (
  source_row bigint generated always as identity primary key,
  "Question_ID" text, "Difficult" text, "Updated_At" text
);
create table if not exists legacy.english_mastered_log_raw (
  source_row bigint generated always as identity primary key,
  "Question_ID" text, "Mastered_On" text, "Reason" text, "Previous_Status" text,
  "Source" text, "Category" text, "Restored_On" text, "Active" text
);
create table if not exists legacy.english_daily_quiz_raw (
  source_row bigint generated always as identity primary key,
  "Question_ID" text, "Priority" text, "Reason" text, "Quiz_Date" text,
  "Status" text, "Topic" text, "Concept_ID" text
);
create table if not exists legacy.english_sources_raw (
  source_row bigint generated always as identity primary key,
  "Source_ID" text, "Source_Type" text, "Source_Name" text, "Source_File" text,
  "Source_Date" text, "Active" text, "Imported_On" text, "Question_Count" text,
  "Source_Ref" text, "Notes" text, "Import_Status" text, "New_Count" text,
  "Recall_Count" text, "Duplicate_Count" text, "Category_Summary" text, "Processed_On" text
);
create table if not exists legacy.english_hindu_words_raw (
  source_row bigint generated always as identity primary key,
  "Hindu_ID" text, "Date" text, "Word" text, "Part_of_Speech" text, "Meaning" text,
  "Synonyms" text, "Antonyms" text, "Example_Sentence" text, "Word_Family" text,
  "Usage_Note" text, "Tip" text, "Memory_Aid" text, "Article_Title" text,
  "Source_URL" text, "Source_Name" text, "Learning_Status" text, "Content_Status" text,
  "First_Practiced" text, "Last_Practiced" text, "Active" text
);
create table if not exists legacy.english_demanded_practice_raw (
  source_row bigint generated always as identity primary key,
  "Batch_ID" text, "Batch_Name" text, "Question_ID" text, "Sequence" text,
  "Created_Date" text, "Created_By" text, "Notes" text, "Active" text
);
create table if not exists legacy.english_my_word_types_raw (
  source_row bigint generated always as identity primary key,
  "Saved_ID" text, "Capture_Type" text, "Updated_At" text
);

alter table legacy.english_performance_raw enable row level security;
alter table legacy.english_starred_revision_log_raw enable row level security;
alter table legacy.english_starred_revision_difficult_raw enable row level security;
alter table legacy.english_mastered_log_raw enable row level security;
alter table legacy.english_daily_quiz_raw enable row level security;
alter table legacy.english_sources_raw enable row level security;
alter table legacy.english_hindu_words_raw enable row level security;
alter table legacy.english_demanded_practice_raw enable row level security;
alter table legacy.english_my_word_types_raw enable row level security;

revoke all on all tables in schema legacy from anon, authenticated;
