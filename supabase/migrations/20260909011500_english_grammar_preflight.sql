-- ENGLISH V2 — Grammar Intelligence Stage 1 preflight
-- Fix the live constraint name before the foundation migration introduces grammar_ai_v1.

alter table english.ai_content_feature_flags
  drop constraint if exists ai_content_feature_flags_name;
alter table english.ai_content_feature_flags
  drop constraint if exists ai_content_feature_flags_flag_check;
alter table english.ai_content_feature_flags
  add constraint ai_content_feature_flags_flag_check
  check (flag = any (array[
    'gemini_content_v1'::text,'groq_critic_v1'::text,'phrasal_sense_v1'::text,
    'phrasal_context_fill_v1'::text,'phrasal_variant_rotation_v1'::text,
    'chatgpt_sprint_v1'::text,'hindu_tone_v1'::text,'antigravity_writer_v1'::text,
    'luna_critic_v1'::text,'grammar_ai_v1'::text
  ]));
