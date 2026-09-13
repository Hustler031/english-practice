import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.cwd(), '..');
const files = [
  'supabase/migrations/20260913201000_english_phrasal_usage_intelligence_v2.sql',
  'supabase/migrations/20260913201100_english_phrasal_daily_usage_curriculum.sql',
  'supabase/migrations/20260913201200_english_phrasal_focus_usage_router_v2.sql',
].map((p) => [p, fs.readFileSync(path.join(root, p), 'utf8')]);

const all = files.map(([, s]) => s).join('\n');
const requireText = (text, needle, label) => {
  if (!text.includes(needle)) throw new Error(`Missing ${label}: ${needle}`);
};

requireText(all, 'phrasal_concepts_v2', 'four-axis intelligence');
requireText(all, 'phrasal_effective_family(q)', 'effective generated-family attribution');
requireText(all, 'usage_attempts', 'usage evidence axis');
requireText(all, "'usageWeak'", 'usage audit surface');

const daily = files[1][1];
requireText(daily, "'recognition','recognition'", 'recognition curriculum lane');
requireText(daily, "'usage_recall'", 'usage/recall curriculum lane');
requireText(daily, "'confusion','confusion'", 'confusion curriculum lane');
requireText(daily, 'limit 4', 'recognition 4-slot cap');
requireText(daily, 'limit 8', '8-slot curriculum lanes');
requireText(daily, 'requestedQuestionFamily', 'requested-family authority');
requireText(daily, 'content_gap', 'generated-only gap handoff');
requireText(daily, "base:=public.english_get_phrasal_daily_curriculum_batch(20)", 'daily selector cutover');

const focus = files[2][1];
requireText(focus, 'fill_daily_focus_phrasal_v2', 'CI Focus router');
requireText(focus, "limit 2", 'soft recognition target');
requireText(focus, "limit 7", 'soft usage/recall target');
requireText(focus, "limit 6", 'soft confusion target');
requireText(focus, "language_v2_usage_first", 'Focus V2 provenance');
requireText(focus, "v_before=0", 'frozen existing Focus guard');
requireText(focus, 'ensure_daily_focus_language_lanes_v1', 'compatibility wrapper');

if (/maths_|gk_/i.test(all)) throw new Error('Phrasal migration must not touch Maths/GK contracts');
console.log('Phrasal Usage-First V2 contracts: PASS');
