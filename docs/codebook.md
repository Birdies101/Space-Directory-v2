# Codebook — U.S. Commercial Space Project Directory (v1.0)

This codebook is the single source of truth for inclusion, classification and coding. Every pipeline prompt, every human reviewer, and every reliability test uses it. Change it only through a versioned revision (bump the version, log the change in §12, re-code affected records).

---

## 1. Unit of analysis

A **project** is a named, distinct system, vehicle, service, facility, or program that has its own development arc and a commercial purpose.

A project is **not** a company. Companies, projects, and the relationships between them are stored as separate, linked records (see `db/schema.sql`). A company can have many projects; a project can involve many organizations.

### 1.1 What is evidence, not a project
These attach to a project as milestones or evidence. They never become separate project records:
- Individual missions, launches, or flights of the same vehicle/system
- Contract phases, options, modifications, and task orders
- Licenses, permits, FCC authorizations, and spectrum filings
- Individual satellites within a constellation
- Funding rounds, press releases, and conference presentations

### 1.2 Split rule (when two efforts are separate projects)
Two efforts are separate projects if they differ on **at least two** of:
1. The product or system delivered
2. The target customer or market
3. The lead organization
4. The funding line or government program
5. Independent stage progression (one can be operational while the other is still in development)

Block upgrades and versions (e.g., "Block 2", "v2") stay with the parent unless they carry a new name **and** separate funding.

### 1.3 Edge cases
| Situation | Coding |
|---|---|
| Constellation | One project; satellites are assets |
| Single-product startup | One org + one project (still two records) |
| Platform/bus supplier | Each named product line is a project |
| Spaceport or test facility | One infrastructure project per site, if offered to third parties |
| NASA program with multiple awardees (e.g., CLPS) | Each awardee's lander/service is its own project; the program is a `government_relationship` |
| Joint venture | One project; the JV is an org; parents linked as `parent` |
| Renamed project | One record; old name goes into `aliases` |
| Acquired company's product continues | Same project; lead org changes; log in change history |

---

## 2. Inclusion tests

A candidate is accepted when it passes **all four** tests.

| Test | Passes when |
|---|---|
| **Identity** | The project and its lead organization can both be named |
| **Space connection** | The project's product or service operates in, travels to, or directly depends on space-based assets (applications must depend on satellite data, connectivity, or PNT) |
| **Commercial relevance** | Commercial intent score ≥ 1 (see §5) |
| **Evidence** | At least one source of tier T1–T3 supports the project's existence |

