const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '../..');
const component = fs.readFileSync(path.join(root, 'web-v2/components/daily-rollover-sync.tsx'), 'utf8');
const migration = fs.readFileSync(path.join(root, 'supabase/migrations/20260907054500_english_daily_rollover_safety_net.sql'), 'utf8');

let bad = 0;
const ok = m => console.log('✓ ' + m);
const fail = m => { bad++; console.error('✗ ' + m); };
const need = (s, x, m) => s.includes(x) ? ok(m) : fail(m);
const forbid = (s, x, m) => !s.includes(x) ? ok(m) : fail(m);

need(component, 'supabase.auth.onAuthStateChange', 'Rollover retries when persisted auth becomes ready');
need(component, 'lastSyncAt.current === 0', 'Auth retry is limited to a missing initial rollover');
need(component, 'void sync(true)', 'Auth/bootstrap retry invokes the live rollover owner');
need(component, 'const blockDailyBoot = pathname === "/english/daily" && !bootReady', 'Only the Daily route is hard-gated');
forbid(component, 'return bootReady ? <>{children}</> : null', 'English Home cannot be blanked by the rollover gate');

need(migration, "pg_advisory_xact_lock(hashtext('english.ensure_daily'), hashtext(p_user_id::text))", 'Concurrent Daily rollover calls serialize per learner');
need(migration, 'if v_batch<v_today and v_pending=0 then', 'Only effectively-complete old batches advance');
need(migration, 'english.daily_effective_counts', 'Rollover completion uses effective completion semantics');
need(migration, 'english.rollover_ready_daily_users()', 'Backend safety-net owner exists');
need(migration, "'english-daily-rollover-safety-net'", 'Backend rollover safety-net is scheduled');
need(migration, "'17 * * * *'", 'Safety-net retries hourly');

if (bad) {
  console.error(`\nDaily rollover safety validation failed with ${bad} defect(s).`);
  process.exit(1);
}
console.log('\n✅ Daily rollover safety contracts passed.');
