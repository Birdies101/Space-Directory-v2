# Project context for Claude Code — U.S. Commercial Space Project Directory

You are building a research-grade dataset and live public directory of 500–700 U.S. commercial space **projects** (not companies). Read these before any work and treat them as binding:
- `docs/codebook.md`: inclusion, unit of analysis, sectors, stages, scores, confidence. **Never hardcode a rule that contradicts it.** Load codebook text into prompts at runtime from this file.
- `docs/methodology.md`: architecture, pipeline stages, safeguards, cadence.
- `db/schema.sql`: the canonical data model.
- `config/sources_registry.yaml`: the source connectors to build.
- `prompts/pipeline/*.md`: runtime prompts. Code loads the SYSTEM/USER sections from these files. Don't inline prompt text in Python.

## Non-negotiable rules
1. **AI proposes, humans decide.** Pipeline code writes only to `sources`, `candidates`, `review_queue`, and `proposed_changes`. Only `review/` (the console) writes canonical tables, inside a transaction that sets `app.change_reason` and `app.review_item_id`.
2. **Every field needs evidence.** No field is stored without an evidence row whose span passes deterministic validation against the *stored snapshot text*.
3. **Snapshot first.** Fetch → store raw + text + SHA-256 → request a Wayback capture → only then process.
4. **Deterministic before model.** Use identifiers, rules, and fuzzy matching first; call a model only for what remains.
5. **Model tiers:** triage `claude-haiku-5-5`; extraction, verification, change detection, and digest `claude-sonnet-5-5`; dedupe adjudication, conflict escalation, and IRR coding `claude-opus-5-5`. Put model IDs in `config/models.yaml`, not in code. Check the Anthropic docs for current model IDs, the Batch API, prompt caching, structured outputs, and server-side web search tool syntax before using them.
6. **Batch and cache.** High-volume calls (triage, extraction) go through the Message Batches API. Codebook-bearing system prompts use prompt caching.
7. **Reproducibility.** Log on every candidate: model ID, prompt file hash, codebook version, and timestamp.
8. **Respect sources.** Verify each endpoint's current docs, auth, rate limits, and terms before writing its connector. SEC requires a descriptive User-Agent. Space-Track and paid databases are verification/discovery only, never republished. Back off on 429s.
9. **Evals gate scaling.** No full run until `evals/` shows each prompt meets the bars in methodology §5.6.
10. **Secrets** live in `.env` (never committed): `ANTHROPIC_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SAM_API_KEY`, `TECHPORT_TOKEN`, `SPACETRACK_USER/PASS`, `SEC_USER_AGENT`.

## Repo layout
```
config/        models.yaml, sources_registry.yaml, settings.py (pydantic-settings)
db/            schema.sql, migrations/, seed/
pipeline/
  connectors/  one module per registry key; common BaseConnector (paginate, retry, incremental cursor)
  snapshot.py  fetch, store, hash, wayback
  triage.py extract.py spans.py resolve.py enumerate_orgs.py verify.py changes.py
  llm.py       Anthropic client wrapper: batch submit/poll, caching, schema validation, retry, cost log
  models.py    pydantic models mirroring every prompt's output schema
review/        Streamlit console
web/           Next.js public directory
analysis/      funnel.py, coverage.py (capture–recapture), irr.py, bias_audit.py, release.py
evals/         gold/, run_evals.py, reports/
jobs/          daily.py, weekly.py, monthly.py, quarterly.py
.github/workflows/  cron schedules
tests/
```

## Conventions
- Python 3.12, `uv` for dependencies, `ruff` + `mypy --strict` on `pipeline/` and `analysis/`, `pytest`.
- IDs: `PRJ-000001`, `ORG-000001`, `SRC-<sha8>`, `EV-…`. Permanent; never reused.
- All dates ISO-8601; store `date_precision`.
- Every job is idempotent and resumable. Store incremental cursors per connector in a `connector_state` table.
- Each job writes a structured run log (counts in/out per stage, cost, errors) to `pipeline_runs`.
