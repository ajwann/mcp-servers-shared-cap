from __future__ import annotations

from datetime import UTC, datetime
from types import ModuleType

# 2026-10-01 00:00 Pacific, when October's budget month begins.
OCTOBER_START = "2026-10-01T07:00:00Z"
SEPTEMBER_START = "2026-09-01T07:00:00Z"


def test_month_start_is_pacific(cap: ModuleType) -> None:
    # 05:00 UTC on the 1st is still the 30th in California.
    assert cap.month_start(datetime(2026, 10, 1, 5, tzinfo=UTC)) == datetime.fromisoformat(
        SEPTEMBER_START
    )
    assert cap.month_start(datetime(2026, 10, 1, 8, tzinfo=UTC)) == datetime.fromisoformat(
        OCTOBER_START
    )


def test_last_months_notification_after_the_1st_is_ignored(cap: ModuleType) -> None:
    notification = {"costAmount": 5.0, "budgetAmount": 5.0, "costIntervalStart": SEPTEMBER_START}
    assert cap.for_closed_month(notification, datetime(2026, 10, 1, 9, tzinfo=UTC))


def test_this_months_notification_counts(cap: ModuleType) -> None:
    notification = {"costAmount": 5.0, "budgetAmount": 5.0, "costIntervalStart": OCTOBER_START}
    assert not cap.for_closed_month(notification, datetime(2026, 10, 1, 9, tzinfo=UTC))


def test_last_hour_of_the_month_still_counts(cap: ModuleType) -> None:
    # 06:12 UTC on Oct 1 is 23:12 on Sept 30 Pacific: September is still open.
    notification = {"costAmount": 5.0, "budgetAmount": 5.0, "costIntervalStart": SEPTEMBER_START}
    assert not cap.for_closed_month(notification, datetime(2026, 10, 1, 6, 12, tzinfo=UTC))


def test_notification_without_interval_counts(cap: ModuleType) -> None:
    assert not cap.for_closed_month({"costAmount": 5.0, "budgetAmount": 5.0}, datetime.now(UTC))
