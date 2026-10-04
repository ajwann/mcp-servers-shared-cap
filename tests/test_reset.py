from __future__ import annotations

from datetime import UTC, datetime
from types import ModuleType

from conftest import CAP_ACCOUNT

NOW = datetime(2026, 10, 4, 7, 30, tzinfo=UTC)  # 00:30 Pacific on Oct 4


def change(
    reset: ModuleType,
    when: str,
    *,
    method: str = "DisableResourceBilling",
    principal: str = CAP_ACCOUNT,
) -> object:
    return reset.BillingChange(
        method=method, principal=principal, timestamp=datetime.fromisoformat(when)
    )


def test_relinks_after_the_cap_tripped_last_month(reset: ModuleType) -> None:
    # The real trip: 23:12 Pacific on Sept 30.
    relink, _ = reset.should_relink(False, change(reset, "2026-10-01T06:12:16.656385Z"), NOW)
    assert relink


def test_waits_when_the_cap_tripped_this_month(reset: ModuleType) -> None:
    relink, reason = reset.should_relink(False, change(reset, "2026-10-02T12:00:00Z"), NOW)
    assert not relink
    assert "until the 1st" in reason


def test_leaves_billing_a_person_removed(reset: ModuleType) -> None:
    last = change(reset, "2026-09-15T12:00:00Z", principal="someone@example.com")
    relink, reason = reset.should_relink(False, last, NOW)
    assert not relink
    assert "someone@example.com" in reason


def test_leaves_billing_off_after_some_other_change(reset: ModuleType) -> None:
    last = change(reset, "2026-09-15T12:00:00Z", method="AssignResourceToBillingAccount")
    assert not reset.should_relink(False, last, NOW)[0]


def test_leaves_billing_off_without_an_audit_record(reset: ModuleType) -> None:
    assert not reset.should_relink(False, None, NOW)[0]


def test_does_nothing_when_billing_is_on(reset: ModuleType) -> None:
    relink, reason = reset.should_relink(True, None, NOW)
    assert not relink
    assert "already enabled" in reason


def test_nanosecond_audit_timestamps_parse(reset: ModuleType) -> None:
    last = change(reset, "2026-09-30T12:00:00.123456789Z")
    assert reset.should_relink(False, last, NOW)[0]
