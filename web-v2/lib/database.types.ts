export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  __InternalSupabase: { PostgrestVersion: "14.5" }
  public: {
    Tables: { [_ in never]: never }
    Views: { [_ in never]: never }
    Functions: {
      english_add_hindu_to_vocab: { Args: { p_hindu_id: string }; Returns: Json }
      english_dashboard_summary: { Args: never; Returns: Json }
      english_get_demand_batch: { Args: { p_count?: number; p_mode?: string; p_set_id?: string }; Returns: Json }
      english_get_demand_sets: { Args: never; Returns: Json }
      english_get_difficult_items: { Args: { p_count?: number }; Returns: Json }
      english_get_hindu_quiz: { Args: never; Returns: Json }
      english_get_hindu_today: { Args: never; Returns: Json }
      english_get_new_practice_batch: { Args: { p_category?: string; p_count?: number; p_mode?: string; p_source?: string }; Returns: Json }
      english_get_new_practice_hub: { Args: never; Returns: Json }
      english_get_phrasal_audit: { Args: never; Returns: Json }
      english_get_phrasal_batch: { Args: { p_count?: number; p_mode?: string }; Returns: Json }
      english_get_phrasal_history_batch: { Args: { p_from_day: number; p_to_day: number }; Returns: Json }
      english_get_phrasal_hub: { Args: never; Returns: Json }
      english_get_phrasal_today: { Args: never; Returns: Json }
      english_get_saved_items: { Args: never; Returns: Json }
      english_get_source_batch: { Args: { p_count?: number; p_mode?: string; p_source_key: string }; Returns: Json }
      english_get_source_hub: { Args: never; Returns: Json }
      english_get_starred_items: { Args: { p_count?: number; p_mode?: string }; Returns: Json }
      english_get_topic_batch: { Args: { p_category: string; p_count?: number; p_mode?: string }; Returns: Json }
      english_get_topic_hub: { Args: never; Returns: Json }
      english_hindu_progress: { Args: never; Returns: Json }
      english_promote_saved_item: { Args: { p_saved_id: string }; Returns: Json }
      english_resume_daily: { Args: never; Returns: Json }
      english_save_word: { Args: { p_capture_type?: string; p_context?: string; p_module?: string; p_question_id?: string; p_source?: string; p_word: string }; Returns: Json }
      english_set_difficult: { Args: { p_difficult: boolean; p_question_id: string }; Returns: Json }
      english_set_hindu_marked: { Args: { p_hindu_id: string; p_marked: boolean }; Returns: Json }
      english_set_mastered: { Args: { p_mastered: boolean; p_question_id: string; p_require_proven?: boolean }; Returns: Json }
      english_set_saved_enrichment: { Args: { p_antonyms: string; p_correct_option: string; p_example: string; p_explanation: string; p_gpt_status?: string; p_meaning: string; p_option_a: string; p_option_b: string; p_option_c: string; p_option_d: string; p_part_of_speech: string; p_question: string; p_saved_id: string; p_source?: string; p_synonyms: string }; Returns: Json }
      english_set_saved_item_type: { Args: { p_capture_type: string; p_saved_id: string }; Returns: Json }
      english_set_starred: { Args: { p_question_id: string; p_starred: boolean }; Returns: Json }
      english_start_daily: { Args: { p_target?: number }; Returns: Json }
      english_submit_answer: { Args: { p_attempt_id?: string; p_marked_revision?: boolean; p_module?: string; p_question_id: string; p_selected_key: string; p_time_seconds?: number }; Returns: Json }
      english_submit_hindu_answer: { Args: { p_attempt_id?: string; p_hindu_id: string; p_selected_key: string; p_time_seconds?: number }; Returns: Json }
      english_update_saved_item: { Args: { p_antonyms?: string; p_context?: string; p_correct_option?: string; p_example?: string; p_explanation?: string; p_meaning?: string; p_option_a?: string; p_option_b?: string; p_option_c?: string; p_option_d?: string; p_part_of_speech?: string; p_question?: string; p_saved_id: string; p_synonyms?: string; p_word?: string }; Returns: Json }
    }
    Enums: { [_ in never]: never }
    CompositeTypes: { [_ in never]: never }
  }
}

export const Constants = { public: { Enums: {} } } as const
