from pathlib import Path

helper = Path('supabase/functions/_shared/english-antigravity-luna.ts')
s = helper.read_text()
if 'Math.min(30_000,Math.ceil(ms))' not in s:
    raise SystemExit('retry cap anchor missing')
s = s.replace('Math.min(30_000,Math.ceil(ms))', 'Math.min(65_000,Math.ceil(ms))', 1)
count = s.count('{maxAttempts:1,schema:args.schema}')
if count != 2:
    raise SystemExit(f'expected 2 repair maxAttempts anchors, found {count}')
s = s.replace('{maxAttempts:1,schema:args.schema}', '{maxAttempts:2,schema:args.schema}')
helper.write_text(s)

validator = Path('.github/scripts/validate-english-hybrid-ai-content.cjs')
v = validator.read_text()
anchor = "need(stage1,'providerRetryMs','Gemini rate-limit retry hints are honored');\n"
checks = (
    "need(stage1,'Math.min(65_000,Math.ceil(ms))','Provider retry hints may wait through a one-minute quota window');\n"
    "need(stage1,'{maxAttempts:2,schema:args.schema}','Repair transport retries are bounded but rate-limit aware');\n"
)
if checks not in v:
    if anchor not in v:
        raise SystemExit('validator retry anchor missing')
    v = v.replace(anchor, anchor + checks, 1)
validator.write_text(v)
