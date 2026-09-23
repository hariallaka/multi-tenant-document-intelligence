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
    created |= set(re.findall(r'^\s*"([a-z0-9-]+)"\s*=\s*var\.', tf, re.M))
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


def test_overflow_pool_names_match_terraform():
    analyze = read("op-analyze.xml")
    assert "&quot;pool-overflow-&quot; + (string)JObject.Parse((string)context.Variables[&quot;tenantCfg&quot;])[&quot;zone&quot;]" in analyze
    pools_tf = (ROOT / "infra" / "terraform" / "modules" / "di-gateway" / "apim_pools.tf").read_text()
    assert 'name      = "pool-overflow-${each.key}"' in pools_tf
    assert 'name      = "pool-${each.key}"' in pools_tf
