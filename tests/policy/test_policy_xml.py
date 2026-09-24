"""Static checks that tie the policy XML to the Terraform and to ticket.py."""

import re
import xml.dom.minidom
from pathlib import Path

import pytest

from ticket import OPERATION_LOCATION_RE

ROOT = Path(__file__).resolve().parents[2]
POLICIES = ROOT / "apim" / "policies"
NAMED_VALUES_TF = ROOT / "infra" / "terraform" / "modules" / "di-gateway" / "named_values.tf"
POLICY_FILES = ["api-di-v1.xml", "op-analyze.xml", "op-result.xml"]


def read(name: str) -> str:
    return (POLICIES / name).read_text()


@pytest.mark.parametrize("name", POLICY_FILES)
def test_policy_is_well_formed(name):
    xml.dom.minidom.parseString(read(name))


def test_every_referenced_named_value_is_created_by_terraform():
    referenced = set()
    for name in POLICY_FILES:
        referenced |= set(re.findall(r"\{\{([a-z0-9-]+)\}\}", read(name)))
    tf = NAMED_VALUES_TF.read_text()
    created = set(re.findall(r'name\s*=\s*"([a-z0-9-]+)"', tf))
    created |= set(re.findall(r'^\s*"([a-z0-9-]+)"\s*=\s*(?:tostring\()?var\.', tf, re.M))
    missing = referenced - created
    assert not missing, f"Policies reference named values Terraform does not create: {sorted(missing)}"


def test_map_named_values_are_base64_decoded():
    # Terraform stores both maps base64-encoded (named_values.tf).
    assert 'Convert.FromBase64String(&quot;{{tenant-cell-map}}&quot;)' in read("api-di-v1.xml")
    assert 'Convert.FromBase64String(&quot;{{di-host-map}}&quot;)' in read("op-analyze.xml")
    assert "base64encode(jsonencode(local.tenant_cell_map))" in NAMED_VALUES_TF.read_text()
    assert "base64encode(jsonencode(local.di_host_map))" in NAMED_VALUES_TF.read_text()


def test_ticket_building_blocks_match_python_port():
    analyze = read("op-analyze.xml")
    result = read("op-result.xml")
    assert f"&quot;{OPERATION_LOCATION_RE}&quot;" in analyze
    assert "string.Join(&quot;|&quot;, key, m.Groups[1].Value, m.Groups[2].Value, (string)context.Variables[&quot;tenant&quot;])" in analyze
    url_safe = ".TrimEnd('=').Replace('+','-').Replace('/','_')"
    assert url_safe in analyze and url_safe in result
    assert "new HMACSHA256(Convert.FromBase64String(" in analyze and "new HMACSHA256(Convert.FromBase64String(" in result
    assert "{{result-signing-key-prev}}" in result
    assert "f.Length != 4 || f[3] != (string)context.Variables[&quot;tenant&quot;]" in result


def test_result_operation_is_pinned_and_not_retried():
    result = read("op-result.xml")
    assert "<retry" not in result
    assert "pool-" not in result
    assert 'set-backend-service backend-id="@((string)context.Variables[&quot;rBackend&quot;])"' in result


def test_capacity_routing_matches_python_port():
    analyze = read("op-analyze.xml")
    # Limits: floor(tps * pct / 100), tenant share at least 1.
    assert analyze.count("(int)Math.Floor((double)c[&quot;tps&quot;] * {{overflow-threshold-pct}} / 100.0)") == 2
    assert "Math.Max(1, (int)Math.Floor((double)c[&quot;tps&quot;] * {{overflow-tenant-share-pct}} / 100.0))" in analyze
    # Spill only for overflow-enabled tenants with a zone overflow pool, at or above the home limit.
    assert ("(bool)context.Variables[&quot;overflow&quot;] &amp;&amp; (int)context.Variables[&quot;ovfLimit&quot;] &gt; 0 &amp;&amp; "
            "Convert.ToInt32(context.Variables[&quot;homeCount&quot;]) &gt;= (int)context.Variables[&quot;homeLimit&quot;]") in analyze
    # ...and only while the overflow pool and the tenant's share of it are below their limits.
    assert ("Convert.ToInt32(context.Variables[&quot;ovfCount&quot;]) &lt; (int)context.Variables[&quot;ovfLimit&quot;] &amp;&amp; "
            "Convert.ToInt32(context.Variables[&quot;tenantOvfCount&quot;]) &lt; (int)context.Variables[&quot;tenantOvfLimit&quot;]") in analyze
    # Never rejects on pool capacity: no return-response between routing and set-backend-service.
    routing = analyze[analyze.index("Capacity-based routing"):analyze.index("</inbound>")]
    assert "return-response" not in routing
    # Counters live in the shared external cache.
    assert routing.count('caching-type="external"') == 6


def test_capacity_map_keys_match_terraform():
    locals_tf = (ROOT / "infra" / "terraform" / "modules" / "di-gateway" / "locals.tf").read_text()
    assert '{ for cell, c in var.di_cells : cell => { tps = sum([for m in c.members : m.tps]) } }' in locals_tf
    assert '{ for zone, m in var.di_overflow : "overflow-${zone}" => { tps = sum([for x in m : x.tps]) } }' in locals_tf
    analyze = read("op-analyze.xml")
    assert "[&quot;overflow-&quot; + (string)context.Variables[&quot;zone&quot;]]" in analyze


def test_overflow_pool_names_match_terraform():
    analyze = read("op-analyze.xml")
    assert '<set-variable name="ovfPool" value="@(&quot;pool-overflow-&quot; + (string)context.Variables[&quot;zone&quot;])" />' in analyze
    assert '<set-variable name="homePool" value="@(&quot;pool-&quot; + (string)context.Variables[&quot;cell&quot;])" />' in analyze
    pools_tf = (ROOT / "infra" / "terraform" / "modules" / "di-gateway" / "apim_pools.tf").read_text()
    assert 'name      = "pool-overflow-${each.key}"' in pools_tf
    assert 'name      = "pool-${each.key}"' in pools_tf
