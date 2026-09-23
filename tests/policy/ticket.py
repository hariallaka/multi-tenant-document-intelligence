"""Python port of the result-ticket logic in apim/policies.

op-analyze.xml (outbound) builds the ticket; op-result.xml (inbound) verifies it.
Keep this file in lock-step with those expressions: the tests in
test_policy_xml.py fail if the policy's building blocks drift.

Ticket format:  <body>.<sig>
  body = base64url_nopad(utf8("backendKey|model|resultId|tenant"))
  sig  = base64url_nopad(HMAC-SHA256(key=base64decode(signing_key), msg=utf8(body)))
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
from dataclasses import dataclass
from typing import Iterable, Optional

# Same pattern as op-analyze.xml.
OPERATION_LOCATION_RE = r"documentModels/([^/]+)/analyzeResults/([^/?]+)"


def _b64url_nopad(data: bytes) -> str:
    # C#: Convert.ToBase64String(x).TrimEnd('=').Replace('+','-').Replace('/','_')
    return base64.b64encode(data).decode("ascii").rstrip("=").replace("+", "-").replace("/", "_")


def _b64url_decode(text: str) -> bytes:
    # C#: Replace('-','+').Replace('_','/'), PadRight to a multiple of 4 with '='.
    b = text.replace("-", "+").replace("_", "/")
    b = b + "=" * ((4 - len(b) % 4) % 4)
    return base64.b64decode(b, validate=True)


def sign(body: str, key_b64: str) -> str:
    key = base64.b64decode(key_b64)
    return _b64url_nopad(hmac.new(key, body.encode("utf-8"), hashlib.sha256).digest())


@dataclass(frozen=True)
class Ticket:
    backend: str
    model: str
    result_id: str
    tenant: str


def build_ticket(backend: str, model: str, result_id: str, tenant: str, key_b64: str) -> str:
    raw = "|".join([backend, model, result_id, tenant])
    body = _b64url_nopad(raw.encode("utf-8"))
    return f"{body}.{sign(body, key_b64)}"


def build_result_url(operation_location: str, host_map: dict[str, str], tenant: str,
                     key_b64: str, gateway_host: str) -> str:
    """Mirror of the Operation-Location rewrite in op-analyze.xml."""
    from urllib.parse import urlparse

    op = urlparse(operation_location)
    backend = host_map[op.hostname]
    m = re.search(OPERATION_LOCATION_RE, op.path)
    if m is None:
        raise ValueError("Operation-Location does not match the analyzeResults pattern")
    ticket = build_ticket(backend, m.group(1), m.group(2), tenant, key_b64)
    return f"https://{gateway_host}/di/v1/results/{ticket}"


def verify_ticket(ticket: str, caller_tenant: str, keys_b64: Iterable[str]) -> Optional[Ticket]:
    """Mirror of op-result.xml. Returns None where the policy returns "" (-> 404)."""
    parts = ticket.split(".")
    if len(parts) != 2:
        return None
    body, sig = parts
    # The policy compares with string equality; compare_digest is the constant-time
    # equivalent and returns the same answer.
    if not any(hmac.compare_digest(sig, sign(body, k)) for k in keys_b64):
        return None
    try:
        fields = _b64url_decode(body).decode("utf-8").split("|")
    except (ValueError, UnicodeDecodeError):
        return None
    if len(fields) != 4 or fields[3] != caller_tenant:
        return None
    return Ticket(*fields)
