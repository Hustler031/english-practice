-- Defense-in-depth constraints for the user-owned question revision overlay.

alter table english.question_revision_proposals
  drop constraint if exists english_question_revision_ready_payload_ck;
alter table english.question_revision_proposals
  add constraint english_question_revision_ready_payload_ck
  check (
    status not in ('ready','applied','kept')
    or (
      proposed_payload is not null
      and critic is not null
      and generation_source is not null
      and generation_source in ('bank_first','ai_last_resort')
    )
  );

alter table english.question_revision_proposals
  drop constraint if exists english_question_revision_identity_uk;
alter table english.question_revision_proposals
  add constraint english_question_revision_identity_uk
  unique(proposal_id,user_id,question_id,proposal_version);

alter table english.user_question_revisions
  drop constraint if exists english_user_question_revision_identity_fk;
alter table english.user_question_revisions
  add constraint english_user_question_revision_identity_fk
  foreign key(proposal_id,user_id,question_id,proposal_version)
  references english.question_revision_proposals(proposal_id,user_id,question_id,proposal_version)
  on delete restrict;
