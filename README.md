# mcp-servers-shared-cap

One hard spending cap for every MCP server sharing a Google Cloud project.

```
budget ──cost updates, several times a day──> Pub/Sub topic
                                                    │
                                                    v
                                     Cloud Run function (gen2)
                                                    │
                            spend >= SPEND_CAP_AT × budget?
                                                    │
                                                    v
                                  unlinks billing from the project

daily Cloud Scheduler job (separate project) ──> reset function
                                                    │
               the cap tripped in an earlier month? │
                                                    v
                                    links billing to the project again
```

**Google Cloud has no hard spending limit.** A budget only sends email; nothing stops
spending on its own. This is the documented substitute.

The cap holds for the rest of the month it trips in. On the 1st (Pacific time, the same
months the budget counts) billing is linked again automatically and the servers come back.

## Why one cap, and not one per server

This is the part that is easy to get wrong, and expensive to get wrong twice.

A budget measures the spend of a **whole project**, and unlinking billing takes a **whole
project** down. So two servers in one project do not get a budget each: two $5 budgets both
alert when the project reaches $5, not $10, and two kill switches unlink the same billing
account for the same money. All you buy is duplicate alert emails and two things to keep in
sync.

So the cap belongs to the project, not to any server in it. It lives here, named after
nobody in particular, and each server's deploy script sets `*_SHARED_BUDGET=true` to create
neither a budget nor a kill switch of its own.

**When it fires, every server in the project stops.** That is the intended behaviour, not a
side effect.

## What it creates

In the project it is pointed at:

| Resource | Name |
| --- | --- |
| Budget | `Adam Wanningers MCP Servers shared cap` |
| Pub/Sub topic | `mcp-servers-shared-cap` |
| Cloud Run function | `mcp-servers-shared-cap` |
| Service account | `mcp-shared-spendcap` |

And, for the monthly reset, in a project of its own (`mcp-servers-cap-reset` by default):

| Resource | Name |
| --- | --- |
| Cloud Scheduler job | `mcp-servers-cap-reset`, daily at 00:30 Pacific |
| Cloud Run function | `mcp-servers-cap-reset` |
| Service accounts | `cap-resetter` (runs it), `cap-reset-build` (builds it) |

The reset can't live in the capped project: once billing is off there, nothing in it runs,
a scheduler included. Its project is billed to the same account but sits outside the
budget, and one scheduler job and a call a day stay within the free tier.

The function's identity holds **Project Billing Manager on that one project**, not the
billing-account-wide admin role Google's own tutorial uses, so it cannot touch anything
else on the billing account. `cap-resetter` holds Billing Account User on that one billing
account, plus Project Billing Manager and Logs Viewer on the capped project: just enough to
link that project to that account and read who unlinked it.

## Using it

```bash
./shared-spend-cap.sh                          # create or update the cap
./shared-spend-cap.sh --show                   # print the live configuration
SPEND_CAP_DRY_RUN=true ./shared-spend-cap.sh   # deploy it in logging-only mode
```

Re-running is how you change it; every step is idempotent.

| Setting | Default | Notes |
| --- | --- | --- |
| `SHARED_CAP_PROJECT` | `adam-wanningers-mcp-servers` | The project whose billing is cut. |
| `SHARED_CAP_BILLING` | the project's billing account | |
| `SHARED_CAP_REGION` | `us-east1` | Where the function runs. |
| `SHARED_CAP_USD` | `5` | Monthly budget. Email alerts at 50%, 90%, 100%. |
| `SPEND_CAP_AT` | `1.0` | Fraction of the budget that trips it. |
| `SPEND_CAP_DRY_RUN` | `false` | `true`: the function logs what it would do and stops. |
| `SHARED_CAP_AUTO_RESET` | `true` | `false`: no monthly reset; billing stays off until linked by hand. |
| `SHARED_CAP_RESET_PROJECT` | `mcp-servers-cap-reset` | Project that runs the reset. Created if missing; project IDs are global, so pick another if it's taken. |
| `SHARED_CAP_BUILD_SA` | any `*-build@` account in the project | Cloud Build needs an account to run as; a project without the Compute API has no default one. |

At the defaults it fires when the project's servers **together** reach $5 in a month.

### Test it before trusting it

Deploy with `SPEND_CAP_DRY_RUN=true`, then push a notification at the trigger point and
read the log. This exercises the threshold arithmetic *and* proves the service account can
actually unlink billing, without unlinking anything:

```bash
gcloud pubsub topics publish mcp-servers-shared-cap --project <project> \
  --message='{"costAmount":5.0,"budgetAmount":5.0,"currencyCode":"USD"}' \
  --attribute=schemaVersion=1.0

gcloud logging read 'resource.labels.service_name="mcp-servers-shared-cap"' \
  --project <project> --limit 5 --freshness=10m --format='value(textPayload)'
# → DRY RUN: would disable billing for <project> (spend 5.0 of a 5.0 budget); permitted to: True
```

`permitted to: True` is the part worth checking.

A dry run deploys the reset in logging-only mode too. Trigger it and read its answer:

```bash
gcloud scheduler jobs run mcp-servers-cap-reset --location us-east1 --project mcp-servers-cap-reset
gcloud logging read 'resource.labels.service_name="mcp-servers-cap-reset"' \
  --project mcp-servers-cap-reset --limit 5 --freshness=10m --format='value(textPayload)'
# → example-project: billing already enabled; nothing to do
```

Then re-run without `SPEND_CAP_DRY_RUN` to arm both.

## Recovering after it fires

The servers return 503 and the project's paid services stop. Billing comes back by itself
in the first half hour of the next month (Pacific time), when the daily reset finds the cap
tripped in a month that has since ended.

The reset re-links only what the cap itself unlinked. It checks the project's audit log,
and if the last billing change was made by anyone other than `mcp-shared-spendcap`, such as
you turning billing off on purpose, it leaves billing off.

A late notification about the month that has just ended can still arrive after the reset.
The kill switch ignores any notification whose `costIntervalStart` is before the current
month, so that notification can't cut billing again.

If you can't wait for the 1st, re-link billing yourself, either in the console or with:

```bash
gcloud billing projects link <project> --billing-account=<billing account>
```

If spend for the month is still over the cap, the next notification will trip it again
straight away. Google may eventually delete a project's resources if billing stays off.
Nothing here is precious: images are rebuilt by the deploy scripts, and losing the OAuth
token collections only means everyone signs in again.

## Tests

```bash
pip install -r reset/requirements.txt pytest
pytest tests
```

## The servers using it

| Server | Repo | Flag it sets |
| --- | --- | --- |
| QueensCoach | `ajwann/queenscoach` | `QUEENSCOACH_SHARED_BUDGET=true` |
| QueensEstate | `ajwann/queensestate` | `QUEENSESTATE_SHARED_BUDGET=true` |

Without that flag a deploy creates a per-server budget of its own, and you are back to two.

## License

MIT - see [LICENSE](LICENSE).
