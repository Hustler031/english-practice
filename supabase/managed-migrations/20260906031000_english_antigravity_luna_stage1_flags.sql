begin;

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
