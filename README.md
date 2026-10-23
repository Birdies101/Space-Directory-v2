# U.S. Commercial Space Project Directory — Build Kit

A complete specification and prompt set for building a research-grade dataset and a live public directory of 500–700 U.S. commercial space projects.

## Decisions locked in
| Decision | Choice |
|---|---|
| Unit of analysis | A project is a named system, vehicle, service, facility, or program. Missions, contract phases, and licenses are evidence. Companies, projects, and partnerships are separate linked records. |
| U.S. qualification | Qualifies if the lead org qualifies for U.S. federal grant/award funding: a federal award recipient, or SAM.gov-registered. A U.S. entity without either is capped at "partially verified". |
| Sectors | 14 controlled codes + 18 end-use industries |
| Stages | S0 announced → S6 terminated, each with an explicit evidence rule |
| Purpose | Both: academic dataset (versioned, DOI, IRR, coverage estimates) **and** a live public searchable directory for government, industry, investors, and the public |

## What's in the kit
| Path | What it is |
|---|---|
| `CLAUDE.md` | Standing context and rules for Claude Code (put at the repo root) |
| `docs/codebook.md` | The coding rules every prompt and reviewer follows |
| `docs/methodology.md` | Architecture, audience → feature map, safeguards, cadence, timeline |
| `db/schema.sql` | Postgres schema: orgs, projects, partnerships, milestones, government relationships, dependencies, facilities, evidence, sources, staging, exclusions, audit history, reliability, releases, public views |
| `config/sources_registry.yaml` | 22 source connectors across six discovery channels |
| `prompts/pipeline/01–08` | Runtime prompts: triage, extraction, dedupe, verification agent, change detection, org enumeration, digest, reliability coder |
| `prompts/build/BUILD_PROMPTS.md` | Ten phase prompts that make Claude Code build the system, each with acceptance checks |

## How to use it
1. Create a GitHub repo, copy this kit in, and create a Supabase project and an Anthropic API key. Register for the free SAM.gov API key and NASA TechPort token.
2. Open the repo in Claude Code and paste the Phase 1 prompt. Proceed phase by phase, and only move on when acceptance checks pass.
3. Phase 3 pauses for you to hand-label the gold set (roughly 4–6 hours). This is what lets you trust the pipeline at scale.
4. Freeze the benchmark lists (Phase 10 describes them) **before** the main collection run.

## What changed from the original emails
- **Added sources:** SBIR/STTR, NOAA remote-sensing licenses, GCAT/SATCAT, named NASA programs, SpaceWERX/DIU/DARPA, SEC Form D, public submissions.
- **Methodology gaps closed:**
  - Inclusion funnel
  - Benchmark recall + capture–recapture coverage estimate
  - Human–human and model–human reliability
  - Source snapshots + Wayback
  - Crosswalk identifiers
  - Gold-set evals gating each prompt
  - Versioned DOI releases
  - Licensing rules
  - Corrections form
  - Bias audits
- **Efficiency:**
  - Organization-first discovery
  - Pre-built evidence packets, so the reviewer approves instead of researching
  - Python + Postgres instead of no-code
  - Batch API + prompt caching
  - Deterministic matching before any model call
  - Weekly exception-only review
