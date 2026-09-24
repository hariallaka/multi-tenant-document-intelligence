// 4. Pool exhaustion and isolation: saturate the general pool while the critical pool
// runs at its committed peak. Critical must be unaffected; general must shed load as
// 429 + Retry-After at the gateway.
//
// GEN_TENANTS:  comma-separated tenants in the general pool (driven at GEN_RATE each,
//               set so the sum exceeds the pool's 30 Analyze TPS).
// CRIT_TENANTS: comma-separated tenants in the critical pool (driven at CRIT_RATE each,
//               within the pool's 36 TPS budget).
//
// Pass criteria:
//   - critical tenants: zero 429s and flat p95 latency.
//   - general tenants: throttling shows up as 429 + Retry-After, never as 5xx.
//   - queries.kql (pool-isolation): general traffic hits only general members.
// If overflow pools are added later, also check overflow-by-zone.
import { submit, poll, tenantScenario } from './lib.js';

const GEN_RATE = parseInt(__ENV.GEN_RATE || '12', 10);
const CRIT_RATE = parseInt(__ENV.CRIT_RATE || '6', 10);
const DURATION = __ENV.DURATION || '10m';
const list = (s) => (s || '').split(',').filter(Boolean);
const gen = list(__ENV.GEN_TENANTS);
const crit = list(__ENV.CRIT_TENANTS);

const scenarios = {};
const thresholds = { checks: ['rate>0.99'] }; // every 429 carries Retry-After
for (const t of gen) scenarios[`gen_${t.slice(-4)}`] = tenantScenario(t, GEN_RATE, DURATION);
for (const t of crit) {
  scenarios[`crit_${t.slice(-4)}`] = tenantScenario(t, CRIT_RATE, DURATION);
  thresholds[`analyze_429{tenant:${t}}`] = ['rate==0'];
  thresholds[`analyze_latency{tenant:${t}}`] = ['p(95)<2000'];
}

export const options = { scenarios, thresholds };

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
