
# Purpose and scope

Shared Document Intelligence (DI) will run behind one APIM gateway that routes each tenant to a home cell of DI resources, spills to a capped, zone-specific overflow pool only when the cell is saturated, and admits traffic against per-tenant budgets so 429s are prevented rather than retried. Scope is Standard (S0), API v4.0, prod and nonprod, all zones.

This design extends the team's "Multi-Tenant Shared Landing Zone Design". That document is sound on TPS-based sizing, Dedicated-by-default for Restricted, and never exposing raw DI endpoints to tenants. It left four things open, which this doc closes:

| Requirement | Where it is solved |
| --- | --- |
| Prevent 429 errors | Admission control, per-tenant limits, dispatcher-owned polling |
| Noisy tenant must not affect others; failover on throttling | Per-tenant bulkheads, circuit breakers, capped zone-specific overflow |
| Route the first request to a suitable resource, not one resource | Capacity-weighted cell placement + weighted pools |
| Other best practices | Result affinity, model replication, security, observability, capacity budget |

# Verified limits and corrections

The original document's numbers match Microsoft Learn (page updated 9 Sep 2026); six design points need correcting. Source: [Service quotas and limits](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/service-limits?view=doc-intel-4.0.0).

| Quota (S0) | Default | Adjustable |
| --- | --- | --- |
| Analyze (POST) per second | 15 | Yes, via support ticket |
| Get-result (GET) per second | 50 | Yes, via support ticket |
| Model management per second | 5 | Yes |
| List operations per second | 10 | Yes |
| DI resources per region | 20 | No |
| Max document size | 500 MB | No |
| Max pages per analyze | 2,000 | No |
| Neural / Template models per resource | 500 / 5,000 | No |

**Corrections to the original design**

1. **Async affinity is missing.** POST returns an `Operation-Location` on the resource that accepted the job; every GET must return to that resource. Round-robin polling fails. APIM's pool session affinity is cookie-based and unsuitable for SDK or batch clients.
2. **GET can bind before POST.** In-flight jobs = POST rate × processing time. At 12 POST/s and 10 s processing, 120 jobs polled every 2 s = 60 GET/s, above the 50 default.
3. **Size on peaks, not averages.** Learn's own example: a jump from 10 to 40 TPS returns 429s against a 15 TPS limit.
4. **Retry-After is documented on the analyze response** (wait before polling), not guaranteed on every 429. Circuit breakers need a fallback trip duration.
5. **"Per subscription" is unconfirmed.** Learn says 20 per region; confirm the subscription scope with Microsoft before sharding across subscriptions.
6. **Custom models block failover** unless the same model ID exists on every pool member. A model-copy pipeline is required.

TPS increases are approved on demonstrated usage and practices; treat them as upside, not baseline.

# Target architecture

Tenants never call DI; they call an internal APIM gateway (sync path) or drop work on Service Bus (batch path), and both reach DI only through budgeted, per-cell backend pools.

**Request flow**

1. Tenant apps authenticate with an Entra token per tenant and call the APIM gateway (internal, private endpoint), or submit batch work to a Service Bus queue per tenant.
2. The dispatcher on AKS drains queues with a fair scheduler and Redis token buckets, and calls the gateway on the tenant's behalf.
3. The gateway routes to the tenant's home cell pool (Cell A, Cell B, …).
4. Only when the home cell is exhausted, the gateway routes to the overflow pool for the tenant's zone (General or Confidential), within a per-tenant cap.
5. On the batch path, the dispatcher polls for results and writes them to tenant result storage, then notifies via Event Grid.

A cell is 2–3 DI resources in one APIM pool with weighted round-robin; each zone (General, Confidential) has its own overflow pool, reached only from the Analyze retry path when the tenant's cell is exhausted; Restricted has no overflow.

| Component | Role | Isolation it provides |
| --- | --- | --- |
| APIM (Premium or v2, internal) | Auth, per-tenant limits, cell routing, 429/503 normalisation, `Operation-Location` rewrite | Tenant never holds a DI credential or DI operation ID |
| Service Bus (queue or session per tenant) | Load-levels batch work | A tenant's backlog delays only that tenant |
| Dispatcher (AKS, Workload Identity) | Weighted fair scheduling; token bucket per DI resource at 80% of TPS; owns polling | Nothing reaches DI without a token; GET budget controlled |
| Redis | Shared token buckets and overflow counters | Consistent limits across dispatcher replicas |
| DI cells (S0) | Analysis | Blast radius of a hot tenant = its home cell + its overflow cap |
| Zone overflow pools | Burst absorption per zone | General and Confidential never share overflow capacity |
| Dedicated DI | Restricted / model-confidential / promoted tenants | Full resource boundary |

# Routing: placement and first-request distribution

Every request is spread across a whole cell from the first call; which cell is decided once, at onboarding, by committed peak TPS.

**Placement (control plane, at onboarding)**

