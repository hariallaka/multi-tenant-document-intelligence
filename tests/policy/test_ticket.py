import base64
import os

import pytest

from ticket import build_result_url, build_ticket, sign, verify_ticket

TENANT_A = "3f1c0d8e-0000-0000-0000-000000000001"
TENANT_B = "3f1c0d8e-0000-0000-0000-000000000002"


def new_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


@pytest.fixture
def keys():
    return {"current": new_key(), "prev": new_key()}


def test_round_trip(keys):
    t = build_ticket("di-prod-gen-a1", "prebuilt-invoice", "abc-123", TENANT_A, keys["current"])
    v = verify_ticket(t, TENANT_A, [keys["current"], keys["prev"]])
    assert v is not None
    assert (v.backend, v.model, v.result_id, v.tenant) == ("di-prod-gen-a1", "prebuilt-invoice", "abc-123", TENANT_A)


def test_ticket_is_url_safe(keys):
    # Enough tickets to hit '+', '/' and padding cases in standard base64.
    for i in range(200):
        t = build_ticket("di-prod-gen-a1", "t001-model", f"r{i}?/+", TENANT_A, keys["current"])
        assert "=" not in t and "+" not in t and "/" not in t
        assert verify_ticket(t, TENANT_A, [keys["current"]]) is not None


def test_tampered_signature_rejected(keys):
    t = build_ticket("di-prod-gen-a1", "prebuilt-read", "r1", TENANT_A, keys["current"])
    body, sig = t.split(".")
    flipped = ("A" if sig[0] != "A" else "B") + sig[1:]
    assert verify_ticket(f"{body}.{flipped}", TENANT_A, [keys["current"], keys["prev"]]) is None


def test_tampered_body_rejected(keys):
    t = build_ticket("di-prod-gen-a1", "prebuilt-read", "r1", TENANT_A, keys["current"])
    _, sig = t.split(".")
    forged_body = build_ticket("di-prod-gen-b1", "prebuilt-read", "r1", TENANT_A, new_key()).split(".")[0]
    assert verify_ticket(f"{forged_body}.{sig}", TENANT_A, [keys["current"]]) is None


def test_wrong_tenant_rejected(keys):
    t = build_ticket("di-prod-gen-a1", "prebuilt-read", "r1", TENANT_A, keys["current"])
    assert verify_ticket(t, TENANT_B, [keys["current"], keys["prev"]]) is None


def test_ticket_signed_with_previous_key_accepted(keys):
    # Key rotation: tickets issued before the rotation carry the (now) previous key.
    t = build_ticket("di-prod-gen-a1", "prebuilt-read", "r1", TENANT_A, keys["prev"])
    assert verify_ticket(t, TENANT_A, [keys["current"], keys["prev"]]) is not None


def test_ticket_signed_with_retired_key_rejected(keys):
    retired = new_key()
    t = build_ticket("di-prod-gen-a1", "prebuilt-read", "r1", TENANT_A, retired)
    assert verify_ticket(t, TENANT_A, [keys["current"], keys["prev"]]) is None


@pytest.mark.parametrize("bad", ["", "nodot", "a.b.c", ".", "abc."])
def test_malformed_ticket_rejected(keys, bad):
    assert verify_ticket(bad, TENANT_A, [keys["current"]]) is None


def test_validly_signed_ticket_with_wrong_field_count_rejected(keys):
    body = base64.urlsafe_b64encode(b"only|three|fields").decode().rstrip("=")
    assert verify_ticket(f"{body}.{sign(body, keys['current'])}", TENANT_A, [keys["current"]]) is None


def test_result_url_rewrite(keys):
    host_map = {"di-prod-gen-a1-x7p.cognitiveservices.azure.com": "di-prod-gen-a1"}
    op = ("https://di-prod-gen-a1-x7p.cognitiveservices.azure.com/documentintelligence/"
          "documentModels/prebuilt-layout/analyzeResults/5b6c0a2e-1111?api-version=2024-11-30")
    url = build_result_url(op, host_map, TENANT_A, keys["current"], "di.internal.example")
    assert url.startswith("https://di.internal.example/di/v1/results/")
    v = verify_ticket(url.rsplit("/", 1)[1], TENANT_A, [keys["current"]])
    assert v is not None
    assert (v.backend, v.model, v.result_id) == ("di-prod-gen-a1", "prebuilt-layout", "5b6c0a2e-1111")