### 2.1 U.S. connection rule
**A project qualifies if its lead organization (or the project's U.S. operating entity) qualifies for U.S. federal grant or award funding.**

Code `us_basis` using the strongest evidence available:

| Code | Evidence | Confidence effect |
|---|---|---|
| `federal_award_recipient` | Has received a U.S. federal grant, contract, SBIR/STTR, OTA, or funded Space Act Agreement (USAspending, SBIR.gov, NASA records) | None (strongest) |
| `sam_registered` | Active SAM.gov entity registration with a U.S. physical address (has a UEI) | None |
| `us_entity_unverified` | U.S.-incorporated entity with no award or SAM record found | Caps record at `partially_verified`; flagged for review |

Also record:
- `sbir_eligible` (true/false/unknown): SBIR additionally requires more than 50% U.S. ownership and control.
- `foreign_parent` (true/false) and `parent_country`.

Exclude: foreign entities with no U.S. operating entity (reason code `NOT_US`).

### 2.2 Exclusion reason codes
Every rejected candidate gets exactly one primary code. It is kept in the `exclusions` table, never deleted.

| Code | Meaning |
|---|---|
| `NO_PROJECT` | Company with no identifiable project |
| `NOT_SPACE` | No meaningful space connection (includes general aeronautics) |
| `NOT_COMMERCIAL` | Pure science/government mission with no commercial pathway |
| `NOT_US` | Fails §2.1 |
| `SPECULATIVE` | Concept with no evidence of development or funding |
| `INSUFFICIENT_EVIDENCE` | Only T4 (lead-only) sources found |
| `DUPLICATE` | Merged into an existing project (record the target project ID) |

Cancelled or abandoned projects are **not** excluded. They are kept as stage `S6_terminated` historical cases.

---

## 3. Sector taxonomy

Each project gets one **primary** sector and up to two **secondary** sectors.

| Code | Sector | Includes |
|---|---|---|
| `LCH` | Launch & reentry | Launch vehicles, launch services, reentry/return vehicles, rideshare |
| `SPT` | Spaceports & test infrastructure | Spaceports, launch sites, test stands, environmental test facilities |
| `COM` | Satellite communications | Broadband, direct-to-device, IoT, relay, optical comms |
| `EO` | Earth observation & remote sensing | Optical, SAR, hyperspectral, RF geolocation, weather, climate sensing |
| `PNT` | Positioning, navigation & timing | Alternative PNT, GNSS augmentation, space-based timing |
| `BUS` | Spacecraft & platforms | Satellite buses, spacecraft manufacturing, hosted payload platforms |
| `CMP` | Components & subsystems | Propulsion, power, avionics, optics, structures, materials, radiation-hardened electronics |
| `ISM` | In-space manufacturing & research | Microgravity manufacturing, biotech, materials processing, payload services |
| `ISL` | In-space servicing, logistics & debris | Refueling, inspection, tugs/OTVs, debris removal, life extension |
| `SDA` | Space domain awareness | Tracking, catalog services, space traffic management |
| `LUN` | Lunar & cislunar | Landers, rovers, lunar comms/nav, ISRU, cislunar transport |
| `STN` | Stations & habitats | Commercial LEO destinations, modules, habitats |
| `GND` | Ground segment & software | Ground stations, ground-station-as-a-service, mission ops, flight software, data platforms |
| `APP` | Downstream applications | Space-enabled products sold to non-space industries |

### 3.1 End-use industries (multi-select)
These serve the non-space business audience.

`agriculture`, `insurance`, `logistics_supply_chain`, `maritime`, `energy_utilities`, `mining`, `finance`, `telecom`, `climate_environment`, `defense_security`, `civil_government`, `disaster_response`, `aviation`, `automotive`, `construction_infrastructure`, `media`, `healthcare_biotech`, `research`

---

## 4. Stage definitions

The stage is the **highest stage for which qualifying evidence exists**. Every stage assignment cites at least one evidence row.

| Code | Stage | Qualifying evidence |
|---|---|---|
| `S0_announced` | Announced | Public announcement, concept unveiling, or pending filing (e.g., FCC application) with no funding evidence |
| `S1_funded` | Funded | Award, contract, funded Space Act Agreement, or investment round explicitly tied to this project |
| `S2_development` | In development | Dated within 24 months: hardware/software build, design review (PDR/CDR), subsystem test, FAA license application, manufacturing facility, or project-specific hiring |
| `S3_demonstrated` | Demonstrated | Flight, launch, on-orbit demo, or full-system test in a relevant environment |
| `S4_operational` | Operational | Delivering a product or service to customers on an ongoing basis |
| `S5_suspended` | Suspended | Public pause, or an automated staleness flag (no new evidence in 24 months) confirmed by a reviewer |
| `S6_terminated` | Terminated | Cancellation, company dissolution, or end of service with no successor |

**Consequential changes** are moves to `S4`, `S5`, or `S6`, and any stage regression. These require:
- Human approval, **and**
- One T1/T2 source, or two independent T3 sources.

The AI proposes stage changes. It never applies them silently.

---

## 5. Commercial intent vs. commercial traction

These are scored separately and are never collapsed into one number.

**Commercial intent (0–3)**
| Score | Meaning |
|---|---|
| 0 | No commercial aim stated (fails inclusion) |
| 1 | A commercial market aim is stated |
| 2 | Defined product, customer segment, and revenue model |
| 3 | Commercial contracting structure in place (fixed-price service purchase, commercial customer pipeline, published pricing) |

**Commercial traction (0–4)**
| Score | Meaning |
|---|---|
| 0 | No customer evidence |
| 1 | LOI, MOU, or named prospective customer |
| 2 | Signed contract or named paying customer (government customers count) |
| 3 | Deployed service generating revenue |
| 4 | Repeat purchases, multiple paying customers, or disclosed recurring revenue |

Traction scores of 2 or higher based only on a company's own claim (T2) need a T1 or T3 corroboration before the record can be `verified`.

---

## 6. Commercial fields

**Customer type** (multi): `gov_civil`, `gov_defense`, `gov_state_local`, `gov_foreign`, `commercial_space`, `commercial_nonspace`, `consumer`, `research_academic`

**Revenue model** (multi): `service_fee`, `hardware_sale`, `government_contract`, `data_subscription`, `licensing_ip`, `capacity_lease`, `launch_service`, `ride_share`, `software_saas`, `not_yet_known`

**Value proposition**: no more than 40 words, factual. It must say who pays, for what, and why. No marketing adjectives.

**Dependency types**: `launch_access`, `supplier_component`, `ground_infrastructure`, `spectrum_fcc`, `license_faa`, `license_noaa`, `export_control`, `anchor_customer`, `financing`, `key_partner`, `facility`

**Milestone types**: `award`, `financing`, `design_review`, `test`, `license_applied`, `license_granted`, `launch`, `demo_success`, `demo_failure`, `service_start`, `customer_contract`, `anomaly`, `delay`, `suspension`, `termination`, `acquisition`

**Organization roles on a project**: `lead`, `partner`, `supplier`, `customer`, `investor`, `funder`, `launch_provider`, `parent`, `academic_partner`

---

## 7. Source tiers

| Tier | Type | Examples | Use |
|---|---|---|---|
| `T1` | Official government and regulatory records | USAspending, SAM.gov, SBIR.gov, FAA, FCC, NOAA, SEC filings, NASA award pages, Space-Track | Strongest evidence |
| `T2` | Organization's own official disclosures; peer-reviewed papers | Company press releases, investor decks, annual reports | Strong for existence; self-interested for traction |
| `T3` | Reputable specialist or general press | SpaceNews, Payload, Via Satellite, Reuters, Bloomberg | Corroboration |
| `T4` | Leads only | Directories, association member lists, conference agendas, social media, aggregators | Discovery only; never sufficient evidence |

---

## 8. Confidence

| Level | Rule | Public directory |
|---|---|---|
| `verified` | At least 2 independent sources, including at least one T1/T2, supporting existence **and** current stage; every required field backed by a validated span | Shown |
| `partially_verified` | One T1/T2 source, or 2 or more T3 sources; or some required fields lack support; or `us_basis = us_entity_unverified` | Shown with badge |
| `unconfirmed` | Only one T3 source | Hidden (review queue only) |

---

## 9. Required fields for acceptance

A record cannot be accepted without all of these:
- canonical name
- lead organization
- `us_basis`
- primary sector
- stage plus stage evidence
- commercial intent score
- commercial traction score
- at least one evidence row
- value proposition
- last-reviewed date

---

## 10. Review cadence (risk-based)

| Condition | Next review due |
|---|---|
| Stage S0–S1 | 90 days |
| Stage S2–S3 | 120 days |
| Stage S4 | 180 days |
| Stage S5–S6 | 365 days |
| New milestone detected by monitoring | Immediate (review queue) |
| Confidence is `partially_verified` | Halve the interval |

---

## 11. Reliability protocol

- Double-code a random sample of at least 10% of accepted records, stratified by primary sector. A second human coder works blind to the first coder's labels.
- Fields tested:
  - inclusion (yes/no)
  - primary sector
  - stage
  - intent score
  - traction score
  - `us_basis`
- Measures:
  - Cohen's κ for nominal fields
  - Weighted κ (quadratic) for ordinal scores
  - Percent agreement reported alongside each κ
- Target: κ ≥ 0.70 per field. Below target, revise the codebook, re-train, and re-code that field across the sample.
- Model-vs-human: report the same statistics comparing AI-proposed codes with final human codes. Publish both.

---

## 12. Revision log
| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-10-23 | Initial codebook. U.S. rule set to federal-award eligibility. Unit of analysis, sectors and stages adopted. |
