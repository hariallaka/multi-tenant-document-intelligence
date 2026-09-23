// 5. Large documents: 2,000-page PDFs; the per-resource GET budget must hold.
//
// The design runs this through the batch path (dispatcher-owned polling). Until the
// dispatcher exists (dispatcher/README.md), this drives the gateway directly with
// urlSource and the 2 s polling floor, which exercises the same GET budget:
//   GET/s = (POST/s x processing s) / poll interval  <=  0.8 x 50
// LARGE_DOC_URL=<2,000-page PDF urlSource> TENANT=<tenant> k6 run 05-large-documents.js
import { submit, poll } from './lib.js';

export const options = {
  scenarios: {
    large: {
      executor: 'constant-arrival-rate',
      rate: parseInt(__ENV.RATE || '1', 10),
      timeUnit: '5s',
      duration: __ENV.DURATION || '20m',
      preAllocatedVUs: 200,
      maxVUs: 600,
      exec: 'large',
    },
  },
  thresholds: {
    result_429: ['rate<0.001'],
    'http_reqs{op:result}': ['rate<40'], // 80% of the 50 GET/s default, per resource under test
  },
};

export function large() {
  const url = submit(__ENV.TENANT, __ENV.LARGE_DOC_URL);
  if (url) poll(__ENV.TENANT, url, 1800);
}
