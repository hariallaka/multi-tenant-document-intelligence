// 1. Baseline: all tenants at committed peak; target zero 429s at DI.
// PEAKS='{"<tenant>": <peak analyze TPS>, ...}' k6 run 01-baseline.js
import { submit, poll, tenantScenario, TENANTS } from './lib.js';

const PEAKS = JSON.parse(__ENV.PEAKS || '{}');
const DURATION = __ENV.DURATION || '15m';

export const options = {
  scenarios: Object.fromEntries(TENANTS.map((t) => [`t_${t.slice(-4)}`, tenantScenario(t, PEAKS[t] || 1, DURATION)])),
  thresholds: {
    analyze_429: ['rate==0'], // gateway admission holds every tenant within budget
    result_429: ['rate<0.001'],
    'http_req_duration{op:analyze}': ['p(95)<2000'],
  },
};

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
