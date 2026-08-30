const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const text=fs.readFileSync(path.join(root,'.github/english-v2-fresh-session-module-audit.md'),'utf8');
const required=['Daily','Central Revision','Difficult','My Saved New','My Saved History','New Practice New','Topic Practice New','Sources / PDFs Practice New','Starred Revision','Phrasal Smart','Phrasal Today','Phrasal History','Extra Practice','Bank Coverage Unseen','Bank Coverage Seen Practice','Bank Coverage Today Review','Demanded Practice Weak / Random','Demanded Practice Practice All / Resume','The Hindu Today / rounds'];
let bad=false;
for(const label of required){if(!text.includes(label)){console.error(`❌ Missing module classification: ${label}`);bad=true;}else console.log(`✅ Classified: ${label}`)}
if(!text.includes('generic 12-hour cache')){console.error('❌ Cache policy summary missing');bad=true}else console.log('✅ Cache policy summary documented');
if(bad)process.exit(1);
console.log('\n✅ English V2 session lane audit coverage passed.');
