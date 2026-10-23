# Build Prompts — paste into Claude Code one phase at a time

**Setup:** create an empty repo and copy this whole kit into it (`CLAUDE.md` at the root). Open Claude Code in the repo. Run the phases in order. Each phase ends with acceptance checks. Don't start the next phase until they pass. Commit after each phase.

---

## Phase 1 — Scaffold, database, config
```
Read CLAUDE.md, docs/codebook.md, docs/methodology.md, db/schema.sql and config/sources_registry.yaml in full before writing anything.

Build the project scaffold exactly as laid out in CLAUDE.md "Repo layout":
1. uv project with dependencies: anthropic, httpx, pydantic, pydantic-settings, psycopg[binary], supabase, rapidfuzz, pgvector, trafilatura (HTML→text), pypdf, pyyaml, tenacity, streamlit, pandas, pyarrow, statsmodels, scikit-learn, pytest, ruff, mypy.
2. db/: apply schema.sql as migration 0001. Add migration 0002 for the operational tables CLAUDE.md mentions (connector_state, pipeline_runs, llm_calls with tokens/cost/model/prompt_hash). Add Postgres roles `pipeline` (insert into sources/candidates/review_queue/proposed_changes only) and `reviewer` (full canonical writes), plus Supabase RLS so the anon key can read ONLY the public_* views.
3. config/settings.py (pydantic-settings reading .env) and config/models.yaml (model IDs per pipeline stage).
4. pipeline/models.py: pydantic models for EVERY output schema in prompts/pipeline/01–08, with enums matching the codebook vocabularies exactly. Build those vocabularies by parsing docs/codebook.md tables, so the codebook stays the single source of truth; add a test that fails if the code and codebook disagree.
5. pipeline/llm.py: a client wrapper that loads a prompt file, splits SYSTEM / USER template, injects codebook sections by marker (e.g. {FULL_CODEBOOK_MARKDOWN}, {CODEBOOK_§4_§5_§6_§8}), applies prompt caching to the system block, validates output against the pydantic model (one repair retry on failure), logs to llm_calls, and supports both synchronous calls and Message Batches (submit, poll, collect). Look up the current Anthropic SDK docs for batches, caching and structured outputs first.
6. A seed script that inserts the sector table and an ID allocator.

Acceptance: `pytest` passes (include a test that every prompt file parses into SYSTEM/USER and every placeholder resolves); migrations apply cleanly to a fresh Supabase project; RLS test proves anon cannot read `projects` or `evidence.span_text`.
```

## Phase 2 — Snapshot store and source connectors
```
Build pipeline/snapshot.py and pipeline/connectors/.

snapshot.py: given a URL, fetch with httpx (timeouts, retries, polite rate limit per domain); store raw bytes to Supabase Storage at snapshots/{sha256}.{ext}; extract text (trafilatura for HTML, pypdf for PDF) to texts/{sha256}.txt; insert into `sources` (dedupe on sha256); request a Wayback Save Page Now capture asynchronously and record wayback_url when available. Structured API records (JSON rows) are also snapshotted: store the JSON and a rendered text version, so spans can be validated against them.

Connectors: a BaseConnector with paginate(), incremental cursor in connector_state, backoff on 429/5xx, and a `discovery_channel` + `tier` from the registry. Implement in this priority order: usaspending, sbir, sam_entity (lookup), faa_licenses, fcc_icfs, noaa_crsra, gcat, celestrak_satcat, techport, nasa_programs, sec_efts (with Form D), sam_opportunities, then RSS-based ones (nasa_news, spacewerx_diu, trade_press, company_newsrooms with auto-discovery of feed URLs from org websites).

FOR EACH CONNECTOR, BEFORE CODING: fetch and read its current official API docs or page, confirm endpoint, auth, filters, rate limits and terms of use, and write those findings into the registry entry (terms_note). If a source has no API, write a careful scraper and a fixture-based test. If a source cannot be reached from this environment, say so and stop on that connector rather than guessing its format.

Each connector produces normalized "documents" (source_id, channel, tier, title, url, published_date, text) plus, for structured sources, a typed record (award, license, filing, catalog entry) stored in a `raw_records` table with its crosswalk identifiers extracted deterministically (UEI, PIID/FAIN, FCC file no., NORAD, license no.).

Acceptance: each connector has a fixture test; a backfill dry-run of usaspending + sbir for one fiscal year completes and reports counts; re-running is idempotent (no duplicate sources).
```

## Phase 3 — Gold set and evaluation harness (do this BEFORE scaling any model stage)
```
Build evals/.
1. evals/gold/sample.py: draw a stratified sample of 150 stored documents across channels and tiers for triage labeling, and 60 candidate projects across sectors for extraction/stage/dedupe labeling. Also generate 80 labeled dedupe pairs (40 true matches including renames/phases, 40 hard negatives: same company, different product).
2. A small Streamlit labeling page (in review/ but separate route) where I label the gold items using the codebook's vocabularies. Labels are stored in evals/gold/*.jsonl.
3. evals/run_evals.py: runs each pipeline prompt over the gold set and reports: triage recall/precision; per-field extraction accuracy and span-validation pass rate; dedupe pairwise precision/recall/F1; stage and sector Cohen's kappa vs gold; cost per item. Writes evals/reports/{date}_{prompt_hash}.md.
4. Bars (methodology §5.6): triage recall ≥ 0.97, extraction field accuracy ≥ 0.90, dedupe F1 ≥ 0.95, stage κ ≥ 0.75. Make `run_evals.py --gate` exit non-zero if any bar fails; later phases call it.

Pause after step 2 and tell me the labeling page is ready. Continue only once I've labeled.
```

