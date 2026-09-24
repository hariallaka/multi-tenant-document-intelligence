"""Python port of the capacity-based routing in apim/policies/op-analyze.xml.

Keep in lock-step with the policy; test_policy_xml.py pins the shared expressions.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Decision:
    route: str        # pool for attempts 1 and 2
    alt_route: str    # pool for attempt 3
    spilled: bool


def limit(cap_map: dict, key: str, pct: int, floor_one: bool = False) -> Optional[int]:
    entry = cap_map.get(key)
    if entry is None:
        return None
    n = math.floor(entry["tps"] * pct / 100.0)
    return max(1, n) if floor_one else n


def route(*, cell: str, zone: str, overflow: bool, cap_map: dict, threshold_pct: int,
          tenant_share_pct: int, home_count: int, ovf_count: int, tenant_ovf_count: int) -> Decision:
    home_pool = f"pool-{cell}"
    ovf_pool = f"pool-overflow-{zone}"
    home_limit = limit(cap_map, cell, threshold_pct)
    home_limit = 2**31 - 1 if home_limit is None else home_limit
    ovf_limit = limit(cap_map, f"overflow-{zone}", threshold_pct) or 0
    tenant_ovf_limit = limit(cap_map, f"overflow-{zone}", tenant_share_pct, floor_one=True) or 0

    spill = overflow and ovf_limit > 0 and home_count >= home_limit
    if spill:
        spill = ovf_count < ovf_limit and tenant_ovf_count < tenant_ovf_limit
    if spill:
        return Decision(ovf_pool, home_pool, True)
    alt = ovf_pool if overflow and ovf_limit > 0 else home_pool
    return Decision(home_pool, alt, False)