1. The tenant declares peak Analyze TPS, average pages per document and model type (prebuilt or custom) in the onboarding config.
2. The placement step picks the cell in the tenant's (environment, zone) where the sum of committed peaks stays at or below 80% of cell Analyze TPS, and projected in-flight GET load stays at or below 80% of cell GET TPS.
3. No cell fits → create a cell (if the regional 20-resource budget allows) or promote the tenant to Dedicated.
4. The mapping `tenantId → cellId, tier` lands in DeployEz config and is rendered into APIM as the `tenant-cell-map` named value (JSON), with the tenant's zone derived from its cell. Changes deploy through the pipeline, never by hand.

Capacity-weighted placement is chosen over consistent hashing because hashing ignores tenant size, and the fixed 20-resource cap makes later rebalancing disruptive.

**Distribution (data plane, per request)**

- Each cell is an APIM backend pool; members share load by weight, so no single resource takes all first requests.
- Weights reflect each member's approved TPS (for example, 3 for a member raised to 45 TPS, 1 for a 15 TPS member).
- Pools hold up to 30 backends; balancing is approximate because gateway units don't synchronise. Source: [APIM backends](https://learn.microsoft.com/en-us/azure/api-management/backends).
- DI publishes no remaining-quota response headers, so true least-loaded routing is only available on the batch path, where the dispatcher reads its own Redis token counters.

| Cell design parameter | Starting value | Reason |
| --- | --- | --- |
| Members per cell | 2–3 | Survives one member tripped without spilling |
| Admission budget | 80% of summed TPS | Headroom for bursts and approximate balancing |
| Tenants per cell | Until budget is committed | Sized on peaks, not averages |
| Overflow share per tenant | ≤ 25% of one overflow member | Stops a hot tenant flooding its zone's overflow |

# 429 prevention

429s are prevented by admitting no more work than each resource can take; retries and failover are the second line, not the first.

| Layer | Control | Sized against |
| --- | --- | --- |
| Gateway, per tenant | `rate-limit-by-key` on the token's tenant claim, per product tier | Tenant's committed peak Analyze TPS |
| Gateway, per tenant | `quota-by-key` daily call cap | Tenant's contracted volume |
| Gateway, per request | Size, content-type and `pages` validation | 500 MB, 2,000 pages |
| Dispatcher, per resource | Token bucket in Redis | 80% of resource Analyze TPS |
| Dispatcher, per resource | GET bucket, polling with Retry-After then 2-5-13-34 s backoff | 80% of resource GET TPS |
| Platform | TPS-increase tickets with load-test evidence | Cells forecast to run hot |

**GET budget formula** — check this per resource, it is often the binding limit:

GET/s = (POST/s × average processing time in s) ÷ poll interval in s, which must stay ≤ 0.8 × 50.

**Rules for tenants**

- Interactive, small documents → sync API; bulk or large documents → batch queue.
- Large files are staged in Blob and sent as `urlSource`, not uploaded through the gateway.
- Tenants poll APIM's rewritten result URL no more than once every 2 s, or subscribe to the Event Grid completion event (batch path). Learn recommends polling no more than once per 2 s per POST.
- Ramp load gradually; step changes cause 429s even when the average is within limits.

# Noisy-neighbour containment and failover

A noisy tenant is stopped by its own limit first; only traffic already within its limit is allowed to fail over, and its use of its zone's overflow is capped.

**Failover sequence**

1. Tenant sends POST analyze to APIM.
2. APIM checks the tenant's rate limit.
3. APIM forwards to a member of the tenant's cell pool (for example DI A1).
4. A1 returns 429; its circuit breaker trips.
5. APIM retries once into the same pool; the pool skips A1 and picks A2.
6. A2 returns 202 + `Operation-Location`; APIM returns 202 + a rewritten, signed result URL.
7. If the whole cell is exhausted, the final retry goes to the overflow pool for the tenant's zone, within the tenant's overflow cap.

**Mechanics**

