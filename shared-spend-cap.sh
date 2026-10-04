#!/usr/bin/env bash
#
# The shared spend cap for every MCP server in one GCP project.
#
#     budget ──cost updates──> Pub/Sub ──> function ──> unlinks the project's billing
#     daily schedule (in a project of its own) ──> reset function ──> links it again
#                                                   once the month it tripped in is over
#
# Google Cloud has no hard spending limit; a budget only sends email. This is the
# documented substitute, and it is deliberately NOT owned by any one server:
# the budget measures the whole project's spend and the function unlinks the
# whole project's billing, so every server in the project shares one cap and
# they all stop together.
#
# Each server's own deploy script skips its per-server budget and kill switch by
# setting ${PREFIX}_SHARED_BUDGET=true, which is what keeps this the only one.
#
# Re-running is how you change it; every step is idempotent.
#
# Usage:
#   ./shared-spend-cap.sh                       # create or update the cap
#   SPEND_CAP_DRY_RUN=true ./shared-spend-cap.sh  # deploy in logging-only mode
#   ./shared-spend-cap.sh --show                # print the live configuration
#
# Settings:
#   SHARED_CAP_PROJECT   the project whose billing is cut     (default below)
#   SHARED_CAP_BILLING   billing account holding the budget   (default: the project's)
#   SHARED_CAP_REGION    region for the function              (default us-east1)
#   SHARED_CAP_USD       monthly budget                       (default 5)
#   SPEND_CAP_AT         fraction of the budget that trips it (default 1.0)
#   SPEND_CAP_DRY_RUN    true: the function only logs         (default false)
#   SHARED_CAP_BUILD_SA  build service account for the function
#                        (default: any *-build@ account in the project)
#   SHARED_CAP_AUTO_RESET     false: billing stays off until linked by hand (default true)
#   SHARED_CAP_RESET_PROJECT  project that runs the monthly reset (default mcp-servers-cap-reset)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT

PROJECT="${SHARED_CAP_PROJECT:-adam-wanningers-mcp-servers}"
REGION="${SHARED_CAP_REGION:-us-east1}"
BUDGET_USD="${SHARED_CAP_USD:-5}"
SPEND_CAP_AT="${SPEND_CAP_AT:-1.0}"
SPEND_CAP_DRY_RUN="${SPEND_CAP_DRY_RUN:-false}"
AUTO_RESET="${SHARED_CAP_AUTO_RESET:-true}"
RESET_PROJECT="${SHARED_CAP_RESET_PROJECT:-mcp-servers-cap-reset}"

# Named for the account rather than any server, because it governs them all.
readonly BUDGET_NAME="Adam Wanningers MCP Servers shared cap"
readonly TOPIC_ID="mcp-servers-shared-cap"
readonly FUNCTION="mcp-servers-shared-cap"
readonly SPEND_SA_ID="mcp-shared-spendcap"
# Google's own identity for publishing budget notifications.
readonly BUDGET_PUBLISHER=billing-budget-alert@system.gserviceaccount.com
readonly SPEND_CAP_SOURCE="$REPO_ROOT/function"
# The monthly reset runs outside $PROJECT: nothing in a project without billing
# runs, a scheduler included.
readonly RESET_FUNCTION="mcp-servers-cap-reset"
readonly RESET_JOB="mcp-servers-cap-reset"
readonly RESET_SA_ID="cap-resetter"
readonly RESET_BUILD_SA_ID="cap-reset-build"
readonly RESET_SOURCE="$REPO_ROOT/reset"
# 00:30 daily in the budget's own time zone; it only acts in a month after the trip.
readonly RESET_SCHEDULE="30 0 * * *"
readonly RESET_TIMEZONE="America/Los_Angeles"

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
else
  B=''; DIM=''; GRN=''; YLW=''; RED=''; RST=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$GRN" "$RST" "$B" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }
