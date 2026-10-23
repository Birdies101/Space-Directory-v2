# Methodology & System Specification

## 1. Purpose and audiences

The directory serves two goals with one dataset:
1. A **research-grade dataset** for academic publication.
2. A **live, public, searchable directory** for government, industry, investors, and the public.

The public directory is a filtered, read-only view of the same verified records. It never shows internal notes, unconfirmed records, or reviewer identities.

### 1.1 Audience → feature mapping
Each audience in the brief maps to concrete fields and features. Build these; don't treat them as nice-to-haves.

| Audience | What they need | Fields that power it | Directory feature |
|---|---|---|---|
| Space startups | Partners, customers, suppliers, competitors | `project_organizations` roles, sectors, value proposition | "Similar projects" panel; org network view |
| Established aerospace | New technologies, adjacent markets | sectors, stage, first-evidence date | "New this month" feed by sector; sector trend charts |
| Investors / corp dev | Business models, milestones, funding, dependencies | revenue model, traction score, financing milestones, dependencies | Comparison table (up to 5 projects); milestone timeline |
| Manufacturers / suppliers | Programs needing components, testing, software, capacity | `dependencies` (supplier_component, facility), stage S1–S3 | "Programs in development that need…" filter |
| Economic development orgs | Local capabilities, facilities, employers, supply chains | `facilities` (state, county, metro), org HQ | Map by state/county; regional cluster export |
| Universities / researchers | Commercialization cases, gaps, collaborators | academic partner role, government relationships, full history | Full dataset download (CSV/Parquet) + data dictionary + versioned releases |
| Government / associations | Bottlenecks, public-private relationships | dependencies (license_*, spectrum, launch_access), government relationships | Bottleneck dashboard; agency/program rollups |
| Non-space businesses | Uses for satellite data, connectivity, manufacturing | `end_use_industries`, sector APP/EO/COM | "Browse by industry" entry point |

## 2. System architecture

```
 DAILY (automated)                                   WEEKLY (human, 2–4 hrs)      MONTHLY (automated + 30 min)
 ┌───────────────┐   ┌────────────┐   ┌──────────┐   ┌──────────────────────┐    ┌──────────────────────┐
 │Source         │──►│Snapshot    │──►│Triage    │──►│Extraction + span     │──┐ │Digest, stale checks, │
 │connectors (17)│   │store (raw) │   │(Haiku)   │   │validation (Sonnet)   │  │ │risk-based rechecks,  │
 └───────────────┘   └────────────┘   └──────────┘   └──────────────────────┘  │ │dataset release       │
                                                                              ▼ └──────────────────────┘
 ┌───────────────┐   ┌──────────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
 │Public dir +   │◄──│Master DB         │◄──│Review console:       │◄──│Entity resolution    │
 │API + exports  │   │(Postgres)        │   │approve evidence      │   │(rules → embeddings  │
 └───────────────┘   │+ change history  │   │packets / exceptions  │   │→ Opus adjudication) │
                     └──────────────────┘   └──────────────────────┘   └─────────────────────┘
                                                      ▲
                                    Verification agent (web search) builds packets
```

### 2.1 Stack
| Function | Choice | Why |
|---|---|---|
| Master database | Postgres on Supabase | Linked tables, row-level security for public views, auto REST API, free tier |
| Pipeline | Python 3.12 (httpx, pydantic, anthropic SDK, rapidfuzz, pgvector) | Handles pagination, bulk loads, matching |
| Scheduling | GitHub Actions cron | No servers; logs kept per run |
| Snapshot store | Supabase Storage / S3, plus Wayback "Save Page Now" | Protects against link rot; reproducibility |
| Review console | Streamlit (password-protected) | Fast to build in Python; reviewer approves packets |
| Public directory | Next.js on Vercel, reading published views | Searchable, faceted, map, shareable URLs |
| Research exports | CSV + Parquet + data dictionary, versioned on Zenodo (DOI) | Citable and reproducible |

## 3. Pipeline stages

| # | Stage | Model | Mode |
|---|---|---|---|
| 1 | Collect from source connectors | none | Daily incremental; one-time bulk backfill |
| 2 | Snapshot every document (HTML/PDF + text + SHA-256) | none | Always |
| 3 | Relevance triage | `claude-haiku-5-5` | Batch API; cached system prompt |
| 4 | Structured extraction with evidence spans | `claude-sonnet-5-5` | Batch API; strict JSON schema |
| 5 | Span validation (fuzzy verbatim check, ≥ 0.92 similarity) | none | Deterministic; unsupported fields dropped |
| 6 | Entity resolution | rules → embeddings → `claude-opus-5-5` | Opus only for the ambiguous band |
| 7 | Org-first project enumeration | `claude-sonnet-5-5` + web search | Per organization, during backfill |
| 8 | Verification agent → evidence packet | `claude-sonnet-5-5` (Opus for conflicts) + web search | Per new/changed project |
| 9 | Change detection on existing projects | `claude-sonnet-5-5` | Per new evidence matched to an existing project |
| 10 | Human review | human | Weekly; exceptions only |
| 11 | Publish, digest, release | `claude-sonnet-5-5` for digest prose | Monthly |

**The AI-proposes-humans-decide rule:** stages 3–9 write only to `candidates`, `review_queue`, and `proposed_changes`. Only the review console writes to canonical tables, and every write is logged in `change_history`.

## 4. Discovery strategy: organization-first