- Each DI backend has one circuit-breaker rule: status 429 and 500–503, count 1 in 10 s, trip 10 s, `acceptRetryAfter: true`.
- The API's `<backend>` section retries on 429/503; the pool pick skips tripped members, so the retry lands elsewhere.
- Overflow is zone-specific (pool-overflow-general, pool-overflow-confidential) and is used only on the final retry when the tenant's cell is exhausted; General and Confidential tenants never share overflow capacity.
- A second, lower per-tenant limit applies when the chosen backend is an overflow member (overflow cap).
- When every member is tripped, the gateway returns 429 with `Retry-After` (APIM's own breaker response is 503; it is rewritten).

**Why the order matters**

Failover without per-tenant limits spreads a hot tenant across every member and then into overflow, throttling every tenant. Limits first, then failover, then capped overflow.

**Retry discipline**

- The gateway retries at most twice. Clients must not retry on 503/429 without honouring `Retry-After`.
- The circuit breaker is approximate across gateway units and unsupported on the Consumption tier; one rule per backend. Load-test that the retry actually lands on a different member.

# Async result affinity and ownership

The gateway replaces DI's `Operation-Location` with a signed APIM URL that pins the GET to the accepting resource and to the submitting tenant; GETs never fail over.

| Step | What happens |
| --- | --- |
| POST accepted | DI returns 202 + `https://<di-host>/documentintelligence/documentModels/{model}/analyzeResults/{resultId}` |
| Outbound rewrite | APIM builds ticket = base64url of backendKey, model, resultId and tenant (joined with a vertical bar), plus an HMAC-SHA256 signature using named value result-signing-key |
| Tenant receives | `https://<apim-host>/di/v1/results/{ticket}.{sig}` |
| GET arrives | APIM verifies signature, checks ticket tenant = token tenant, then `set-backend-service` to the single backend `backendKey` (not the pool) |
| Mismatch | 404, so no signal that another tenant's result exists |

This is stateless (no cache or DB lookup) and closes the original document's concern that DI operation IDs are resource-scoped, not tenant-scoped. On the batch path the dispatcher polls, so tenants never see a result URL at all.

**Rules**

- The GET operation uses a single backend entity per DI resource, with no retry and no pool.
- Rotate `result-signing-key` with overlap: accept the previous key for 24 h.
- Backend keys are stable names (`di-prod-gen-a1`), never hostnames, so resources can be replaced without breaking in-flight tickets.

# APIM policy set

Three policies implement the design: an API-level policy (identity, tenant resolution, 429 normalisation), the Analyze operation (limits, cell routing, failover, result-URL signing) and the Result operation (ticket verification, pinned backend, 2 s polling floor). This is a reference implementation; validate it in nonprod against the checks listed at the end of this section.

**API design** — API `di-v1`, path `/di/v1`, internal gateway only.

| Operation | Method and template | Backend |
| --- | --- | --- |
| Analyze | POST `/documentModels/{modelId}/analyze` | Tenant's cell pool, zone overflow on exhaustion |
| Result | GET `/results/{ticket}` | The single DI backend named in the ticket |

**Named values** (rendered by DeployEz from config; secrets are Key Vault references)

| Name | Content |
| --- | --- |
| `entra-tenant-id` | Entra directory ID |
| `di-gateway-audience` | App ID URI of the gateway app registration |
| `dispatcher-app-id` | Client ID of the batch dispatcher's workload identity |
| `gateway-host` | Host tenants call, e.g. `di.internal.example` |
| `tenant-cell-map` | JSON: tenant client ID → cell, tier, overflow flag, model prefix, zone (rendered from the cell) |
| `di-host-map` | JSON: DI hostname → backend key |
| `result-signing-key`, `result-signing-key-prev` | Key Vault secrets, base64, rotated with overlap |

Example `tenant-cell-map`:

```json
{
  "3f1c0d8e-0000-0000-0000-000000000001": { "cell": "prod-gen-a", "tier": "standard", "overflow": true,  "modelPrefix": "t001-", "zone": "general" },
  "3f1c0d8e-0000-0000-0000-000000000002": { "cell": "prod-gen-b", "tier": "gold",     "overflow": true,  "modelPrefix": "t002-", "zone": "general" },
  "3f1c0d8e-0000-0000-0000-000000000003": { "cell": "prod-conf-a", "tier": "standard", "overflow": false, "modelPrefix": "t003-", "zone": "confidential" }
}
```

## 1. API-level policy (all operations)

```xml
<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="{{entra-tenant-id}}" output-token-variable-name="jwt"
                             failed-validation-httpcode="401">
      <audiences><audience>{{di-gateway-audience}}</audience></audiences>
    </validate-azure-ad-token>

    <!-- Caller identity: v2 tokens carry azp, v1 carry appid. Never trust a client header for tenant. -->
    <set-variable name="caller" value="@{
        var jwt = (Jwt)context.Variables[&quot;jwt&quot;];
        return jwt.Claims.GetValueOrDefault(&quot;azp&quot;, jwt.Claims.GetValueOrDefault(&quot;appid&quot;, &quot;&quot;));
    }" />

    <!-- Only the platform dispatcher may act on behalf of a tenant (batch path). -->
    <set-variable name="tenant" value="@{
        var caller = (string)context.Variables[&quot;caller&quot;];
        if (caller == &quot;{{dispatcher-app-id}}&quot;)
            return context.Request.Headers.GetValueOrDefault(&quot;x-daas-tenant&quot;, &quot;&quot;);
        return caller;
    }" />

    <set-variable name="tenantMap" value="{{tenant-cell-map}}" />
    <set-variable name="tenantCfg" value="@{
        var map = JObject.Parse((string)context.Variables[&quot;tenantMap&quot;]);
        var cfg = map[(string)context.Variables[&quot;tenant&quot;]];
        return cfg == null ? &quot;&quot; : cfg.ToString(Newtonsoft.Json.Formatting.None);
    }" />
    <choose>
      <when condition="@(string.IsNullOrEmpty((string)context.Variables[&quot;tenantCfg&quot;]))">
        <return-response>
          <set-status code="403" reason="Tenant not onboarded" />
        </return-response>
      </when>
    </choose>

    <!-- Gateway authenticates to DI with its managed identity; tenant tokens never reach DI. -->
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <set-header name="x-daas-tenant" exists-action="delete" />
    <set-query-parameter name="api-version" exists-action="override">
      <value>2024-11-30</value>
    </set-query-parameter>
  </inbound>

  <backend>
    <base />
  </backend>

  <outbound>
    <base />
    <!-- One contract for tenants: throttling and breaker exhaustion both surface as 429 + Retry-After. -->
    <choose>
      <when condition="@(context.Response.StatusCode == 429 || context.Response.StatusCode == 503)">
        <set-status code="429" reason="Too Many Requests" />
        <set-header name="Retry-After" exists-action="skip">
          <value>10</value>
        </set-header>
      </when>
    </choose>
    <set-header name="x-daas-tenant" exists-action="override">
      <value>@((string)context.Variables[&quot;tenant&quot;])</value>
    </set-header>
  </outbound>

  <on-error>
    <base />
    <choose>
      <when condition="@(context.LastError.Source == &quot;rate-limit-by-key&quot; || context.LastError.Source == &quot;forward-request&quot;)">
        <return-response>
          <set-status code="429" reason="Too Many Requests" />
          <set-header name="Retry-After" exists-action="override"><value>10</value></set-header>
        </return-response>
      </when>
    </choose>
  </on-error>
</policies>
```

## 2. Analyze operation (POST /documentModels/{modelId}/analyze)

```xml
<policies>
  <inbound>
    <base />
    <set-variable name="cell"      value="@((string)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;cell&quot;])" />
    <set-variable name="tier"      value="@((string)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;tier&quot;])" />
    <set-variable name="overflow"  value="@((bool)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;overflow&quot;])" />
    <set-variable name="modelId"   value="@(context.Request.MatchedParameters[&quot;modelId&quot;])" />

    <!-- Model allowlist: prebuilt models, or custom models carrying this tenant's prefix. -->
    <choose>
      <when condition="@{
          var m = (string)context.Variables[&quot;modelId&quot;];
          var p = (string)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;modelPrefix&quot;];
          return !(m.StartsWith(&quot;prebuilt-&quot;) || (!string.IsNullOrEmpty(p) &amp;&amp; m.StartsWith(p)));
      }">
        <return-response><set-status code="403" reason="Model not permitted for tenant" /></return-response>
      </when>
    </choose>

    <!-- Inline uploads capped at 50 MB; larger documents must use urlSource from staged Blob. -->
    <choose>
      <when condition="@(long.Parse(context.Request.Headers.GetValueOrDefault(&quot;Content-Length&quot;, &quot;0&quot;)) &gt; 52428800)">
        <return-response><set-status code="413" reason="Use urlSource for documents over 50 MB" /></return-response>
      </when>
    </choose>

    <!-- Per-tenant admission: 5 s sliding window allows short bursts while holding the average. -->
    <choose>
      <when condition="@((string)context.Variables[&quot;tier&quot;] == &quot;gold&quot;)">
        <rate-limit-by-key calls="30" renewal-period="5"
                           counter-key="@(&quot;an:&quot; + (string)context.Variables[&quot;tenant&quot;])"
                           retry-after-header-name="Retry-After" />
      </when>
      <otherwise>
        <rate-limit-by-key calls="10" renewal-period="5"
                           counter-key="@(&quot;an:&quot; + (string)context.Variables[&quot;tenant&quot;])"
                           retry-after-header-name="Retry-After" />
      </otherwise>
    </choose>
    <quota-by-key calls="200000" renewal-period="86400"
                  counter-key="@(&quot;q:&quot; + (string)context.Variables[&quot;tenant&quot;])" />

    <rewrite-uri template="@(&quot;/documentModels/&quot; + (string)context.Variables[&quot;modelId&quot;] + &quot;:analyze&quot;)" copy-unmatched-params="true" />
    <set-backend-service backend-id="@(&quot;pool-&quot; + (string)context.Variables[&quot;cell&quot;])" />
  </inbound>

  <backend>
    <!-- Attempt 1: cell pool. Attempt 2: cell pool again (skips tripped member).
         Attempt 3: the tenant's ZONE overflow pool, only if allowed and within its overflow cap. -->
    <retry condition="@(context.Response == null || context.Response.StatusCode == 429 || context.Response.StatusCode == 503)"
           count="2" interval="0" first-fast-retry="true">
      <choose>
        <when condition="@(context.Variables.ContainsKey(&quot;attempt&quot;) &amp;&amp; (int)context.Variables[&quot;attempt&quot;] &gt;= 1 &amp;&amp; (bool)context.Variables[&quot;overflow&quot;])">
          <cache-lookup-value key="@(&quot;ovf:&quot; + (string)context.Variables[&quot;tenant&quot;] + &quot;:&quot; + (DateTime.UtcNow.Ticks / TimeSpan.TicksPerSecond / 10))"
                              variable-name="ovfCount" caching-type="external" />
          <choose>
            <when condition="@((int)context.Variables.GetValueOrDefault(&quot;ovfCount&quot;, 0) &lt; 30)">
              <cache-store-value key="@(&quot;ovf:&quot; + (string)context.Variables[&quot;tenant&quot;] + &quot;:&quot; + (DateTime.UtcNow.Ticks / TimeSpan.TicksPerSecond / 10))"
                                 value="@((int)context.Variables.GetValueOrDefault(&quot;ovfCount&quot;, 0) + 1)"
                                 duration="20" caching-type="external" />
              <set-backend-service backend-id="@(&quot;pool-overflow-&quot; + (string)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;zone&quot;])" />
            </when>
          </choose>
        </when>
      </choose>
      <set-variable name="attempt" value="@(context.Variables.ContainsKey(&quot;attempt&quot;) ? (int)context.Variables[&quot;attempt&quot;] + 1 : 0)" />
      <forward-request buffer-request-body="true" timeout="60" />
    </retry>
  </backend>

  <outbound>
    <base />
    <!-- Replace DI's Operation-Location with a signed, tenant-bound gateway URL. -->
    <choose>
      <when condition="@(context.Response.StatusCode == 202)">
        <set-variable name="hostMap" value="{{di-host-map}}" />
        <set-header name="Operation-Location" exists-action="override">
          <value>@{
            var op   = new Uri(context.Response.Headers.GetValueOrDefault(&quot;Operation-Location&quot;, &quot;&quot;));
            var key  = (string)JObject.Parse((string)context.Variables[&quot;hostMap&quot;])[op.Host];
            var m    = Regex.Match(op.AbsolutePath, &quot;documentModels/([^/]+)/analyzeResults/([^/?]+)&quot;);
            var raw  = string.Join(&quot;|&quot;, key, m.Groups[1].Value, m.Groups[2].Value, (string)context.Variables[&quot;tenant&quot;]);
            var body = Convert.ToBase64String(Encoding.UTF8.GetBytes(raw)).TrimEnd('=').Replace('+','-').Replace('/','_');
            using (var h = new HMACSHA256(Convert.FromBase64String(&quot;{{result-signing-key}}&quot;))) {
              var sig = Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(body))).TrimEnd('=').Replace('+','-').Replace('/','_');
              return &quot;https://{{gateway-host}}/di/v1/results/&quot; + body + &quot;.&quot; + sig;
            }
          }</value>
        </set-header>
      </when>
    </choose>
  </outbound>

  <on-error>
    <base />
  </on-error>
</policies>
```

## 3. Result operation (GET /results/{ticket})

```xml
<policies>
  <inbound>
    <base />
    <!-- Verify signature (current or previous key) and tenant ownership; decode to backend|model|result|tenant. -->
    <set-variable name="ticket" value="@{
        var t = ((string)context.Request.MatchedParameters[&quot;ticket&quot;]).Split('.');
        if (t.Length != 2) return &quot;&quot;;
        Func&lt;string, string&gt; sign = k =&gt; {
            using (var h = new HMACSHA256(Convert.FromBase64String(k)))
                return Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(t[0]))).TrimEnd('=').Replace('+','-').Replace('/','_');
        };
        if (t[1] != sign(&quot;{{result-signing-key}}&quot;) &amp;&amp; t[1] != sign(&quot;{{result-signing-key-prev}}&quot;)) return &quot;&quot;;
        var b = t[0].Replace('-','+').Replace('_','/');
        b = b.PadRight(b.Length + (4 - b.Length % 4) % 4, '=');
        var f = Encoding.UTF8.GetString(Convert.FromBase64String(b)).Split('|');
        if (f.Length != 4 || f[3] != (string)context.Variables[&quot;tenant&quot;]) return &quot;&quot;;
        return string.Join(&quot;|&quot;, f);
    }" />
    <choose>
      <when condition="@(string.IsNullOrEmpty((string)context.Variables[&quot;ticket&quot;]))">
        <return-response><set-status code="404" reason="Not Found" /></return-response>
      </when>
    </choose>
    <set-variable name="rBackend" value="@(((string)context.Variables[&quot;ticket&quot;]).Split('|')[0])" />
    <set-variable name="rModel"   value="@(((string)context.Variables[&quot;ticket&quot;]).Split('|')[1])" />
    <set-variable name="rResult"  value="@(((string)context.Variables[&quot;ticket&quot;]).Split('|')[2])" />

    <!-- Polling floor: one GET per result every 2 s protects the resource's 50 GET/s budget. -->
    <rate-limit-by-key calls="1" renewal-period="2"
                       counter-key="@(&quot;poll:&quot; + (string)context.Variables[&quot;rResult&quot;])"
                       retry-after-header-name="Retry-After" />

    <rewrite-uri template="@(&quot;/documentModels/&quot; + (string)context.Variables[&quot;rModel&quot;] + &quot;/analyzeResults/&quot; + (string)context.Variables[&quot;rResult&quot;])" copy-unmatched-params="false" />
    <!-- Pinned to the accepting resource. No pool, no retry, no failover. -->
    <set-backend-service backend-id="@((string)context.Variables[&quot;rBackend&quot;])" />
  </inbound>
  <backend>
    <forward-request timeout="30" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

**Validate in nonprod before rollout**

- [ ] How your APIM tier surfaces a fully tripped pool (a 503 `context.Response`, or an error routed to `on-error`); adjust the retry condition and `on-error` source check to match.
- [ ] The retried `forward-request` lands on a different pool member after a 429 (log `context.Backend` and the DI host per attempt).
- [ ] `HMACSHA256`, `Regex` and `Func` are accepted by your tier's policy-expression allowlist.
- [ ] External cache (Azure Cache for Redis) is attached to APIM; the overflow counter is approximate and non-atomic by design.
- [ ] `buffer-request-body` memory on the 50 MB inline cap under concurrent load.
- [ ] `rate-limit-by-key` counter accuracy across your gateway unit count; keep the 80% margin.

# Terraform: DI resources, backends and pools

One config map drives everything: DI accounts, private endpoints, RBAC, APIM backends with circuit breakers, one pool per cell plus one overflow pool per zone, and the named values the policies read. It slots into the DeployEz config layer; backends and pools use `azapi` because pool and circuit-breaker properties are set through the `Microsoft.ApiManagement/service/backends` ARM schema.

## Config (DeployEz layer)

```hcl
# config/prod/di.auto.tfvars
di_cells = {
  "prod-gen-a" = {
    zone    = "general"
    members = {
      "di-prod-gen-a1" = { weight = 1 }
      "di-prod-gen-a2" = { weight = 1 }
    }
  }
  "prod-gen-b" = {
    zone    = "general"
    members = {
      "di-prod-gen-b1" = { weight = 3 }   # TPS raised to 45 via support ticket
      "di-prod-gen-b2" = { weight = 1 }
    }
  }
}

di_overflow = {
  general = {
    "di-prod-ovf-gen-1" = { weight = 1 }
    "di-prod-ovf-gen-2" = { weight = 1 }
  }
  confidential = {
    "di-prod-ovf-conf-1" = { weight = 1 }
  }
}

di_tenants = {
  "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "prod-gen-a", tier = "standard", overflow = true, modelPrefix = "t001-" }
  "3f1c0d8e-0000-0000-0000-000000000002" = { cell = "prod-gen-b", tier = "gold",     overflow = true, modelPrefix = "t002-" }
}
```

## Variables and locals

```hcl
variable "di_cells" {
  type = map(object({
    zone    = string
    members = map(object({ weight = number }))
  }))
}
variable "di_overflow"      { type = map(map(object({ weight = number }))) }   # zone => members
variable "di_tenants"       { type = map(object({ cell = string, tier = string, overflow = bool, modelPrefix = string })) }
variable "location"         { type = string }
variable "rg_name"          { type = string }
variable "pe_subnet_id"     { type = string }
variable "dns_zone_id"      { type = string }   # privatelink.cognitiveservices.azure.com
variable "apim_id"          { type = string }
variable "apim_name"        { type = string }
variable "apim_principal_id"{ type = string }
variable "signing_secret_id"      { type = string }   # Key Vault versionless secret ID
variable "signing_secret_prev_id" { type = string }

locals {
  cell_members = merge([
    for cell, c in var.di_cells : {
      for name, m in c.members : name => { cell = cell, weight = m.weight }
    }
  ]...)
  overflow_members = merge([
    for zone, members in var.di_overflow : {
      for name, m in members : name => { cell = "overflow-${zone}", weight = m.weight }
    }
  ]...)
  all_members      = merge(local.cell_members, local.overflow_members)
}
```

## DI accounts, private endpoints, RBAC

```hcl
resource "azurerm_cognitive_account" "di" {
  for_each                      = local.all_members
  name                          = each.key
  location                      = var.location
  resource_group_name           = var.rg_name
  kind                          = "FormRecognizer"
  sku_name                      = "S0"
  custom_subdomain_name         = each.key          # required for Entra auth and private endpoint
  local_auth_enabled            = false             # keys disabled; also enforce via Azure Policy
  public_network_access_enabled = false

  identity { type = "SystemAssigned" }              # for urlSource reads from staged Blob

  network_acls { default_action = "Deny" }

  tags = { cell = each.value.cell, platform = "daas-di" }
}

resource "azurerm_private_endpoint" "di" {
  for_each            = local.all_members
  name                = "pe-${each.key}"
  location            = var.location
  resource_group_name = var.rg_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_cognitive_account.di[each.key].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

resource "azurerm_role_assignment" "apim_di" {
  for_each             = local.all_members
  scope                = azurerm_cognitive_account.di[each.key].id
  role_definition_name = "Cognitive Services User"   # consider a custom analyze-only role
  principal_id         = var.apim_principal_id
}
```

## APIM backends with circuit breakers

```hcl
resource "azapi_resource" "di_backend" {
  for_each  = local.all_members
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name      = each.key
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI ${each.key} (cell ${each.value.cell})"
      type        = "Single"
      protocol    = "http"
      url         = "https://${each.key}.cognitiveservices.azure.com/documentintelligence"
      tls         = { validateCertificateChain = true, validateCertificateName = true }
      circuitBreaker = {
        rules = [{
          name = "throttle-or-fault"
          failureCondition = {
            count    = 1
            interval = "PT10S"
            statusCodeRanges = [
              { min = 429, max = 429 },
              { min = 500, max = 503 }
            ]
          }
          tripDuration     = "PT10S"   # fallback when DI sends no Retry-After
          acceptRetryAfter = true
        }]
      }
    }
  }

  depends_on = [azurerm_private_endpoint.di]
}
```

## Pools: one per cell, plus one overflow pool per zone

```hcl
resource "azapi_resource" "cell_pool" {
  for_each  = var.di_cells
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name      = "pool-${each.key}"
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI cell ${each.key} (${each.value.zone})"
      type        = "Pool"
      pool = {
        services = [
          for name, m in each.value.members : {
            id       = azapi_resource.di_backend[name].id
            priority = 1
            weight   = m.weight
          }
        ]
      }
    }
  }
}

