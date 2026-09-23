// 3. Member loss: disable one member of a cell mid-run; traffic shifts within the trip window.
//
// At DISABLE_AT (default 5m) run, from a host with line-of-sight:
//   ./disable-member.sh <resource-group> <di-account-name>
// which rejects the member's private endpoint connection so APIM sees failures and trips
// its breaker. Re-approve the connection after the test.
//
// Pass criteria: analyze 429 rate returns to ~0 within 30 s of the disable (breaker trip
// 10 s + retry), and APIM GatewayLogs show retries landing on the other member
// (see queries.kql: retry-lands-elsewhere).
// TENANT=<tenant in the cell> RATE=<its peak> k6 run 03-member-loss.js
import { submit, poll, tenantScenario } from './lib.js';

export const options = {
  scenarios: { cell: tenantScenario(__ENV.TENANT, parseInt(__ENV.RATE || '4', 10), __ENV.DURATION || '15m') },
  thresholds: {
    analyze_429: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  if (url) poll(__ENV.TENANT, url);
}
