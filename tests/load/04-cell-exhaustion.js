// 4. Overflow at 90% and pool isolation.
//
// Drive the general pool past 90% of its capacity (27 calls/s of 30) while the critical
// pool runs at its committed peak.
//
// GEN_TENANTS:  comma-separated overflow-enabled tenants in the general pool, each at
//               GEN_RATE. Set the sum above 27/s, e.g. 3 tenants x 12/s = 36/s.
// CRIT_TENANTS: comma-separated tenants in the critical pool, each at CRIT_RATE, kept
//               under the critical spill point (40/s).
//
// Pass criteria:
//   - General requests above the threshold are served by pool-overflow-general
//     (x-daas-pool header; queries.kql: spill-rate). Spill starts near 27/s.
//   - No gateway 429s caused by pool capacity. Any 429 must come from a tenant's own
//     contract limit (rate-limit-by-key), so keep GEN_RATE within each tenant's tier or
//     expect those 429s.
//   - Critical tenants: zero 429s, flat p95, and never served by a general pool.
//   - Nothing from general reaches pool-overflow-critical, and vice versa.
import { submit, poll, tenantScenario } from './lib.js';

const GEN_RATE = parseInt(__ENV.GEN_RATE || '12', 10);
const CRIT_RATE = parseInt(__ENV.CRIT_RATE || '6', 10);
const DURATION = __ENV.DURATION || '10m';
const list = (s) => (s || '').split(',').filter(Boolean);
const gen = list(__ENV.GEN_TENANTS);
const crit = list(__ENV.CRIT_TENANTS);

const withZone = (scenario, zone) => ({ ...scenario, env: { ...scenario.env, ZONE: zone } });

const scenarios = {};
const thresholds = { checks: ['rate>0.99'] };
for (const t of gen) scenarios[`gen_${t.slice(-4)}`] = withZone(tenantScenario(t, GEN_RATE, DURATION), 'general');
for (const t of crit) {
  scenarios[`crit_${t.slice(-4)}`] = withZone(tenantScenario(t, CRIT_RATE, DURATION), 'critical');
  thresholds[`analyze_429{tenant:${t}}`] = ['rate==0'];
  thresholds[`analyze_latency{tenant:${t}}`] = ['p(95)<2000'];
}
// Spill must actually happen for the general pool...
thresholds['served_by_pool{pool:pool-overflow-general}'] = ['count>0'];
// ...and never cross zones.
thresholds['served_by_pool{zone:general,pool:pool-overflow-critical}'] = ['count==0'];
thresholds['served_by_pool{zone:critical,pool:pool-overflow-general}'] = ['count==0'];

export const options = { scenarios, thresholds };

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