warn() { printf '%s !! %s%s\n' "$YLW" "$*" "$RST" >&2; }
die()  { printf '%s !! %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

gp() { gcloud --quiet --project="$PROJECT" "$@"; }

retry() { # IAM is eventually consistent, so a new account can lag behind the next call
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" && return 0
    note "not ready yet; retrying in $(( attempt * 5 ))s"
    sleep $(( attempt * 5 ))
  done
  "$@"
}

budget_ids() { # every budget matching our display name
  gcloud billing budgets list --billing-account="$BILLING" --billing-project="$PROJECT" \
    --filter="displayName=\"$BUDGET_NAME\"" --format='value(name.basename())'
}

show() {
  step "Live shared cap"
  gcloud billing budgets list --billing-account="$BILLING" --billing-project="$PROJECT" \
    --format="table[box](displayName,amount.specifiedAmount.units:label=USD,
                         notificationsRule.pubsubTopic:label=TOPIC)"
  gp run services describe "$FUNCTION" --region="$REGION" \
    --format='value(spec.template.spec.containers[0].env)' 2>/dev/null \
    | tr ';' '\n' | grep -o "'name': '[^']*', 'value': '[^']*'" || warn "$FUNCTION not deployed"
  step "Monthly reset"
  gcloud --quiet --project="$RESET_PROJECT" scheduler jobs describe "$RESET_JOB" \
    --location="$REGION" --format='value(schedule,timeZone,state,lastAttemptTime,status.code)' \
    2>/dev/null | awk -F'\t' '{ # status.code is a google.rpc code: absent once a run succeeds
      last = ($4 == "" ? "never" : $4 ($5 == "" ? ", succeeded" : ", failed with code " $5))
      printf "    %s (%s), %s; last run: %s\n", $1, $2, $3, last }' \
    || warn "no monthly reset in $RESET_PROJECT"
}

# -- preflight ---------------------------------------------------------------

command -v gcloud >/dev/null || die "gcloud is not installed"
gcloud auth print-access-token >/dev/null 2>&1 \
  || die "not logged in: run 'gcloud auth login'"
