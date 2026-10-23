-- U.S. Commercial Space Project Directory — Postgres schema (v1.0)
-- Target: Supabase / Postgres 15+. Requires pgvector and pg_trgm.
-- Canonical tables are written ONLY by the review console (role `reviewer`).
-- Pipeline jobs (role `pipeline`) write to candidates / review_queue / proposed_changes.

create extension if not exists vector;
create extension if not exists pg_trgm;
create extension if not exists "uuid-ossp";

-- ───────────────────────── Controlled vocabularies ─────────────────────────
create table sectors (code text primary key, label text not null, description text);
insert into sectors values
 ('LCH','Launch & reentry',null),('SPT','Spaceports & test infrastructure',null),
 ('COM','Satellite communications',null),('EO','Earth observation & remote sensing',null),
 ('PNT','Positioning, navigation & timing',null),('BUS','Spacecraft & platforms',null),
 ('CMP','Components & subsystems',null),('ISM','In-space manufacturing & research',null),
 ('ISL','In-space servicing, logistics & debris',null),('SDA','Space domain awareness',null),
 ('LUN','Lunar & cislunar',null),('STN','Stations & habitats',null),
 ('GND','Ground segment & software',null),('APP','Downstream applications',null);

create type stage_t as enum ('S0_announced','S1_funded','S2_development','S3_demonstrated',
                             'S4_operational','S5_suspended','S6_terminated');
create type confidence_t as enum ('verified','partially_verified','unconfirmed');
create type us_basis_t as enum ('federal_award_recipient','sam_registered','us_entity_unverified');
create type tier_t as enum ('T1','T2','T3','T4');
create type record_status_t as enum ('draft','in_review','accepted','excluded','merged');

