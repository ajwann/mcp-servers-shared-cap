"""Monthly reset: link billing again once the month the cap tripped in is over.

Deployed by ../shared-spend-cap.sh as an HTTP Cloud Run function in a project
of its own, called daily by Cloud Scheduler. It cannot live in the capped
project: once the cap unlinks billing there, nothing in that project runs,
including a scheduler.

It links billing only when the cap itself unlinked it, in an earlier budget
month. Billing removed by a person is left alone, and a cap that trips
mid-month stays tripped until the 1st. Running daily rather than monthly makes
a failed attempt retry itself the next day.

Environment:
    RESET_PROJECT          Project the cap guards. Required.
    RESET_BILLING_ACCOUNT  Billing account to link it to, like 0123AB-CDEF01-234567. Required.
    RESET_CAP_SA           Email of the cap function's service account. Required.
    RESET_DRY_RUN          "true" to log the decision without acting on it.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import flask
import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import billing_v1

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
_logger = logging.getLogger("spend-cap-reset")
# basicConfig does nothing when the framework has already configured logging.
_logger.setLevel(logging.INFO)

PROJECT_ID = os.environ["RESET_PROJECT"]
BILLING_ACCOUNT = os.environ["RESET_BILLING_ACCOUNT"]
CAP_ACCOUNT = os.environ["RESET_CAP_SA"]
DRY_RUN = os.environ.get("RESET_DRY_RUN", "").strip().lower() in {"1", "true", "yes"}

#: Budgets count calendar months in Pacific time, whatever the account's locale.
BUDGET_TIMEZONE = ZoneInfo("America/Los_Angeles")
#: How Cloud Billing records removing a project's billing account.
UNLINK_METHOD = "DisableResourceBilling"
#: Admin Activity audit logs are kept this long, so looking further back finds nothing.
_AUDIT_RETENTION = timedelta(days=400)


@dataclass(frozen=True)
class BillingChange:
    """The most recent change to the project's billing link, from its audit log."""

    method: str
    principal: str
    timestamp: datetime


def month_start(now: datetime) -> datetime:
    """The start of the budget month containing ``now``."""
    return now.astimezone(BUDGET_TIMEZONE).replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def should_relink(
    billing_enabled: bool,
    last_change: BillingChange | None,
    now: datetime,
    cap_account: str = CAP_ACCOUNT,
) -> tuple[bool, str]:
    """Decide whether to link billing again, and say why for the log."""
    if billing_enabled:
        return False, "billing already enabled; nothing to do"
    if last_change is None:
        return False, "billing is off but the audit log does not say who did it; leaving it off"
    if last_change.method != UNLINK_METHOD or last_change.principal != cap_account:
        return False, (
            f"billing was last changed by {last_change.principal} ({last_change.method}), "
            "not by the cap; leaving it off"
        )
    if last_change.timestamp >= month_start(now):
        return False, (
            f"the cap tripped this month, at {last_change.timestamp.isoformat()}; "
            "billing stays off until the 1st"
        )
    return True, f"the cap tripped last month, at {last_change.timestamp.isoformat()}"


def last_billing_change(now: datetime) -> BillingChange | None:
    """The newest Cloud Billing entry in the project's Admin Activity audit log."""
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    # An explicit timestamp bound, because a filter without one may be limited to the last day.
    since = (now - _AUDIT_RETENTION).isoformat()
    response = AuthorizedSession(credentials).post(
        "https://logging.googleapis.com/v2/entries:list",
        json={
            "resourceNames": [f"projects/{PROJECT_ID}"],
            "filter": (
                f'logName="projects/{PROJECT_ID}/logs/cloudaudit.googleapis.com%2Factivity" '
                'AND protoPayload.serviceName="cloudbilling.googleapis.com" '
                f'AND timestamp>="{since}"'
            ),
            "orderBy": "timestamp desc",
            "pageSize": 1,
        },
        timeout=30,
    )
    response.raise_for_status()
    entries = response.json().get("entries", [])
    if not entries:
        return None
    payload = entries[0]["protoPayload"]
    return BillingChange(
        method=payload.get("methodName", ""),
        principal=payload.get("authenticationInfo", {}).get("principalEmail", ""),
        timestamp=datetime.fromisoformat(entries[0]["timestamp"]),
    )


@functions_framework.http
def relink_billing(request: flask.Request) -> tuple[str, int]:
    """Handle one scheduled run. Errors propagate so the run is recorded as failed."""
    del request  # the schedule carries no input
    now = datetime.now(UTC)
    client = billing_v1.CloudBillingClient()
    name = f"projects/{PROJECT_ID}"
    billing_enabled = client.get_project_billing_info(name=name).billing_enabled
    last_change = None if billing_enabled else last_billing_change(now)

    relink, reason = should_relink(billing_enabled, last_change, now)
    if not relink:
        _logger.info("%s: %s", PROJECT_ID, reason)
        return reason, 200

    if DRY_RUN:
        message = f"DRY RUN: would link {PROJECT_ID} to billing account {BILLING_ACCOUNT}: {reason}"
        _logger.warning(message)
        return message, 200

    client.update_project_billing_info(
        name=name,
        project_billing_info=billing_v1.ProjectBillingInfo(
            billing_account_name=f"billingAccounts/{BILLING_ACCOUNT}"
        ),
    )
    message = f"linked {PROJECT_ID} to billing account {BILLING_ACCOUNT}: {reason}"
    _logger.warning(message)
    return message, 200
