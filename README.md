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
```

**Google Cloud has no hard spending limit.** A budget only sends email; nothing stops
spending on its own. This is the documented substitute.

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

The function's identity holds **Project Billing Manager on that one project**, not the
billing-account-wide admin role Google's own tutorial uses, so it cannot touch anything
else on the billing account.

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

`permitted to: True` is the part worth checking. Then re-run without `SPEND_CAP_DRY_RUN` to
arm it.

## Recovering after it fires

The servers return 503 and the project's paid services stop. Re-link billing in the console,
or re-run the server's own deploy script, which links it again. Google may eventually delete
a project's resources if billing stays off — nothing here is precious, since images are
rebuilt by the deploy scripts and losing the OAuth token collections only means everyone
signs in again.

## The servers using it

| Server | Repo | Flag it sets |
| --- | --- | --- |
| QueensCoach | `ajwann/queenscoach` | `QUEENSCOACH_SHARED_BUDGET=true` |
| QueensEstate | `ajwann/queensestate` | `QUEENSESTATE_SHARED_BUDGET=true` |

Without that flag a deploy creates a per-server budget of its own, and you are back to two.

## License

MIT - see [LICENSE](LICENSE).
