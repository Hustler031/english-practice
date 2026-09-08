-- Restore the six legacy My Saved rows whose capture timestamp was lost during migration.
-- Saved IDs are generated from Asia/Kolkata local time by english_save_word_with_intent_core_20260908,
-- so the YYYYMMDD_HH24MISS segment is the authoritative capture timestamp for these legacy rows.

update english.saved_items
set created_at = make_timestamptz(
  substring(saved_id from 4 for 4)::integer,
  substring(saved_id from 8 for 2)::integer,
  substring(saved_id from 10 for 2)::integer,
  substring(saved_id from 13 for 2)::integer,
  substring(saved_id from 15 for 2)::integer,
  substring(saved_id from 17 for 2)::double precision,
  'Asia/Kolkata'
)
where created_at is null
  and saved_id ~ '^MW_[0-9]{8}_[0-9]{6}_[A-Z0-9]+$';
