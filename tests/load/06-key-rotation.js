// 6. Key rotation: rotate result-signing-key mid-test; in-flight tickets still resolve.
//
// At ROTATE_AT (default 5m) run: scripts/rotate-signing-key.sh <key-vault> <apim> <rg>
// Tickets issued before the rotation verify with result-signing-key-prev.
// Pass criteria: zero result 404s across the rotation.
// TENANT=<tenant> k6 run 06-key-rotation.js
import { submit, poll, tenantScenario } from './lib.js';

export const options = {
  scenarios: { rotate: tenantScenario(__ENV.TENANT, parseInt(__ENV.RATE || '2', 10), __ENV.DURATION || '15m') },
  thresholds: {
    result_404: ['count==0'],
  },
};

export function submitAndPoll() {
  const url = submit(__ENV.TENANT);
  // Deliberately slow first poll so many tickets straddle the rotation.
  if (url) poll(__ENV.TENANT, url, 600);
}
