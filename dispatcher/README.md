# Batch dispatcher (stub)

> TODO: out of scope for this pass (AKS + Service Bus + Redis token buckets). This file
> records the contract from `docs/design.md` so the gateway and dispatcher stay compatible.

## Role

Load-levels bulk and large-document work so nothing reaches DI without a token, and owns
result polling so tenants never see result URLs on the batch path.

## Contract with the gateway

| Item | Contract |
| --- | --- |
| Identity | AKS Workload Identity. Its client ID is the `dispatcher-app-id` named value. |
| Tenant | Sends `x-daas-tenant: <tenant client id>`. The gateway honours the header **only** from this identity and strips it before DI. |
| Calls | `POST /di/v1/documentModels/{modelId}/analyze` and `GET /di/v1/results/{ticket}`, same as tenants. |
| Limits | Per-tenant gateway limits still apply to dispatched work. |

## Behaviour

- **Input:** one Service Bus queue, or one session, per tenant. A tenant's backlog delays only that tenant.
- **Scheduling:** weighted fair scheduling across tenants.
- **Admission:** a Redis token bucket per DI resource at 80% of Analyze TPS, and a second
  bucket at 80% of GET TPS. Buckets are shared by all replicas.
- **Polling:** wait for `Retry-After` from the analyze response, then back off 2, 5, 13 and 34 s.
- **Output:** write results to tenant result storage and publish an Event Grid completion event.
- **Least-loaded routing:** available here, not in APIM, because the dispatcher reads its own
  Redis counters. DI publishes no remaining-quota headers.

## Infra still to add

Service Bus Premium namespace (private endpoint), per-tenant queues from `di_tenants`,
AKS with Workload Identity, Event Grid topic, tenant result storage, and a Redis instance
separate from the APIM external cache.
