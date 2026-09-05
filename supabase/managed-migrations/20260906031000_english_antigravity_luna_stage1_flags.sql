begin;

alter table english.ai_content_feature_flags
  drop constraint if exists ai_content_feature_flags_name;

alter table english.ai_content_feature_flags
  add constraint ai_content_feature_flags_name
  check (flag = any (array[
    'gemini_content_v1'::text,
    'groq_critic_v1'::text,
    'phrasal_sense_v1'::text,
    'phrasal_context_fill_v1'::text,
    'phrasal_variant_rotation_v1'::text,
    'chatgpt_sprint_v1'::text,
    'hindu_tone_v1'::text,
    'antigravity_writer_v1'::text,
    'luna_critic_v1'::text
  ]));

insert into english.ai_content_feature_flags(flag, enabled, activated_at, metadata, updated_at)
values
  ('antigravity_writer_v1', true, now(), '{"scope":["saved","phrasal"],"reasoning":"high","stage":"stage1"}'::jsonb, now()),
  ('luna_critic_v1', true, now(), '{"scope":["saved","phrasal"],"reasoning":"low","one_item_per_call":true,"stage":"stage1"}'::jsonb, now())
on conflict (flag) do update
set enabled=excluded.enabled,
    activated_at=coalesce(english.ai_content_feature_flags.activated_at, excluded.activated_at),
    metadata=english.ai_content_feature_flags.metadata || excluded.metadata,
    updated_at=now();

commit;