1. **Build the organization universe first** (target 500–800 orgs) from structured T1 sources:
   - SBIR/STTR space awards
   - USAspending space-related contracts and grants
   - FAA licensees
   - FCC space station applicants
   - NOAA remote-sensing licensees
   - NASA program awardee lists
   - SEC filers with space SIC/keywords
   - Form D filers
2. **Enumerate each organization's projects** with the enumeration agent (prompt `06`).
3. **Fill gaps from document streams**: news, RSS, newsrooms, and association directories. These catch projects with no government footprint.

## 5. Methodology safeguards (the gaps, closed)

### 5.1 Inclusion funnel (publish with every release)
Report each step: candidates collected (by channel) → triaged in → extracted → resolved to unique projects → excluded (by reason code) → accepted (by confidence). Generated automatically from `candidates`, `exclusions`, and `projects`.

### 5.2 Coverage validation
Two independent checks, reported in every release:

1. **Benchmark recall.** Freeze reference lists *before* collection starts and measure what fraction appears in the directory:
   - NASA CLPS, Commercial LEO Destinations, Tipping Point, and ACO awardees
   - Space Force/SpaceWERX STRATFI/TACFI recipients
   - FAA active licenses
   - NOAA licensees
   - A random sample of 100 SBIR space awards

   Target ≥ 90% recall on each benchmark.
2. **Capture–recapture estimate** of the total universe:
   - Each project records which discovery channels found it.
   - Compute the Chapman estimator for each channel pair, and a log-linear multi-list model (Rcapture or Python equivalent) across all six channels.
   - Report the estimated total N̂ with a 95% CI and the implied coverage, overall and by sector.
   - Channels are not independent (government-funded projects appear in several), so report the log-linear model with interaction terms as primary.

### 5.3 Inter-rater reliability
See codebook §11. A built-in "blind second-coder" mode in the review console hides first-coder values, and an `irr.py` script computes κ.

### 5.4 Source preservation
Every evidence URL is stored with access date, a local snapshot (HTML + extracted text + PDF where applicable), its SHA-256, and a Wayback Machine capture URL. Evidence spans are validated against the stored text, never the live page.

### 5.5 Crosswalk identifiers
Organizations: UEI, CAGE, CIK, FCC FRN, FAA licensee name, NOAA licensee name, website domain, LEI.

Projects: contract/award IDs, FAA license numbers, FCC call signs/file numbers, NORAD/COSPAR IDs, TechPort IDs.

These drive deterministic deduplication and let outside researchers join to other datasets.

### 5.6 Gold-standard evaluation set
Before scaling, hand-label 150 documents (triage) and 60 projects (extraction, stage, sector, dedupe). Measure every pipeline prompt against them. Minimum bars before the full run:

| Prompt | Bar |
|---|---|
| Triage | Recall ≥ 0.97 (missing projects is worse than extra review) |
| Extraction | Field accuracy ≥ 0.90 |
| Dedupe | Pairwise F1 ≥ 0.95 |
| Stage | κ vs. gold ≥ 0.75 |

Re-run the evals whenever a prompt or model changes.

### 5.7 Versioning and citation
- Monthly dataset releases (`vYYYY.MM`) with a frozen snapshot, data dictionary, codebook version, funnel, coverage report, and IRR report.
- Releases are deposited on Zenodo for a DOI.
- `change_history` makes any past state of any record reconstructable, which supports longitudinal research.

### 5.8 Licensing and terms of use
- U.S. federal data is generally public domain. Still, record each source's terms in `sources_registry.yaml` and check them before building the connector.
- The public directory shows **facts plus links**, not copied text. Evidence notes are short factual paraphrases. Stored verbatim spans are internal only.
- Some sources require an account and restrict redistribution (Space-Track user agreement; commercial databases like Crunchbase/PitchBook). Use them for discovery or verification only. Never republish their records.
- Dataset license: CC BY 4.0 for directory-authored fields.

### 5.9 Corrections and transparency
- A public "suggest a correction / submit a project" form feeds the review queue with source type `T4_submission`. It must be verified like any lead.
- Each public record shows last-reviewed date, confidence, and its sources.
- A methods page discloses AI use, the codebook, and the review process.

### 5.10 Bias audits (quarterly)
Compare the sector, state, and org-size distribution against the benchmarks and the capture–recapture estimates. Projects with no government footprint are the likeliest to be under-covered. Watch the share of projects found *only* via news/company channels.

## 6. Update routine

| Cadence | Automated | Human |
|---|---|---|
| Daily | Collect, snapshot, triage, extract, resolve; verification agent drafts packets; staleness flags | — |
| Weekly | Priority-sort queue: consequential stage changes, new contracts/launches/financing, conflicts | Review exceptions only (target 2–4 hrs at ~600 projects) |
| Monthly | Digest draft, risk-based rechecks, dataset release build, funnel/coverage reports | Approve digest and release (~30 min) |
| Quarterly | Coverage + bias audit, IRR sample draw, source-registry health check | Second-coder session, codebook review |

The 2–4 hrs/week figure is a planning estimate for a directory of about 600 projects once the automation is stable. It will rise with scope.

## 7. Timeline (with this design)

| Week | Goal |
|---|---|
| 1 | Codebook frozen, schema live, gold set labeled, benchmarks frozen |
| 2 | T1 connectors + bulk backfill, org universe built (500+ orgs) |
| 3 | Triage/extraction/resolution passing eval bars, enumeration run |
| 4 | Verification packets for all candidates, review console live, first 300 accepted |
| 5 | Document-stream connectors, gap-filling, 500–700 accepted |
| 6 | IRR sample, coverage report, public directory launch, release v1 |

The constraint is human review hours, not discovery.
