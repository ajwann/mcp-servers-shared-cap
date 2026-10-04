"""Budget kill switch: unlink billing from the project once spend nears its budget.

Deployed by ../shared-spend-cap.sh as a Cloud Run function subscribed to the
budget's Pub/Sub notifications. Google Cloud has no hard spending limit; this is
its documented substitute.

Removing the billing account stops every paid service in the project, so EVERY
server sharing it goes offline together until billing is linked again. That is
the intended behaviour: a budget measures a whole project's spend, so the cap
that acts on it belongs to the project rather than to any one server.

This file needs no changes per project: it is configured entirely by the three
SPEND_CAP_* environment variables the deploy script sets.

Cost data trails actual usage by hours, so the trigger can be set to a fraction
of the budget (SPEND_CAP_AT) rather than all of it. For the same reason a
notification about a month that has already closed can arrive after the 1st,
when ../reset has linked billing again; those are ignored, because cutting
billing then saves nothing and would undo the monthly reset.

Environment:
    SPEND_CAP_PROJECT   Project whose billing is cut. Required.
    SPEND_CAP_AT        Fraction of the budget that triggers the cut.
    SPEND_CAP_DRY_RUN   "true" to log the decision without acting on it.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from datetime import UTC, datetime
from typing import Any
from zoneinfo import ZoneInfo

import functions_framework
import google.auth
from cloudevents.http import CloudEvent
from google.auth.transport.requests import AuthorizedSession
from google.cloud import billing_v1

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
_logger = logging.getLogger("spend-cap")
# basicConfig does nothing when the framework has already configured logging,
# which would leave the default WARNING level in force and drop INFO lines.
_logger.setLevel(logging.INFO)

PROJECT_ID = os.environ["SPEND_CAP_PROJECT"]
THRESHOLD = float(os.environ.get("SPEND_CAP_AT", "0.8"))
DRY_RUN = os.environ.get("SPEND_CAP_DRY_RUN", "").strip().lower() in {"1", "true", "yes"}

#: Budgets count calendar months in Pacific time, whatever the account's locale.
BUDGET_TIMEZONE = ZoneInfo("America/Los_Angeles")

#: The one permission removing a project's billing account needs. The deploy
#: script grants it through Project Billing Manager on this project alone, not
#: the billing-account-wide admin role Google's tutorial uses. That role holds
#: only the create and delete billing-assignment permissions: it cannot even
#: read the project's billing info, so the function never tries to.
_UNLINK_PERMISSION = "resourcemanager.projects.deleteBillingAssignment"


def can_unlink_billing() -> bool:
    """Whether this function's identity may remove the project's billing account.

    Checked in a dry run so that the test proves the real cut would succeed.
    """
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    response = AuthorizedSession(credentials).post(
        f"https://cloudresourcemanager.googleapis.com/v3/projects/{PROJECT_ID}:testIamPermissions",
        json={"permissions": [_UNLINK_PERMISSION]},
        timeout=30,
    )
    response.raise_for_status()
    return _UNLINK_PERMISSION in response.json().get("permissions", [])


def over_threshold(notification: dict[str, Any], threshold: float = THRESHOLD) -> bool:
    """Whether a budget notification reports spend at or past the trigger point."""
    cost = float(notification["costAmount"])
    budget = float(notification["budgetAmount"])
    return budget > 0 and cost >= threshold * budget


def month_start(now: datetime) -> datetime:
    """The start of the budget month containing ``now``."""
    return now.astimezone(BUDGET_TIMEZONE).replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def for_closed_month(notification: dict[str, Any], now: datetime) -> bool:
    """Whether a budget notification reports on a month that has already ended.

    A notification without ``costIntervalStart`` is treated as current, so a
    malformed one errs towards cutting billing rather than ignoring spend.
    """
    interval_start = notification.get("costIntervalStart")
    if not interval_start:
        return False
    return datetime.fromisoformat(interval_start) < month_start(now)


@functions_framework.cloud_event
def stop_billing(event: CloudEvent) -> None:
    """Handle one budget notification delivered through Pub/Sub."""
    notification = json.loads(base64.b64decode(event.data["message"]["data"]))
    cost = notification.get("costAmount")
    budget = notification.get("budgetAmount")
    if for_closed_month(notification, datetime.now(UTC)):
        _logger.info(
            "ignoring spend %s of a %s budget for the month starting %s, which has ended",
            cost,
            budget,
            notification["costIntervalStart"],
        )
        return
    if not over_threshold(notification):
        _logger.info(
            "spend %s of a %s budget is under the %.0f%% cap", cost, budget, THRESHOLD * 100
        )
        return

    if DRY_RUN:
        _logger.warning(
            "DRY RUN: would disable billing for %s (spend %s of a %s budget); permitted to: %s",
            PROJECT_ID,
            cost,
            budget,
            can_unlink_billing(),
        )
        return

    # Unlinking a project that has no billing account changes nothing, so a
    # notification arriving after the cut is harmless.
    billing_v1.CloudBillingClient().update_project_billing_info(
        name=f"projects/{PROJECT_ID}",
        project_billing_info=billing_v1.ProjectBillingInfo(billing_account_name=""),
    )
    _logger.warning(
        "disabled billing for %s: spend %s reached %.0f%% of the %s budget",
        PROJECT_ID,
        cost,
        THRESHOLD * 100,
        budget,
    )