## Phase 4 — Triage, extraction, span validation
```
Implement pipeline/triage.py, pipeline/extract.py and pipeline/spans.py, following prompts/pipeline/01_triage.md and 02_extraction.md exactly (load prompt text from the files).
- Triage: Batch API, haiku tier, cached system prompt. Route per the file's ROUTING section, including the 2% irrelevant-sample audit into review_queue.
- Extraction: Batch API, sonnet tier, full codebook in the cached system block. Validate output into pydantic models.
- spans.py: implement the SPAN VALIDATION algorithm in 02_extraction.md exactly (NFKC, whitespace/quote/dash normalization, exact substring → fuzz.partial_ratio ≥ 92; field drop; >30% failure flag; name/lead-org drop → review). Validate against the STORED text file, never the live page.
- Write results to `candidates` with model_versions and prompt hash.
Then run evals for triage and extraction. If a bar fails, show me the failure cases grouped by type and propose prompt edits (change the prompt FILE, not inline code), re-run, and report the before/after.

Acceptance: `run_evals.py --gate --stages triage,extract` passes; a 500-document run finishes through Batches with a cost report.
```

## Phase 5 — Organization universe and entity resolution
```
Implement pipeline/resolve.py and the org universe build.
1. Org universe: from raw_records (usaspending, sbir, faa, fcc, noaa, sec, nasa_programs) create or merge organizations using deterministic keys first (UEI > CIK > FCC FRN > normalized domain > normalized legal name with suffix stripping: Inc, LLC, Corp, Technologies...). Look up SAM entity for each org with a UEI to fill us_basis/address/CAGE. Compute name embeddings (pgvector).
2. Project resolution, exactly per prompts/pipeline/03_entity_resolution.md: exact identifier match → blocking → weighted score → auto-merge band / Opus adjudication band / distinct band. Use the same pattern for orgs first, with an org variant of prompt 03 (write it as prompts/pipeline/03b_org_resolution.md, mirroring 03).
3. Routing per the prompt file. Ambiguous cases create review_queue items of type `merge` with a side-by-side packet.
4. Record discovery_channel for every candidate→project link, so projects.discovery_channels is complete (needed for capture–recapture).

Acceptance: dedupe eval bar passes; on the backfill data, report orgs created, auto-merges, adjudications, and review items, plus 20 random auto-merges for me to spot-check.
```

## Phase 6 — Enumeration agent and verification agent
```
Implement pipeline/enumerate_orgs.py (prompts/pipeline/06) and pipeline/verify.py (prompts/pipeline/04) as tool-using agents on the Claude API.
- Tools: the server-side web search tool, a web fetch tool, plus custom tools wrapping our connectors: lookup_sam, lookup_usaspending, lookup_sbir, lookup_fcc, lookup_faa, lookup_satcat, and snapshot(url) → {source_id, text excerpt}. Check current Anthropic docs for tool-use and web search syntax.
- Enforce the per-item tool-call budgets in the prompt files. Escalate verify to the opus tier when conflicts touch stage, us_basis or identity.
- Re-validate every span in the packet with spans.py. Recompute confidence deterministically from codebook §8 in code; if the model's confidence disagrees, use the computed one and note the disagreement in the packet.
- Write packets to review_queue with priority and `consequential` set.
- Run enumeration over the org universe in priority order (orgs with the most federal records first), concurrency-limited, resumable.

Acceptance: run on 25 orgs and show me 5 full packets; report average tool calls, cost and time per org/project; packet JSON validates; confidence recomputation unit-tested against codebook examples.
```

## Phase 7 — Review console and change detection
```
Build review/ (Streamlit, password-protected via env) and pipeline/changes.py (prompts/pipeline/05).
Console views:
1. Queue: filter by item_type, priority, consequential, sector. Sorted by priority then age.
2. Packet view: proposed record on the left; evidence list on the right with tier badges, span highlighted inside the snapshot text, links to the live URL and the Wayback copy; conflicts panel; reviewer checklist. Buttons: Approve / Edit-then-approve / Reject (requires exclusion reason code) / Defer. Keyboard shortcuts.
3. Merge view: side-by-side for dedupe items.
4. Change view: field-level diffs for proposed_changes; consequential changes require a second confirmation and show whether the evidence bar is met.
5. Blind second-coder mode for IRR: hides existing codes and records into reliability_codings.
6. Record history: render change_history for any project as a timeline.
All approvals write canonical tables in ONE transaction setting app.change_reason and app.review_item_id, so the audit trigger captures them. Set last_reviewed and next_review_due per codebook §10.

changes.py: runs prompt 05 when new evidence attaches to an accepted project; writes proposed_changes + review_queue items. Also a staleness job: projects with no new evidence in 24 months → `stale` review item (never auto-change stage).

Acceptance: end-to-end test — a fixture document flows from connector → triage → extract → resolve → verify → console approval → canonical tables → change_history row; a second fixture with a launch triggers a proposed stage change that needs consequential confirmation.
```