resource "azapi_resource" "overflow_pool" {
  for_each  = var.di_overflow   # one pool per zone
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  name      = "pool-overflow-${each.key}"
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI ${each.key} overflow, reached only from the Analyze retry path"
      type        = "Pool"
      pool = {
        services = [
          for name, m in each.value : {
            id       = azapi_resource.di_backend[name].id
            priority = 1
            weight   = m.weight
          }
        ]
      }
    }
  }
}
```

## Named values the policies read

```hcl
resource "azurerm_api_management_named_value" "tenant_cell_map" {
  name                = "tenant-cell-map"
  api_management_name = var.apim_name
  resource_group_name = var.rg_name
  display_name        = "tenant-cell-map"
  value               = jsonencode({ for k, t in var.di_tenants : k => merge(t, { zone = var.di_cells[t.cell].zone }) })
}

resource "azurerm_api_management_named_value" "di_host_map" {
  name                = "di-host-map"
  api_management_name = var.apim_name
  resource_group_name = var.rg_name
  display_name        = "di-host-map"
  value = jsonencode({
    for name, _ in local.all_members : "${name}.cognitiveservices.azure.com" => name
  })
}

resource "azurerm_api_management_named_value" "signing" {
  for_each = {
    "result-signing-key"      = var.signing_secret_id
    "result-signing-key-prev" = var.signing_secret_prev_id
  }
  name                = each.key
  api_management_name = var.apim_name
  resource_group_name = var.rg_name
  display_name        = each.key
  secret              = true
  value_from_key_vault { secret_id = each.value }
}

