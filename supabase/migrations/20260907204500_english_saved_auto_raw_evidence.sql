-- AUTO classification must never learn from its own generated enrichment.
-- Learner-entered text + immutable origin topic are authoritative; generated
-- meaning/POS/question/explanation are intentionally ignored for AUTO.

create or replace function english.resolve_saved_type(
  p_capture_type text,
  p_word text,
  p_meaning text,
  p_context text,
  p_part_of_speech text,
  p_question text,
  p_explanation text
)
returns text
language sql
immutable
set search_path to pg_catalog, english
as $function$
with x as (
  select
    upper(btrim(coalesce(p_capture_type,'AUTO'))) as capture,
    lower(btrim(coalesce(p_word,''))) as learner_text,
    lower(coalesce(p_context,'')) as context_text
)
select case
  -- Explicit learner choice always wins.
  when capture in ('V','SM','OWS','PV','IP','CU') then capture

  -- Explicit learner-entered intent overrides origin family.
  when learner_text ~ '(\mspell(ing|ed|t)?\M|misspell|correct spelling|incorrect spelling|wrong spelling)'
    then 'SM'

  when learner_text ~ '(grammar|confusable|confusion|difference between|differences between|differentiate|distinguish between|\mvs\M|countable|uncountable|subject[- ]verb|subject verb|agreement|singular[[:space:]]+(noun|verb)|plural[[:space:]]+(noun|verb)|many[[:space:]]+a\M|fixed[[:space:]]+preposition|correct[[:space:]]+usage|incorrect[[:space:]]+usage|article[[:space:]]+rule|determiner[[:space:]]+rule|pronoun[[:space:]]+rule|tense[[:space:]]+rule|voice[[:space:]]+rule|narration[[:space:]]+rule|reported[[:space:]]+speech|conditional[[:space:]]+rule|modifier[[:space:]]+rule|parallelism|error[[:space:]]+(detection|spotting)|sentence[[:space:]]+correction)'
    then 'CU'

  -- The saved question's canonical topic is the strongest contextual evidence.
  when context_text ~ 'origin[ -]?topic:[[:space:]]*(spelling|spelling mistakes)\M' then 'SM'
  when context_text ~ 'origin[ -]?topic:[[:space:]]*phrasal verbs?\M' then 'PV'
  when context_text ~ 'origin[ -]?topic:[[:space:]]*(one word substitution|fields of study)\M' then 'OWS'
  when context_text ~ 'origin[ -]?topic:[[:space:]]*(idioms?[[:space:]]*&[[:space:]]*phrases|idiom)\M' then 'IP'
  when context_text ~ 'origin[ -]?topic:[[:space:]]*(fixed preposition|grammar / usage|error detection)\M' then 'CU'
  when context_text ~ 'origin[ -]?topic:[[:space:]]*(vocabulary|the hindu vocabulary|synonym)\M' then 'V'

  -- High-confidence lexical fallback for manually saved phrasal verbs.
  when learner_text ~ '^(back|bear|beat|blow|break|bring|brush|call|carry|check|clear|close|come|count|cross|cut|do|drop|end|fall|fill|find|get|give|go|hand|hang|hold|keep|leave|let|live|look|make|move|pass|pay|pick|point|pull|put|read|run|see|set|show|speak|split|stand|step|stick|take|throw|try|turn|walk|wear|work|write)[[:space:]]+(about|across|after|along|around|aside|away|back|by|down|for|forth|forward|in|into|off|on|out|over|through|to|up|upon|with)([[:space:]]+(about|across|after|along|around|away|back|down|for|from|in|into|of|off|on|out|over|through|to|up|with))?$'
    then 'PV'

  -- A bare/ambiguous lexical save defaults to Vocabulary. The learner can use
  -- the now-visible category controls when intent cannot be inferred safely.
  else 'V'
end
from x;
$function$;