## Phase 8 — Public directory, API, exports
```
Build web/ (Next.js App Router, TypeScript, Tailwind), deployed to Vercel, reading ONLY the public_* views via the Supabase anon key.
Pages and features (from docs/methodology.md §1.1, audience → feature mapping):
- Search with full-text + facets: sector, stage, state, end-use industry, customer type, revenue model, confidence, government agency/program, dependency type, traction score.
- Project page: summary, stage badge, intent/traction, value proposition, organizations with roles, milestone timeline, government relationships, dependencies, sources list (title, publisher, date, tier, live link + archived link), last reviewed, confidence badge, "suggest a correction" button.
- Organization page: projects, roles across the network, facilities.
- Browse by industry (non-space businesses), and "Programs in development that need…" supplier view (dependencies of type supplier_component/facility with stage S1–S3).
- Map by state/county (facilities + HQ) with regional CSV export.
- Network graph (org↔project) for a filter selection.
- Compare up to 5 projects side by side.
- Monthly digest archive, methods page (codebook, AI-use disclosure, funnel, coverage and IRR from the latest release), changelog.
- Downloads: current release CSV/Parquet + data dictionary + DOI link. Public read API = Supabase REST on the views, documented on an /api page.
- Submission/correction form → inserts into review_queue (type `submission`) through a rate-limited server action with captcha.
Accessibility AA, works at phone width, OpenGraph per project.

Acceptance: Lighthouse ≥ 90 for accessibility and performance on the search and project pages; anon key verified unable to read internal tables; submission lands in the queue.
```

## Phase 9 — Scheduling, digest, releases
```
Build jobs/ and .github/workflows/:
- daily (06:00 ET): all daily/RSS connectors incremental → snapshot → triage → extract → resolve → verify/changes. Job summary posted to the run log.
- weekly (Mon): weekly connectors (FAA, FCC, GCAT, SATCAT, SEC, SBIR); queue health report emailed to me (open items by priority, oldest item age, consequential items awaiting review).
- monthly (1st): risk-based recheck (projects with next_review_due ≤ today → verify task `recheck`); build the digest delta in SQL; run prompts/pipeline/07 for a draft into review_queue for approval; build release vYYYY.MM via analysis/release.py (freeze export, data dictionary from schema comments, funnel, coverage, IRR) and prepare a Zenodo deposit (draft; I publish).
- quarterly: coverage + bias audit, draw the IRR sample (10% stratified by sector) into the review queue as `reliability_sample`, source-registry health check (endpoints still alive, terms unchanged).
Each workflow: concurrency group, timeout, failure notification, cost ceiling (abort if the daily model spend estimate exceeds the CONFIG limit).

Acceptance: dry-run every job against staging; a cost and count summary for each.
```

## Phase 10 — Research analysis tooling
```
Build analysis/:
- funnel.py: inclusion funnel by channel → triage → extracted → unique → excluded by reason → accepted by confidence. Outputs a table + Sankey (Plotly) for the methods page.
- coverage.py: (a) benchmark recall against the frozen `benchmarks` table (load CLPS, CLD, Tipping Point, ACO, STRATFI/TACFI, FAA active licenses, NOAA licensees, random 100 SBIR space awards, frozen BEFORE the main collection run, with a frozen_at date); (b) capture–recapture: Chapman estimator per channel pair, plus a log-linear multi-list model (Poisson GLM via statsmodels, with pairwise interaction terms selected by AIC) across the six discovery channels, overall and per sector, with 95% CIs. Report N̂, implied coverage, and caveats about channel dependence.
- irr.py: Cohen's κ (nominal), quadratic-weighted κ (ordinal intent/traction/stage order), percent agreement, bootstrap CIs; human–human and model–human (prompt 08 run via Batches). Flags fields with κ < 0.70.
- bias_audit.py: distributions by sector/state/org type vs benchmarks; share of projects found only via company/news channels.
- release.py: assembles all of the above into the release record and methods page JSON.
- notebooks/ with a starter network-analysis notebook (networkx: degree, betweenness, communities on the org↔project graph).

Acceptance: run on current data and show me the coverage report and IRR report outputs.
```

---

## Ongoing: prompt-maintenance prompt
Use whenever a reviewer pattern repeats (the same kind of edit 5+ times):
```
Look at review_queue decisions from the last 30 days where the reviewer edited or rejected a packet. Group edits by field and pattern. For the top 3 patterns, find which pipeline prompt produced the error, propose a minimal edit to that prompt FILE (or a codebook clarification, if the rule itself is ambiguous; bump the codebook version and add a revision-log line), run evals before/after, and show me the diff and the metric change. Don't merge until I approve.
```