-- ───────────────────────── Organizations ─────────────────────────
create table organizations (
  org_id            text primary key,                -- ORG-000001, never reused
  name              text not null,
  aliases           text[] default '{}',
  org_type          text check (org_type in ('startup','private_established','public_company',
                     'prime_contractor','university','nonprofit','government','jv','other')),
  parent_org_id     text references organizations(org_id),
  hq_city text, hq_state text, hq_country text default 'US',
  website           text,
  domain            text,                            -- normalized, used for matching
  founded_year      int,
  employee_band     text,
  us_basis          us_basis_t,
  sbir_eligible     boolean,
  foreign_parent    boolean default false,
  parent_country    text,
  status            record_status_t default 'draft',
  name_embedding    vector(1024),
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create index on organizations using gin (name gin_trgm_ops);

create table org_identifiers (               -- crosswalk IDs: UEI, CAGE, CIK, FRN, LEI, ...
  org_id text references organizations(org_id) on delete cascade,
  id_type text not null check (id_type in ('UEI','CAGE','CIK','FCC_FRN','LEI','FAA_LICENSEE',
                                           'NOAA_LICENSEE','SBIR_FIRM_ID','CRUNCHBASE','OTHER')),
  id_value text not null,
  primary key (id_type, id_value)
);

create table facilities (                    -- powers economic-development map
  facility_id   text primary key,
  org_id        text references organizations(org_id),
  name          text,
  facility_type text check (facility_type in ('hq','manufacturing','test','launch_site',
                           'ground_station','office','lab','mission_ops','other')),
  city text, county text, state text, zip text, lat numeric, lon numeric,
  source_id     text
);

-- ───────────────────────── Projects ─────────────────────────
create table projects (
  project_id          text primary key,            -- PRJ-000001, permanent
  canonical_name      text not null,
  aliases             text[] default '{}',
  description         text,                        -- ≤ 80 words, factual
  primary_sector      text references sectors(code) not null,
  secondary_sectors   text[] default '{}',
  end_use_industries  text[] default '{}',
  stage               stage_t not null,
  stage_evidence_id   text,                        -- FK added below
  commercial_intent   smallint check (commercial_intent between 0 and 3),
  commercial_traction smallint check (commercial_traction between 0 and 4),
  value_proposition   text,                        -- ≤ 40 words: who pays, for what, why
  customer_types      text[] default '{}',
  revenue_models      text[] default '{}',
  us_basis            us_basis_t not null,
  confidence          confidence_t not null default 'unconfirmed',
  first_evidence_date date,
  last_reviewed       date,
  next_review_due     date,
  discovery_channels  text[] default '{}',         -- for capture–recapture
  status              record_status_t default 'draft',
  merged_into         text references projects(project_id),
  is_public           boolean generated always as
                      (status = 'accepted' and confidence <> 'unconfirmed') stored,
  name_embedding      vector(1024),
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create index on projects using gin (canonical_name gin_trgm_ops);
create index on projects (primary_sector, stage);

create table project_identifiers (           -- contract IDs, FAA license #, FCC call sign, NORAD, TechPort ID
  project_id text references projects(project_id) on delete cascade,
  id_type text not null check (id_type in ('AWARD_ID','PIID','FAIN','SBIR_AWARD','FAA_LICENSE',
          'FCC_CALLSIGN','FCC_FILE','NORAD','COSPAR','TECHPORT','NOAA_LICENSE','OTHER')),
  id_value text not null,
  primary key (id_type, id_value)
);

-- Company ↔ project network (enables network analysis)
create table project_organizations (
  project_id text references projects(project_id) on delete cascade,
  org_id     text references organizations(org_id),
  role       text not null check (role in ('lead','partner','supplier','customer','investor',
              'funder','launch_provider','parent','academic_partner')),
  start_date date, end_date date,
  evidence_id text,
  primary key (project_id, org_id, role)
);
create unique index one_lead_per_project on project_organizations(project_id) where role = 'lead';

create table milestones (
  milestone_id   text primary key,
  project_id     text references projects(project_id) on delete cascade,
  milestone_type text not null,                  -- codebook §6
  milestone_date date,
  date_precision text check (date_precision in ('day','month','quarter','year')),
  planned        boolean default false,          -- planned vs. achieved
  amount_usd     numeric,
  description    text,
  evidence_id    text
);

create table government_relationships (
  gov_rel_id     text primary key,
  project_id     text references projects(project_id) on delete cascade,
  agency         text not null,                  -- NASA, USSF, NOAA, DARPA, DIU, NSF, FAA ...
  program        text,                           -- CLPS, Tipping Point, SBIR Ph II, STRATFI ...
  instrument     text check (instrument in ('contract','grant','sbir_sttr','ota','space_act_funded',
                  'space_act_unfunded','cooperative_agreement','license','other')),
  award_ref      text,
  amount_usd     numeric,
  start_date date, end_date date,
  evidence_id    text
);

create table dependencies (
  dependency_id   text primary key,
  project_id      text references projects(project_id) on delete cascade,
  dependency_type text not null,                 -- codebook §6
  counterparty_org_id text references organizations(org_id),
  description     text,
  status          text check (status in ('secured','pending','at_risk','unknown')),
  evidence_id     text
);

-- ───────────────────────── Sources & evidence ─────────────────────────
create table sources (
  source_id       text primary key,              -- SRC-...
  url             text not null,
  canonical_url   text,
  channel         text not null,                 -- registry key, e.g. 'usaspending', 'sbir', 'spacenews_rss'
  discovery_channel text check (discovery_channel in ('nasa_agency','launch_infra','federal_awards',
                     'satcom_systems','company_disclosures','associations_specialist')),
  tier            tier_t not null,
  title           text,
  publisher       text,
  published_date  date,
  accessed_at     timestamptz not null default now(),
  snapshot_path   text,                          -- storage key of raw HTML/PDF
  text_path       text,                          -- extracted plain text used for span checks
  sha256          text,
  wayback_url     text,
  terms_note      text
);
create unique index on sources (sha256);

create table evidence (
  evidence_id    text primary key,
  project_id     text references projects(project_id) on delete cascade,
  source_id      text references sources(source_id) not null,
  evidence_type  text check (evidence_type in ('award','license','filing','launch','customer',
                  'financing','test','press','catalog','other')),
  supports_fields text[] not null,               -- e.g. {stage,commercial_traction}
  span_text      text not null,                  -- verbatim, internal only
  span_score     numeric,                        -- fuzzy-match score vs. stored text
  note           text,                           -- short factual paraphrase, public
  event_date     date,
  created_at     timestamptz default now()
);

alter table projects add constraint fk_stage_ev foreign key (stage_evidence_id) references evidence(evidence_id);

-- ───────────────────────── Pipeline staging ─────────────────────────
create table candidates (
  candidate_id     text primary key,
  source_id        text references sources(source_id),
  triage_label     text,                         -- relevant / irrelevant / uncertain
  triage_reason    text,
  extraction       jsonb,                        -- validated extraction output (prompt 02)
  span_check       jsonb,                        -- per-field validation results
  resolution       text check (resolution in ('new_project','existing_project','new_evidence',
                    'related_not_same','unresolved')),
  resolved_project_id text references projects(project_id),
  resolution_detail jsonb,
  model_versions   jsonb,                        -- {triage:'claude-haiku-5-5',...,prompt_hash:...}
  created_at timestamptz default now()
);

create table review_queue (
  item_id       text primary key,
  item_type     text check (item_type in ('new_project','stage_change','field_change','merge',
                 'conflict','stale','submission','reliability_sample')),
  project_id    text references projects(project_id),
  candidate_ids text[],
  packet        jsonb not null,                  -- evidence packet from prompt 04/05
  priority      smallint default 3,              -- 1 = highest
  consequential boolean default false,
  status        text default 'open' check (status in ('open','approved','rejected','edited','deferred')),
  reviewer      text,
  decided_at    timestamptz,
  decision_note text,
  created_at timestamptz default now()
);
create index on review_queue (status, priority, created_at);

create table proposed_changes (
  change_id   text primary key,
  item_id     text references review_queue(item_id),
  table_name  text, record_id text, field text,
  old_value   jsonb, new_value jsonb,
  evidence_ids text[]
);

create table exclusions (
  exclusion_id  text primary key,
  candidate_name text, org_name text,
  reason_code   text not null check (reason_code in ('NO_PROJECT','NOT_SPACE','NOT_COMMERCIAL',
                 'NOT_US','SPECULATIVE','INSUFFICIENT_EVIDENCE','DUPLICATE')),
  duplicate_of  text references projects(project_id),
  candidate_ids text[],
  reviewer      text, decided_at timestamptz default now(), note text
);

-- ───────────────────────── History, reliability, releases ─────────────────────────
create table change_history (
  change_id   bigserial primary key,
  table_name  text not null,
  record_id   text not null,
  operation   text not null,
  old_row     jsonb, new_row jsonb,
  changed_by  text default current_user,
  reason      text,                              -- set via `set local app.change_reason`
  review_item_id text,
  changed_at  timestamptz default now()
);

create or replace function log_change() returns trigger language plpgsql as $$
declare rid text;
begin
  rid := coalesce(to_jsonb(new)->>tg_argv[0], to_jsonb(old)->>tg_argv[0]);
  insert into change_history(table_name, record_id, operation, old_row, new_row, reason, review_item_id)
  values (tg_table_name, rid, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          current_setting('app.change_reason', true),
          current_setting('app.review_item_id', true));
  return coalesce(new, old);
end $$;

create trigger audit_projects after insert or update or delete on projects
  for each row execute function log_change('project_id');
create trigger audit_orgs after insert or update or delete on organizations
  for each row execute function log_change('org_id');
create trigger audit_project_orgs after insert or update or delete on project_organizations
  for each row execute function log_change('project_id');
create trigger audit_milestones after insert or update or delete on milestones
  for each row execute function log_change('milestone_id');
create trigger audit_gov after insert or update or delete on government_relationships
  for each row execute function log_change('gov_rel_id');
create trigger audit_deps after insert or update or delete on dependencies
  for each row execute function log_change('dependency_id');

create table reliability_codings (
  coding_id   bigserial primary key,
  sample_id   text not null,                     -- IRR round, e.g. IRR-2026Q4
  project_id  text references projects(project_id),
  coder       text not null,                     -- human id or model id
  coder_kind  text check (coder_kind in ('human_primary','human_secondary','model')),
  field       text not null,
  value       text,
  coded_at    timestamptz default now()
);

create table benchmarks (                        -- frozen reference lists for recall
  benchmark_id text, item_name text, org_name text, ref_url text,
  matched_project_id text references projects(project_id),
  frozen_at date, primary key (benchmark_id, item_name)
);

create table dataset_releases (
  version text primary key,                      -- v2026.11
  released_at timestamptz, codebook_version text,
  n_projects int, n_orgs int, funnel jsonb, coverage jsonb, irr jsonb,
  doi text, export_path text, notes text
);

-- ───────────────────────── Public views (exposed via API, RLS read-only) ─────────────────────────
create view public_projects as
select p.project_id, p.canonical_name, p.aliases, p.description, p.primary_sector, p.secondary_sectors,
       p.end_use_industries, p.stage, p.commercial_intent, p.commercial_traction, p.value_proposition,
       p.customer_types, p.revenue_models, p.us_basis, p.confidence, p.first_evidence_date, p.last_reviewed,
       lo.org_id as lead_org_id, o.name as lead_org_name, o.hq_state
from projects p
left join project_organizations lo on lo.project_id = p.project_id and lo.role = 'lead'
left join organizations o on o.org_id = lo.org_id
where p.is_public;

create view public_evidence as   -- no verbatim spans in public
select e.evidence_id, e.project_id, e.evidence_type, e.note, e.event_date,
       s.url, s.title, s.publisher, s.published_date, s.tier, s.wayback_url
from evidence e join sources s using (source_id)
join projects p using (project_id) where p.is_public;

create view public_network as
select po.project_id, po.org_id, o.name as org_name, po.role
from project_organizations po join organizations o using (org_id)
join projects p using (project_id) where p.is_public;
