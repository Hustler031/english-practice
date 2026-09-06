from pathlib import Path

helper = Path('supabase/functions/_shared/english-antigravity-luna.ts')
s = helper.read_text()

anchor = 'function withTimeout(ms:number){const c=new AbortController();const timer=setTimeout(()=>c.abort(),ms);return {c,timer}}\n'
insert = '''function providerRetryMs(res:Response,payload:any,fallback:number){\n  let ms=Math.max(0,fallback);\n  const header=String(res.headers.get("retry-after")||"").trim();\n  if(/^\\d+(?:\\.\\d+)?$/.test(header))ms=Math.max(ms,Number(header)*1000+250);\n  const message=String(payload?.error?.message||"");\n  const match=message.match(/retry in\\s+([0-9.]+)\\s*s/i);\n  if(match)ms=Math.max(ms,Number(match[1])*1000+500);\n  return Math.max(fallback,Math.min(30_000,Math.ceil(ms)));\n}\n'''
if 'function providerRetryMs(' not in s:
    if anchor not in s:
        raise SystemExit('withTimeout anchor missing')
    s = s.replace(anchor, anchor + insert, 1)

old = '''  for(let attempt=0;attempt<maxAttempts;attempt++){\n    const {c,timer}=withTimeout(95_000);\n    try{'''
new = '''  for(let attempt=0;attempt<maxAttempts;attempt++){\n    const {c,timer}=withTimeout(95_000);\n    let retryMs=800*(attempt+1);\n    try{'''
if old not in s:
    raise SystemExit('antigravity loop anchor missing')
s = s.replace(old, new, 1)

old = '''      const payload=await res.json().catch(()=>null);\n      if(res.ok){'''
new = '''      const payload=await res.json().catch(()=>null);\n      if(!res.ok&&TRANSIENT.has(res.status)&&attempt<maxAttempts-1)retryMs=providerRetryMs(res,payload,retryMs);\n      if(res.ok){'''
if old not in s:
    raise SystemExit('antigravity payload anchor missing')
s = s.replace(old, new, 1)

old = '''    await sleep(800*(attempt+1));\n  }\n  throw new Error("ANTIGRAVITY_RETRY_EXHAUSTED");'''
new = '''    await sleep(retryMs);\n  }\n  throw new Error("ANTIGRAVITY_RETRY_EXHAUSTED");'''
if old not in s:
    raise SystemExit('antigravity sleep anchor missing')
s = s.replace(old, new, 1)

old = '''  for(let attempt=0;attempt<maxAttempts;attempt++){\n    const {c,timer}=withTimeout(45_000);\n    try{\n      const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_RARE_RESCUE_MODEL)}:generateContent`,{'''
new = '''  for(let attempt=0;attempt<maxAttempts;attempt++){\n    const {c,timer}=withTimeout(45_000);\n    let retryMs=1200*(attempt+1);\n    try{\n      const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_RARE_RESCUE_MODEL)}:generateContent`,{'''
if old not in s:
    raise SystemExit('rescue loop anchor missing')
s = s.replace(old, new, 1)

old = '''      const payload=await res.json().catch(()=>null);\n      if(res.ok){\n        const text=(payload?.candidates?.[0]?.content?.parts||[]).map((p:any)=>typeof p?.text==="string"&&!p?.thought?p.text:"").join("").trim();'''
new = '''      const payload=await res.json().catch(()=>null);\n      if(!res.ok&&TRANSIENT.has(res.status)&&attempt<maxAttempts-1)retryMs=providerRetryMs(res,payload,retryMs);\n      if(res.ok){\n        const text=(payload?.candidates?.[0]?.content?.parts||[]).map((p:any)=>typeof p?.text==="string"&&!p?.thought?p.text:"").join("").trim();'''
if old not in s:
    raise SystemExit('rescue payload anchor missing')
s = s.replace(old, new, 1)

old = '''    await sleep(1200*(attempt+1));\n  }\n  throw new Error("GEMINI_RESCUE_RETRY_EXHAUSTED");'''
new = '''    await sleep(retryMs);\n  }\n  throw new Error("GEMINI_RESCUE_RETRY_EXHAUSTED");'''
if old not in s:
    raise SystemExit('rescue sleep anchor missing')
s = s.replace(old, new, 1)
helper.write_text(s)

validator = Path('.github/scripts/validate-english-hybrid-ai-content.cjs')
v = validator.read_text()
anchor = "need(stage1,'Work carefully with high reasoning effort','High-effort writer instruction is explicit');\n"
check = "need(stage1,'providerRetryMs','Gemini rate-limit retry hints are honored');\n"
if check not in v:
    if anchor not in v:
        raise SystemExit('validator anchor missing')
    v = v.replace(anchor, anchor + check, 1)
validator.write_text(v)
