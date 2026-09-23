// 4. Cell exhaustion: saturate a General and a Confidential cell. Each spills only to
// its own zone's overflow pool, only for overflow-enabled tenants, within caps.
//
// GEN_TENANTS / CONF_TENANTS: comma-separated tenants in one General / Confidential cell.
// NO_OVERFLOW_TENANT: a tenant in the saturated cell with overflow=false.
// RATE: per-tenant TPS, set so the sum exceeds the cell's DI TPS.
//
// Pass criteria (queries.kql: overflow-by-zone):
//   - General tenants' overflow traffic hits only pool-overflow-general members.
//   - Confidential tenants' overflow traffic hits only pool-overflow-confidential members.
//   - NO_OVERFLOW_TENANT never reaches an overflow member; it sees 429s instead.
//   - Per tenant, overflow requests per 10 s window stay <= 30 (policy cap).
import { submit, poll, tenantScenario } from './lib.js';

const RATE = parseInt(__ENV.RATE || '10', 10);
const DURATION = __ENV.DURATION || '10m';
const list = (s) => (s || '').split(',').filter(Boolean);
const tenants = [...list(__ENV.GEN_TENANTS), ...list(__ENV.CONF_TENANTS), ...list(__ENV.NO_OVERFLOW_TENANT)];

export const options = {
  scenarios: Object.fromEntries(tenants.map((t) => [`t_${t.slice(-4)}`, tenantScenario(t, RATE, DURATION)])),
  thresholds: {
    checks: ['rate>0.99'], // every 429 carries Retry-After
  },
};

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
