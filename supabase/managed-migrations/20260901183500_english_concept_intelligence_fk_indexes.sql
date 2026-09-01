create index if not exists english_ai_interventions_concept_idx
  on english.ai_interventions(concept_id);

create index if not exists english_ai_interventions_question_idx
  on english.ai_interventions(question_id);

create index if not exists english_concept_evidence_concept_idx
  on english.concept_evidence(concept_id);

create index if not exists english_concept_events_concept_idx
  on english.concept_evidence_events(concept_id);

create index if not exists english_concept_events_question_idx
  on english.concept_evidence_events(question_id);

create index if not exists english_concept_relationships_related_idx
  on english.concept_relationships(related_concept_id);

create index if not exists english_confidence_signals_attempt_idx
  on english.learner_confidence_signals(attempt_id);

create index if not exists english_confidence_signals_question_idx
  on english.learner_confidence_signals(question_id);

create index if not exists english_saved_concept_concept_idx
  on english.saved_concept_mappings(concept_id);

create index if not exists english_semantic_queue_user_idx
  on english.semantic_queue(user_id);
