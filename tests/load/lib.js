// Shared helpers for the design's six nonprod load tests (k6).
//
// Inputs (environment variables, never committed):
//   GATEWAY      https://<apim-host>/di/v1
//   TOKENS_FILE  JSON file: { "<tenant client id>": "<bearer token>", ... }
//                Fetch with client credentials for the gateway audience before the run.
//   DOC_URL      urlSource for the test document (staged Blob, SAS or DI-readable)
//   MODEL        model ID (default prebuilt-read)
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

export const GATEWAY = __ENV.GATEWAY;
export const MODEL = __ENV.MODEL || 'prebuilt-read';
export const DOC_URL = __ENV.DOC_URL;
export const TOKENS = JSON.parse(open(__ENV.TOKENS_FILE || './tokens.json'));
export const TENANTS = Object.keys(TOKENS);

export const analyze429 = new Rate('analyze_429');
export const result429 = new Rate('result_429');
export const result404 = new Counter('result_404');
export const analyzeLatency = new Trend('analyze_latency', true);
export const jobDuration = new Trend('job_duration', true);
// Pool that served each analyze call (x-daas-pool, set by op-analyze.xml): home or overflow.
export const servedBy = new Counter('served_by_pool');

function headers(tenant) {
  return { Authorization: `Bearer ${TOKENS[tenant]}`, 'Content-Type': 'application/json' };
}

// POST analyze; returns the signed result URL or null. Tags each request with the
// tenant so thresholds and dashboards can be split per tenant.
export function submit(tenant, docUrl = DOC_URL, model = MODEL, query = '') {
  const res = http.post(
    `${GATEWAY}/documentModels/${model}/analyze${query}`,
    JSON.stringify({ urlSource: docUrl }),
    { headers: headers(tenant), tags: { tenant, op: 'analyze' } },
  );
  analyze429.add(res.status === 429, { tenant });
  const pool = res.headers['X-Daas-Pool'] || 'none';
  servedBy.add(1, { tenant, pool, zone: __ENV.ZONE || 'unknown' });
  analyzeLatency.add(res.timings.duration, { tenant });
  check(res, { 'analyze 202 or 429': (r) => r.status === 202 || r.status === 429 });
  if (res.status === 429) {
    check(res, { '429 carries Retry-After': (r) => !!r.headers['Retry-After'] });
    return null;
  }
  return res.headers['Operation-Location'] || null;
}

// Poll a result URL honouring Retry-After, never faster than every 2 s.
export function poll(tenant, url, maxSeconds = 300) {
  const start = Date.now();
  while ((Date.now() - start) / 1000 < maxSeconds) {
    const res = http.get(url, { headers: headers(tenant), tags: { tenant, op: 'result' } });
    result429.add(res.status === 429, { tenant });
    if (res.status === 404) {
      result404.add(1, { tenant });
      return res;
    }
    if (res.status === 200) {
      const status = res.json('status');
      if (status === 'succeeded' || status === 'failed') {
        jobDuration.add(Date.now() - start, { tenant });
        return res;
      }
    }
    const retryAfter = parseInt(res.headers['Retry-After'] || '2', 10);
    sleep(Math.max(2, retryAfter));
  }
  return null;
}

// Constant-arrival-rate scenario for one tenant at a given Analyze TPS.
export function tenantScenario(tenant, rate, duration, exec = 'submitAndPoll') {
  return {
    executor: 'constant-arrival-rate',
    exec,
    rate,
    timeUnit: '1s',
    duration,
    preAllocatedVUs: Math.max(10, rate * 20),
    maxVUs: Math.max(50, rate * 60),
    env: { TENANT: tenant },
    tags: { tenant },
  };
}