[[ -d $SPEND_CAP_SOURCE ]] || die "no function source at $SPEND_CAP_SOURCE"
[[ $BUDGET_USD =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || die "SHARED_CAP_USD must be an amount like 5"
[[ $SPEND_CAP_AT =~ ^(0?\.[0-9]+|1(\.0+)?)$ ]] || die "SPEND_CAP_AT must be a fraction like 1.0"
[[ $AUTO_RESET =~ ^(true|false)$ ]] || die "SHARED_CAP_AUTO_RESET must be true or false"
[[ $AUTO_RESET == false || -d $RESET_SOURCE ]] || die "no reset source at $RESET_SOURCE"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')" \
  || die "cannot read project $PROJECT"
BILLING="${SHARED_CAP_BILLING:-$(gcloud billing projects describe "$PROJECT" \
  --format='value(billingAccountName)' | sed 's|billingAccounts/||')}"
[[ -n $BILLING ]] || die "no billing account is linked to $PROJECT"
readonly PROJECT PROJECT_NUMBER BILLING

[[ ${1:-} == --show ]] && { show; exit 0; }

step "Shared spend cap for $PROJECT"
info "budget \$$BUDGET_USD a month, billing unlinked at ${SPEND_CAP_AT} of it"
info "that is \$$(python3 -c "print(f'{$BUDGET_USD * $SPEND_CAP_AT:.2f}')") of combined spend"
[[ $SPEND_CAP_DRY_RUN == true ]] && warn "DRY RUN: the function will log, not unlink billing"

# -- APIs --------------------------------------------------------------------

step "APIs"
gp services enable billingbudgets.googleapis.com cloudbilling.googleapis.com \
  pubsub.googleapis.com cloudfunctions.googleapis.com run.googleapis.com \
  eventarc.googleapis.com cloudbuild.googleapis.com >/dev/null
info "enabled"

# -- topic -------------------------------------------------------------------

step "Pub/Sub topic"
if ! gp pubsub topics describe "$TOPIC_ID" >/dev/null 2>&1; then
  gp pubsub topics create "$TOPIC_ID" >/dev/null
  info "created $TOPIC_ID"
else
  info "$TOPIC_ID already exists"
fi
retry gp pubsub topics add-iam-policy-binding "$TOPIC_ID" \
  --member="serviceAccount:$BUDGET_PUBLISHER" --role=roles/pubsub.publisher >/dev/null
info "Google's budget publisher may publish to it"

# -- identity ----------------------------------------------------------------

step "Service account"
SPEND_SA="$SPEND_SA_ID@$PROJECT.iam.gserviceaccount.com"
if ! gp iam service-accounts describe "$SPEND_SA" >/dev/null 2>&1; then
  gp iam service-accounts create "$SPEND_SA_ID" \
    --display-name="Shared MCP spend cap" >/dev/null
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    gp iam service-accounts describe "$SPEND_SA" >/dev/null 2>&1 && break
    sleep 3
  done
  info "created $SPEND_SA_ID"
else
  info "$SPEND_SA_ID already exists"
fi
# Removing THIS project's billing link and nothing more: Project Billing Manager
# on the project, never admin over the whole billing account.
retry gp projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$SPEND_SA" --role=roles/billing.projectManager \
  --condition=None >/dev/null
info "may unlink billing for $PROJECT, and nothing else"

# Cloud Build needs a service account it may run as. A project without the
# Compute API has no default one, so reuse a builder the project already has
# rather than naming any particular server's. That is a property of the project,
# not of whichever server happens to be deployed first.
BUILD_SA="${SHARED_CAP_BUILD_SA:-}"
if [[ -z $BUILD_SA ]]; then
  BUILD_SA="$(gp iam service-accounts list \
    --filter="email:*-build@$PROJECT.iam.gserviceaccount.com" \
    --format='value(email)' --limit=1 2>/dev/null || true)"
fi
BUILD_ARGS=()
if [[ -n $BUILD_SA ]] && gp iam service-accounts describe "$BUILD_SA" >/dev/null 2>&1; then
  BUILD_ARGS=(--build-service-account="projects/$PROJECT/serviceAccounts/$BUILD_SA")
  info "building as $BUILD_SA"
else
  note "no builder service account found; Cloud Build will use the project default"
fi

# -- the kill switch ---------------------------------------------------------

step "Function"
info "deploying $FUNCTION (a few minutes)"
retry gp functions deploy "$FUNCTION" --gen2 --region="$REGION" --runtime=python312 \
  --source="$SPEND_CAP_SOURCE" --entry-point=stop_billing \
  --trigger-topic="$TOPIC_ID" \
  --run-service-account="$SPEND_SA" --trigger-service-account="$SPEND_SA" \
  ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
  --set-env-vars="SPEND_CAP_PROJECT=$PROJECT,SPEND_CAP_AT=$SPEND_CAP_AT,SPEND_CAP_DRY_RUN=$SPEND_CAP_DRY_RUN" \
  --max-instances=1 --memory=256Mi --timeout=60s --no-allow-unauthenticated >/dev/null
retry gp run services add-iam-policy-binding "$FUNCTION" --region="$REGION" \
  --member="serviceAccount:$SPEND_SA" --role=roles/run.invoker >/dev/null
info "$FUNCTION trips at ${SPEND_CAP_AT} of the budget (dry run: $SPEND_CAP_DRY_RUN)"

# -- budget ------------------------------------------------------------------

# Replaced rather than updated, because creation's threshold flags are the
# unambiguously documented ones. Only the budget with our display name is
# touched, so a per-server budget someone else made is left alone.
step "Budget"
for budget_id in $(budget_ids); do
  gcloud billing budgets delete "$budget_id" --billing-account="$BILLING" \
    --billing-project="$PROJECT" --quiet >/dev/null
  note "replaced the previous budget"
done
gcloud billing budgets create \
  --billing-account="$BILLING" --billing-project="$PROJECT" \
  --display-name="$BUDGET_NAME" \
  --budget-amount="${BUDGET_USD}USD" --calendar-period=month \
  --filter-projects="projects/$PROJECT_NUMBER" \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
  --notifications-rule-pubsub-topic="projects/$PROJECT/topics/$TOPIC_ID" \
  --quiet >/dev/null
info "\"$BUDGET_NAME\": \$$BUDGET_USD a month over all of $PROJECT"
info "email alerts to the billing admins at 50%, 90%, 100%"

# -- monthly reset -----------------------------------------------------------

if [[ $AUTO_RESET == true ]]; then
  rp() { gcloud --quiet --project="$RESET_PROJECT" "$@"; }

  step "Monthly reset in $RESET_PROJECT"
  if ! gcloud projects describe "$RESET_PROJECT" >/dev/null 2>&1; then
    gcloud projects create "$RESET_PROJECT" --name="MCP servers cap reset" >/dev/null \
      || die "cannot create $RESET_PROJECT; set SHARED_CAP_RESET_PROJECT to an unused ID"
    info "created $RESET_PROJECT"
  else
    info "$RESET_PROJECT already exists"
  fi
  # Deliberately outside the budget's filter: it has to keep running once the
  # cap has cut $PROJECT off. One scheduler job and a daily call are free tier.
  gcloud billing projects link "$RESET_PROJECT" --billing-account="$BILLING" >/dev/null
  info "billed to $BILLING, outside the cap"
  rp services enable cloudscheduler.googleapis.com cloudfunctions.googleapis.com \
    run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
    logging.googleapis.com cloudbilling.googleapis.com >/dev/null
  info "APIs enabled"

  ensure_reset_sa() { # $1 id, $2 display name
    local email="$1@$RESET_PROJECT.iam.gserviceaccount.com"
    if ! rp iam service-accounts describe "$email" >/dev/null 2>&1; then
      rp iam service-accounts create "$1" --display-name="$2" >/dev/null
      retry rp iam service-accounts describe "$email" >/dev/null 2>&1
    fi
    printf '%s' "$email"
  }
  RESET_SA="$(ensure_reset_sa "$RESET_SA_ID" "Shared MCP spend cap reset")"
  RESET_BUILD_SA="$(ensure_reset_sa "$RESET_BUILD_SA_ID" "Shared MCP spend cap reset builds")"

  # Linking takes a permission on both ends: attaching projects to this one
  # billing account, and changing the billing of this one project. Logs Viewer
  # reads the audit entry that says who unlinked it, and lets it read the
  # project's billing info.
  retry gcloud billing accounts add-iam-policy-binding "$BILLING" \
    --member="serviceAccount:$RESET_SA" --role=roles/billing.user >/dev/null
  for role in roles/billing.projectManager roles/logging.viewer; do
    retry gp projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:$RESET_SA" --role="$role" --condition=None >/dev/null
  done
  retry rp projects add-iam-policy-binding "$RESET_PROJECT" \
    --member="serviceAccount:$RESET_BUILD_SA" --role=roles/cloudbuild.builds.builder \
    --condition=None >/dev/null
  info "$RESET_SA_ID may link $PROJECT to $BILLING, and nothing else"

  info "deploying $RESET_FUNCTION (a few minutes)"
  retry rp functions deploy "$RESET_FUNCTION" --gen2 --region="$REGION" --runtime=python312 \
    --source="$RESET_SOURCE" --entry-point=relink_billing --trigger-http \
    --run-service-account="$RESET_SA" \
    --build-service-account="projects/$RESET_PROJECT/serviceAccounts/$RESET_BUILD_SA" \
    --set-env-vars="RESET_PROJECT=$PROJECT,RESET_BILLING_ACCOUNT=$BILLING,RESET_CAP_SA=$SPEND_SA,RESET_DRY_RUN=$SPEND_CAP_DRY_RUN" \
    --max-instances=1 --memory=256Mi --timeout=60s --no-allow-unauthenticated >/dev/null
  retry rp run services add-iam-policy-binding "$RESET_FUNCTION" --region="$REGION" \
    --member="serviceAccount:$RESET_SA" --role=roles/run.invoker >/dev/null
  RESET_URL="$(rp functions describe "$RESET_FUNCTION" --gen2 --region="$REGION" \
    --format='value(serviceConfig.uri)')"

  job_verb=create
  rp scheduler jobs describe "$RESET_JOB" --location="$REGION" >/dev/null 2>&1 && job_verb=update
  retry rp scheduler jobs "$job_verb" http "$RESET_JOB" --location="$REGION" \
    --schedule="$RESET_SCHEDULE" --time-zone="$RESET_TIMEZONE" \
    --uri="$RESET_URL" --http-method=POST \
    --oidc-service-account-email="$RESET_SA" --oidc-token-audience="$RESET_URL" >/dev/null
  info "checks daily at 00:30 Pacific; links billing again in the month after a trip"
else
  note "SHARED_CAP_AUTO_RESET=false: after a trip, billing stays off until linked by hand"
fi

step "Done"
info "every server in $PROJECT now shares one cap"
[[ $SPEND_CAP_DRY_RUN == true ]] \
  && warn "still a DRY RUN: re-run without SPEND_CAP_DRY_RUN=true to arm it"
note "inspect it any time with: ./shared-spend-cap.sh --show"
