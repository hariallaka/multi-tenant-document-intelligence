import pytest

from routing import route

CAP = {
    "prod-general": {"tps": 30},
    "prod-critical": {"tps": 45},
    "overflow-general": {"tps": 15},
    "overflow-critical": {"tps": 15},
}


def decide(**kw):
    args = dict(cell="prod-general", zone="general", overflow=True, cap_map=CAP, threshold_pct=90,
                tenant_share_pct=50, home_count=0, ovf_count=0, tenant_ovf_count=0)
    args.update(kw)
    return route(**args)


def test_below_threshold_uses_home_pool_with_overflow_as_last_retry():
    d = decide(home_count=26)  # 90% of 30 = 27
    assert (d.route, d.alt_route, d.spilled) == ("pool-prod-general", "pool-overflow-general", False)


def test_at_threshold_spills_to_zone_overflow():
    d = decide(home_count=27)
    assert (d.route, d.alt_route, d.spilled) == ("pool-overflow-general", "pool-prod-general", True)


def test_critical_spills_to_critical_overflow_only():
    d = decide(cell="prod-critical", zone="critical", home_count=40)  # 90% of 45 = 40.5 -> 40
    assert d.route == "pool-overflow-critical"
    assert decide(cell="prod-critical", zone="critical", home_count=39).route == "pool-prod-critical"


def test_overflow_disabled_tenant_never_spills():
    d = decide(overflow=False, home_count=1000)
    assert (d.route, d.alt_route, d.spilled) == ("pool-prod-general", "pool-prod-general", False)


def test_no_overflow_pool_for_zone_never_spills():
    d = decide(cell="res", zone="restricted", cap_map={**CAP, "res": {"tps": 15}}, home_count=1000)
    assert d.route == "pool-res" and not d.spilled


def test_busy_overflow_pool_falls_back_to_home_instead_of_rejecting():
    d = decide(home_count=50, ovf_count=13)  # overflow limit: 90% of 15 = 13
    assert d.route == "pool-prod-general" and not d.spilled


def test_tenant_share_of_overflow_is_capped():
    # 50% of 15 = 7 per second per tenant
    assert decide(home_count=50, tenant_ovf_count=6).spilled
    assert not decide(home_count=50, tenant_ovf_count=7).spilled


@pytest.mark.parametrize("pct, expected", [(90, 27), (100, 30), (50, 15)])
def test_threshold_is_configurable(pct, expected):
    assert not decide(threshold_pct=pct, home_count=expected - 1).spilled
    assert decide(threshold_pct=pct, home_count=expected).spilled
