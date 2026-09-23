// 2. Noisy tenant: one tenant at 5x its limit; the others' p95 latency and 429 rate stay flat.
// NOISY=<tenant> PEAKS='{...}' k6 run 02-noisy-tenant.js
import { submit, poll, tenantScenario, TENANTS } from './lib.js';

const PEAKS = JSON.parse(__ENV.PEAKS || '{}');
const NOISY = __ENV.NOISY || TENANTS[0];
const DURATION = __ENV.DURATION || '15m';

const scenarios = {};
const thresholds = {};
for (const t of TENANTS) {
  const name = `t_${t.slice(-4)}`;
  const rate = t === NOISY ? 5 * (PEAKS[t] || 1) : PEAKS[t] || 1;
  scenarios[name] = tenantScenario(t, rate, DURATION);
  if (t !== NOISY) {
    thresholds[`analyze_429{tenant:${t}}`] = ['rate==0'];
    thresholds[`analyze_latency{tenant:${t}}`] = ['p(95)<2000'];
  }
}
// The noisy tenant must be throttled at the gateway, not spread across the cell.
thresholds[`analyze_429{tenant:${NOISY}}`] = ['rate>0.5'];

export const options = { scenarios, thresholds };

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