-- Strong-evidence helper is only for historical repair. It prevents us from
-- rewriting ambiguous old AUTO saves that lacked origin metadata.
create or replace function english.saved_auto_has_strong_evidence(
  p_word text,
  p_context text,
  p_origin_topic text
)
returns boolean
language sql
immutable
set search_path to pg_catalog, english
as $function$
select
  btrim(coalesce(p_origin_topic,'')) in (
    'Spelling','Spelling Mistakes','Phrasal Verb','Phrasal Verbs',
    'One Word Substitution','Fields of Study','Idioms & Phrases','Idiom',
    'Fixed Preposition','Grammar / Usage','Error Detection',
    'Vocabulary','The Hindu Vocabulary','Synonym'
  )
  or lower(coalesce(p_word,'')) ~ '(\mspell(ing|ed|t)?\M|misspell|correct spelling|incorrect spelling|wrong spelling|grammar|confusable|confusion|difference between|differences between|differentiate|distinguish between|\mvs\M|countable|uncountable|subject[- ]verb|subject verb|agreement|singular[[:space:]]+(noun|verb)|plural[[:space:]]+(noun|verb)|many[[:space:]]+a\M|fixed[[:space:]]+preposition|correct[[:space:]]+usage|incorrect[[:space:]]+usage|reported[[:space:]]+speech|parallelism|error[[:space:]]+(detection|spotting)|sentence[[:space:]]+correction)'
  or lower(btrim(coalesce(p_word,''))) ~ '^(back|bear|beat|blow|break|bring|brush|call|carry|check|clear|close|come|count|cross|cut|do|drop|end|fall|fill|find|get|give|go|hand|hang|hold|keep|leave|let|live|look|make|move|pass|pay|pick|point|pull|put|read|run|see|set|show|speak|split|stand|step|stick|take|throw|try|turn|walk|wear|work|write)[[:space:]]+(about|across|after|along|around|aside|away|back|by|down|for|forth|forward|in|into|off|on|out|over|through|to|up|upon|with)([[:space:]]+(about|across|after|along|around|away|back|down|for|from|in|into|of|off|on|out|over|through|to|up|with))?$';
$function$;

-- Recompute only historical AUTO rows for which raw evidence is strong.
create temporary table _english_saved_auto_raw_repair on commit drop as
select
  t.user_id,
  t.saved_id,
  t.resolved_type as old_resolved,
  english.resolve_saved_type(
    'AUTO',
    s.word,
    '',
    concat_ws(' ',s.context,case when coalesce(q.topic,'')<>'' then 'Origin topic: '||q.topic end),
    '',
    '',
    ''
  ) as new_resolved
from english.saved_item_types t
join english.saved_items s
  on s.user_id=t.user_id and s.saved_id=t.saved_id and s.active
left join english.questions q on q.question_id=s.origin_question_id
where t.capture_type='AUTO'
  and english.saved_auto_has_strong_evidence(s.word,s.context,q.topic);

update english.saved_item_types t
set resolved_type=r.new_resolved,
    updated_at=now()
from _english_saved_auto_raw_repair r
where t.user_id=r.user_id
  and t.saved_id=r.saved_id
  and t.resolved_type is distinct from r.new_resolved;

update english.saved_items s
set gpt_status='Needs Enrichment',
    practice_question_id=null,
    gpt_source='',
    updated_at=now()
from _english_saved_auto_raw_repair r
where s.user_id=r.user_id
  and s.saved_id=r.saved_id
  and r.old_resolved is distinct from r.new_resolved;

update english.saved_enrichment_item_state es
set state='pending',
    lease_id=null,
    last_error=null,
    last_error_at=null,
    next_attempt_at=null,
    updated_at=now()
from _english_saved_auto_raw_repair r
where es.user_id=r.user_id
  and es.saved_id=r.saved_id
  and r.old_resolved is distinct from r.new_resolved;

select english.kick_saved_enrichment_worker(1);
