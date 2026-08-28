create or replace function english.recent_content_date(q english.questions)
returns date language plpgsql immutable as $$
declare s text; m text[];
begin
 foreach s in array array[coalesce(q.question_id,''),coalesce(q.source_id,''),coalesce(q.source_file,'')] loop
  m:=regexp_match(s,'(?:^|[^0-9])(20[0-9]{2})([0-9]{2})([0-9]{2})(?:[^0-9]|$)');
  if m is not null then begin return make_date(m[1]::int,m[2]::int,m[3]::int); exception when others then null; end; end if;
  m:=regexp_match(s,'(?:^|[^0-9])(20[0-9]{2})[-_]([0-9]{2})[-_]([0-9]{2})(?:[^0-9]|$)');
  if m is not null then begin return make_date(m[1]::int,m[2]::int,m[3]::int); exception when others then null; end; end if;
 end loop;
 return null;
end; $$;

create or replace function english.source_descriptor_key(q english.questions)
returns text language sql immutable as $$
with x as (select btrim(coalesce(q.source_file,'')) raw_file,btrim(coalesce(q.source_id,'')) raw_id,lower(coalesce(q.source_file,'')||' '||coalesce(q.source_id,'')) s)
select case
 when raw_file='' and raw_id='' then null
 when s ~ '\bhindu\b' then 'THE_HINDU'
 when s ~ 'screen\s*shot|screenshot|image\s*note|photo\s*note' then 'SCREENSHOTS'
 when raw_file ~ '[=→]' or lower(raw_file) ~ '\bmeans\b|\bwithout\b.+\bwith\b' or length(raw_file)>90 or s ~ 'hand\s*written|handwritten|hand_note|notes?[_ -]?img' then 'HANDWRITTEN'
 else 'NAMED::'||lower(btrim(coalesce(nullif(raw_file,''),raw_id))) end from x; $$;

create or replace function english.source_descriptor_name(q english.questions)
returns text language sql immutable as $$
with x as (select btrim(coalesce(q.source_file,'')) raw_file,btrim(coalesce(q.source_id,'')) raw_id,lower(coalesce(q.source_file,'')||' '||coalesce(q.source_id,'')) s)
select case
 when raw_file='' and raw_id='' then null
 when s ~ '\bhindu\b' then 'The Hindu'
 when s ~ 'screen\s*shot|screenshot|image\s*note|photo\s*note' then 'Screenshots'
 when raw_file ~ '[=→]' or lower(raw_file) ~ '\bmeans\b|\bwithout\b.+\bwith\b' or length(raw_file)>90 or s ~ 'hand\s*written|handwritten|hand_note|notes?[_ -]?img' then 'Handwritten Notes'
 else regexp_replace(btrim(coalesce(nullif(raw_file,''),raw_id)),'\s+',' ','g') end from x; $$;

create or replace function english.new_practice_type(p_user_id uuid,q english.questions)
returns text language plpgsql stable security definer set search_path=pg_catalog,english,auth as $$
declare v_type text; cat text; meta text; detail text;
begin
 select sit.resolved_type into v_type from english.saved_items si join english.saved_item_types sit on sit.user_id=si.user_id and sit.saved_id=si.saved_id where si.user_id=p_user_id and si.active and si.practice_question_id=q.question_id order by si.updated_at desc nulls last limit 1;
 if v_type is not null then return case v_type when 'V' then 'VOC' when 'SM' then 'SPELL' when 'OWS' then 'OWS' when 'PV' then 'PHRASAL' when 'IP' then 'IDIOM' when 'CU' then 'CU' else 'VOC' end; end if;
 cat:=english.canonical_category(q.topic);meta:=lower(concat_ws(' ',q.topic,q.subtopic,q.question_type,q.source_file,q.source_id));detail:=lower(concat_ws(' ',q.explanation,q.tip));
 if meta ~ 'spelling|misspelt|misspelled|correctly spelt|incorrectly spelt' or detail ~ 'part of speech:\s*spelling' then return 'SPELL'; end if;
 if cat='PHRASAL' or meta ~ 'phrasal verb' or detail ~ 'part of speech:\s*phrasal verb' then return 'PHRASAL'; end if;
 if cat='IDIOM' or meta ~ 'idiom' or detail ~ 'part of speech:\s*(idiom|phrase)' then return 'IDIOM'; end if;
 if cat='OWS' or meta ~ 'one word substitution|one-word substitution' or detail ~ 'part of speech:\s*(ows|one word substitution)' then return 'OWS'; end if;
 if cat='VOC' or meta ~ 'vocab|vocabulary' then return 'VOC'; end if;
 if cat<>'MISC' then return cat; end if; return 'OTHER';
end; $$;

create or replace function english.new_practice_source(p_user_id uuid,q english.questions)
returns text language sql stable security definer set search_path=pg_catalog,english,auth as $$
select case
 when exists(select 1 from english.saved_items si where si.user_id=p_user_id and si.active and si.practice_question_id=q.question_id) then 'My Saved Words'
 when exists(select 1 from english.hindu_vocab_registry h where h.user_id=p_user_id and h.active and h.in_vocab and h.question_id=q.question_id) or lower(concat_ws(' ',q.subtopic,q.source_file,q.source_id)) ~ '\bthe\s+hindu\b|hindu\s+daily' then 'The Hindu'
 when lower(concat_ws(' ',q.subtopic,q.source_file,q.source_id)) ~ 'english\s*madhyam' then 'English Madhyam'
 when lower(concat_ws(' ',q.subtopic,q.source_file,q.source_id)) ~ 'handwritten' then 'Handwritten Notes'
 else coalesce(nullif(btrim(q.source_file),''),nullif(btrim(q.source_id),''),nullif(btrim(q.subtopic),''),'Other') end; $$;

create or replace function english.question_payload(p_user_id uuid,p_question_id text)
returns jsonb language sql stable security definer set search_path=pg_catalog,english,auth as $$
select jsonb_build_object(
 'id',q.question_id,'category',english.canonical_category(q.topic),'topic',coalesce(q.topic,''),'subtopic',coalesce(q.subtopic,''),'word',coalesce(q.word,''),'question',q.question,
 'options',jsonb_build_array(jsonb_build_object('key','A','text',coalesce(q.option_a,'')),jsonb_build_object('key','B','text',coalesce(q.option_b,'')),jsonb_build_object('key','C','text',coalesce(q.option_c,'')),jsonb_build_object('key','D','text',coalesce(q.option_d,''))),
 'correctKey',upper(coalesce(q.correct,'')),'explanation',coalesce(q.explanation,''),'tip',coalesce(q.tip,''),'usageNote',coalesce(q.usage_note,''),'example',coalesce(q.example_sentence,''),'memoryAid',coalesce(q.memory_aid,''),'related',coalesce(q.related_words,''),'source',coalesce(q.source_file,q.source_id,''),'sourcePage',coalesce(q.source_page,''),'sourceUrl',coalesce(q.source_url,''),'questionType',coalesce(q.question_type,''),'conceptId',coalesce(q.concept_id,''),'difficulty',coalesce(q.difficulty,''),
 'attempts',coalesce(s.attempts,0),'wrong',coalesce(s.wrong,0),'status',coalesce(s.status,'New'),'nextReview',s.next_review,'starred',coalesce(s.last_marked,false),'difficult',coalesce(d.difficult,false),'mastered',coalesce(s.mastered,false),'added',english.recent_content_date(q)
)
from english.questions q left join english.question_state s on s.user_id=p_user_id and s.question_id=q.question_id left join english.difficult_state d on d.user_id=p_user_id and d.question_id=q.question_id where q.question_id=p_question_id; $$;