# Guardrail: every tenant must point at a cell that exists.
check "tenant_cells_exist" {
  assert {
    condition     = alltrue([for t in var.di_tenants : contains(keys(var.di_cells), t.cell)])
    error_message = "A tenant in di_tenants references an undefined cell."
  }
}

# Guardrail: overflow-enabled tenants need an overflow pool in their own zone; Restricted never gets one.
check "tenant_overflow_zone" {
  assert {
    condition = alltrue([
      for t in var.di_tenants :
      !t.overflow || (contains(keys(var.di_overflow), var.di_cells[t.cell].zone) && var.di_cells[t.cell].zone != "restricted")
    ])
    error_message = "An overflow-enabled tenant has no overflow pool in its zone, or is in the Restricted zone."
  }
}
```

**Before applying**

- [ ] Pin the backends API version to the latest GA your `azapi` provider supports; confirm `circuitBreaker` and `pool` validate against it.
- [ ] Count `local.all_members` plus Dedicated resources per region against the 20-resource cap in a plan-time `check` block.
- [ ] Note that named values are size-limited; when `tenant-cell-map` grows large, move the map to the external cache and load it with `cache-lookup-value`.
- [ ] APIM needs outbound network line-of-sight to the DI private endpoints (VNet-injected Premium, or v2 with VNet integration) in the hub-spoke topology.

# Security, observability, capacity and testing

The gateway inherits the DaaS baseline (private endpoints only, NSP, Workload Identity Federation) and adds per-tenant attribution that DI itself cannot provide.

**Security controls**

| Control | Setting |
| --- | --- |
| DI authentication | `local_auth_enabled = false`, enforced by Azure Policy at management-group level |
| DI network | Public access disabled, private endpoint, NSP association |
| Gateway to DI | APIM managed identity; Cognitive Services User or a custom analyze-only role |
| Tenant to gateway | Entra token validated per request; tenant = token client ID, never a header |
| Batch path | Dispatcher on AKS with Workload Identity; only identity allowed to set `x-daas-tenant` |
| Model access | Allowlist: `prebuilt-*` or the tenant's own model prefix |
| Result isolation | HMAC-signed, tenant-bound result tickets; mismatch returns 404 |
| Overflow isolation | One overflow pool per zone; General and Confidential never share overflow resources |
| Restricted zone | Dedicated DI resources only; no overflow pool membership |

**Custom models**

- Every custom model is copied to all members of the tenant's cell (and its zone's overflow pool, if the tenant is overflow-enabled) with the DI model-copy API, under the same model ID.
- The model-promotion pipeline fails if any target member is missing the model; tenants whose models are not replicated get `overflow = false`.

**Observability** — DI logs carry no tenant field, so APIM supplies it.

| Signal | Source | Alert |
| --- | --- | --- |
| Requests, latency, status by tenant, backend, operation | APIM diagnostics to Log Analytics with `x-daas-tenant` | p95 latency per tenant per cell |
| 429 rate per DI resource | DI metrics | > 1% over 5 min |
| Circuit breaker trip / reset | APIM events to Event Grid | Any trip on a cell member |
| Overflow share by tenant and zone | APIM logs (backend = overflow pool) | Tenant > its overflow cap for 15 min → promotion review |
| GET/POST ratio and in-flight jobs per resource | DI metrics + dispatcher counters | GET > 80% of 50/s |

**Regional capacity budget (prod, one region, 20 resources)**

| Use | Resources |
| --- | --- |
| General cells (4 × 2) | 8 |
| Confidential cells (1 × 2) | 2 |
| Overflow (General 2, Confidential 1) | 3 |
| Restricted / Dedicated / promoted tenants | 6 |
| Reserve for growth and replacement | 1 |

Nonprod sits in its own subscription and budget. When the budget binds, add a second region (Australia East and Australia Southeast are the pair) after confirming model availability and data-residency approval.

**Load-test plan (nonprod, before go-live)**

1. Baseline: all tenants at committed peak; target zero 429s at DI.
2. Noisy tenant: one tenant at 5× its limit; others' p95 latency and 429 rate must stay flat.
3. Member loss: disable one member in a cell; traffic must shift within the trip window.
4. Cell exhaustion: saturate a General and a Confidential cell; each spills only to its own zone's overflow pool, only for overflow-enabled tenants, within caps.
5. Large documents: 2,000-page PDFs through the batch path; GET budget must hold.
6. Key rotation: rotate `result-signing-key` mid-test; in-flight tickets must still resolve.

# Risks and open decisions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Failover spreads a noisy tenant across the cell and overflow | Every tenant in the zone throttled | Per-tenant limits before failover; overflow cap per tenant |
| APIM breaker and balancing are approximate across gateway units | Some 429s leak through | 80% admission margin; single gateway region per cell |
| Retry storms (client + gateway retries) | Amplified load during incidents | Gateway retries at most twice; clients must honour Retry-After |
| GET bucket exhausted by large, slow documents | Result polling throttled | 2 s polling floor per result; batch path with dispatcher-owned polling |
| Custom model missing on a pool member | Failed analyze after failover | Replication gate in promotion pipeline; overflow off for unreplicated tenants |
| 20-resource regional cap | Growth blocked | Explicit per-region budget (reserve now 1 after Confidential overflow); promotion; second region |
| TPS increase not approved | Cell capacity below plan | Plan on 15/50 defaults; increases are upside |
| Tenant-cell map grows past named-value limits | Deploy failures | Move map to external cache when it grows |

**Open decisions**

- [ ] Confirm with Microsoft whether the 20-resource limit is per subscription per region or per region only.
- [ ] Confirm the APIM tier (Premium classic VNet-injected, or Premium v2) that fits the hub-spoke private-endpoint design.
- [ ] Decide whether AIzone shared pools are Dedicated-only.
- [x] Decide whether Confidential-zone tenants may use overflow: decided 23 Sep 2026 — yes, through a Confidential-only overflow pool; overflow is zone-specific and never shared across zones.
- [ ] Set per-tier limits (standard 2 TPS avg / gold 6 TPS avg in the reference policy) from onboarding data.
- [ ] Confirm DI result retention against audit requirements for Confidential and Restricted tenants.

# Sources

- [Document Intelligence service quotas and limits](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/service-limits?view=doc-intel-4.0.0) (updated 9 Sep 2026)
- [Backends in API Management: circuit breaker and load-balanced pools](https://learn.microsoft.com/en-us/azure/api-management/backends) (updated 20 May 2026)
- Team source document: Azure AI Document Intelligence — Multi-Tenant Shared Landing Zone Design (S0)
