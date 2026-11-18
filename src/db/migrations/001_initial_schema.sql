-- =============================================================================
-- LeadForge — initial schema (PostgreSQL 17)
--
-- Derived from the frontend contract in Leader_scrapper-fe/src/types/index.ts
-- and services/api/types.ts, plus PRODUCT.md.
--
-- Conventions
--   * uuid primary keys (gen_random_uuid), timestamptz everywhere.
--   * Closed value sets are text + CHECK (easier to evolve than PG enums).
--   * Every tenant-owned row carries workspace_id so each query can be scoped
--     to one workspace (and Row Level Security can be added later).
--   * Money is numeric: budgets numeric(12,4), per-request AI cost numeric(14,6).
--   * Human tags (P-012, L-01234, R-0456, X-007) are unique per workspace and
--     come from next_tag().
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS citext;   -- case-insensitive emails / domains
CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- fuzzy lead search

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- =============================================================================
-- Identity: users, workspaces, membership, sessions
-- =============================================================================
CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text        NOT NULL CHECK (length(trim(name)) > 0),
  email             citext      NOT NULL UNIQUE,
  password_hash     text        NOT NULL,            -- argon2id
  email_verified_at timestamptz,
  last_active_at    timestamptz,
  disabled_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workspaces (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL CHECK (length(trim(name)) > 0),
  client      text,                                   -- agency client; NULL = in-house team
  plan        text        NOT NULL DEFAULT 'Starter'
              CHECK (plan IN ('Starter', 'Agency', 'Agency Pro')),
  created_by  uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);

CREATE TABLE workspace_members (
  workspace_id   uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id        uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role           text        NOT NULL CHECK (role IN ('owner', 'admin', 'analyst', 'viewer')),
  joined_at      timestamptz NOT NULL DEFAULT now(),
  last_active_at timestamptz,
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX workspace_members_user_idx ON workspace_members (user_id);

-- Invitations for people who may not have an account yet ("invited" status in the team list).
CREATE TABLE workspace_invitations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  email        citext      NOT NULL,
  name         text,
  role         text        NOT NULL CHECK (role IN ('admin', 'analyst', 'viewer')),
  token_hash   text        NOT NULL UNIQUE,
  invited_by   uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  accepted_at  timestamptz,
  revoked_at   timestamptz
);
CREATE UNIQUE INDEX workspace_invitations_open_uq
  ON workspace_invitations (workspace_id, email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- Refresh tokens / server-side sessions, so logout can revoke.
CREATE TABLE auth_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   text        NOT NULL UNIQUE,
  user_agent   text,
  ip           inet,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz
);
CREATE INDEX auth_sessions_user_idx ON auth_sessions (user_id) WHERE revoked_at IS NULL;

-- Per-workspace counters behind the short human tags.
CREATE TABLE workspace_counters (
  workspace_id uuid   NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  kind         text   NOT NULL CHECK (kind IN ('project', 'lead', 'run', 'export')),
  last_value   bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (workspace_id, kind)
);

-- next_tag(ws, 'lead') -> 'L-01234'. Row-locks the counter, so it is safe under concurrency.
CREATE OR REPLACE FUNCTION next_tag(p_workspace uuid, p_kind text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v bigint;
  prefix text := CASE p_kind
                   WHEN 'project' THEN 'P'
                   WHEN 'lead'    THEN 'L'
                   WHEN 'run'     THEN 'R'
                   WHEN 'export'  THEN 'X'
                 END;
BEGIN
  IF prefix IS NULL THEN
    RAISE EXCEPTION 'unknown tag kind %', p_kind;
  END IF;
  INSERT INTO workspace_counters AS c (workspace_id, kind, last_value)
  VALUES (p_workspace, p_kind, 1)
  ON CONFLICT (workspace_id, kind) DO UPDATE SET last_value = c.last_value + 1
  RETURNING last_value INTO v;
  RETURN prefix || '-0' || v::text;
END $$;

-- =============================================================================
-- Data sources (global catalogue + per-workspace settings)
-- =============================================================================
CREATE TABLE data_sources (
  id              text PRIMARY KEY CHECK (id IN (
                    'osm', 'wikidata', 'gleif', 'companies_house', 'sec_edgar',
                    'company_websites', 'csv_upload', 'common_crawl')),
  name            text    NOT NULL,
  kind            text    NOT NULL CHECK (kind IN (
                    'Open dataset', 'Registry API', 'Web research', 'Customer upload', 'Web corpus')),
  description     text    NOT NULL DEFAULT '',
  lead_types      text[]  NOT NULL DEFAULT '{business}'
                  CHECK (lead_types <@ ARRAY['business', 'professional']),
  incremental     boolean NOT NULL DEFAULT false,
  update_cadence  text    NOT NULL DEFAULT '',
  coverage_note   text    NOT NULL DEFAULT '',
  rate_limit      text    NOT NULL DEFAULT '',
  available       boolean NOT NULL DEFAULT true,   -- false = "planned" adapter
  -- Licence & permitted use (publicly visible != commercially reusable)
  license_name    text    NOT NULL,
  license_url     text    NOT NULL,
  attribution     text    NOT NULL DEFAULT '',
  commercial_use  text    NOT NULL CHECK (commercial_use IN ('permitted', 'conditional', 'restricted', 'review_required')),
  redistribution  text    NOT NULL CHECK (redistribution IN ('permitted', 'conditional', 'restricted', 'review_required')),
  license_notes   text    NOT NULL DEFAULT '',
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workspace_sources (
  workspace_id uuid    NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  source_id    text    NOT NULL REFERENCES data_sources(id),
  enabled      boolean NOT NULL DEFAULT false,
  status       text    NOT NULL DEFAULT 'disabled'
               CHECK (status IN ('connected', 'syncing', 'disabled', 'error', 'planned')),
  config       jsonb   NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(config) = 'object'),  -- e.g. Geofabrik region
  last_sync_at timestamptz,
  records_held bigint  NOT NULL DEFAULT 0,
  last_error   text,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, source_id)
);

-- =============================================================================
-- Projects ("My searches")
-- =============================================================================
CREATE TABLE projects (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id        uuid    NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  tag                 text    NOT NULL,
  name                text    NOT NULL CHECK (length(trim(name)) > 0),
  client              text,
  brief               text,                              -- natural-language brief, if any
  lead_type           text    NOT NULL CHECK (lead_type IN ('business', 'professional')),
  -- Criteria (industries, countries, cities, services, roles, employeeRange, keywords,
  -- requireWebsite, requirePublicContact). Read whole by the pipeline, never joined on.
  criteria            jsonb   NOT NULL CHECK (jsonb_typeof(criteria) = 'object'),
  rules_version       integer NOT NULL DEFAULT 1,        -- bumped when scoring rules change
  ai_research         boolean NOT NULL DEFAULT true,
  max_pages_per_site  smallint NOT NULL DEFAULT 6 CHECK (max_pages_per_site BETWEEN 1 AND 50),
  target              integer NOT NULL DEFAULT 500 CHECK (target > 0),
  status              text    NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('active', 'paused', 'draft', 'archived')),
  -- Schedule (default every two hours)
  schedule_enabled    boolean NOT NULL DEFAULT true,
  interval_hours      smallint NOT NULL DEFAULT 2 CHECK (interval_hours BETWEEN 1 AND 168),
  next_run_at         timestamptz,
  last_run_at         timestamptz,
  last_success_at     timestamptz,
  -- Pipeline funnel counters, maintained by the pipeline stages
  funnel_discovered   integer NOT NULL DEFAULT 0,
  funnel_cleaned      integer NOT NULL DEFAULT 0,
  funnel_relevant     integer NOT NULL DEFAULT 0,
  funnel_researched   integer NOT NULL DEFAULT 0,
  funnel_qualified    integer NOT NULL DEFAULT 0,
  active_run_id       uuid,                              -- FK added after runs exists
  owner_id            uuid    REFERENCES users(id) ON DELETE SET NULL,
  created_by          uuid    REFERENCES users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, tag),
  UNIQUE (workspace_id, id)                              -- target for same-workspace FKs
);
CREATE INDEX projects_workspace_status_idx ON projects (workspace_id, status);
-- Scheduler: "which projects are due?"
CREATE INDEX projects_due_idx ON projects (next_run_at)
  WHERE status = 'active' AND schedule_enabled;

CREATE TABLE project_sources (
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  source_id  text NOT NULL REFERENCES data_sources(id),
  PRIMARY KEY (project_id, source_id)
);

CREATE TABLE project_scoring_rules (
  project_id uuid     NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  key        text     NOT NULL CHECK (key IN (
               'industry', 'location', 'services', 'size', 'contact', 'role', 'company', 'evidence')),
  label      text     NOT NULL,
  weight     smallint NOT NULL CHECK (weight BETWEEN 0 AND 100),
  position   smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (project_id, key)
);

-- =============================================================================
-- Runs (discovery jobs) and their logs
-- =============================================================================
CREATE TABLE runs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id       uuid    NOT NULL,
  project_id         uuid    NOT NULL,
  tag                text    NOT NULL,
  trigger            text    NOT NULL CHECK (trigger IN ('schedule', 'manual', 'retry')),
  lead_id            uuid,                               -- set for a single-lead manual re-research
  retry_of_run_id    uuid    REFERENCES runs(id) ON DELETE SET NULL,
  status             text    NOT NULL DEFAULT 'queued'
                     CHECK (status IN ('queued', 'running', 'completed', 'partial', 'failed', 'cancelled')),
  stage              text    NOT NULL DEFAULT 'queued'
                     CHECK (stage IN ('queued', 'discovering', 'extracting', 'filtering',
                                      'crawling', 'researching', 'qualifying', 'done')),
  progress           smallint NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  -- counts
  discovered         integer NOT NULL DEFAULT 0,
  new_records        integer NOT NULL DEFAULT 0,
  duplicates         integer NOT NULL DEFAULT 0,
  filtered_out       integer NOT NULL DEFAULT 0,
  crawled            integer NOT NULL DEFAULT 0,
  unchanged_skipped  integer NOT NULL DEFAULT 0,
  researched         integer NOT NULL DEFAULT 0,
  qualified          integer NOT NULL DEFAULT 0,
  failed             integer NOT NULL DEFAULT 0,
  ai_cost_usd        numeric(12,4) NOT NULL DEFAULT 0,
  attempts           smallint NOT NULL DEFAULT 0,
  error              text,
  queue_job_id       text,                               -- BullMQ job id
  triggered_by       uuid    REFERENCES users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  started_at         timestamptz,
  finished_at        timestamptz,
  UNIQUE (workspace_id, tag),
  UNIQUE (workspace_id, id),
  FOREIGN KEY (workspace_id, project_id) REFERENCES projects (workspace_id, id) ON DELETE CASCADE,
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX runs_project_created_idx ON runs (project_id, created_at DESC);
CREATE INDEX runs_workspace_created_idx ON runs (workspace_id, created_at DESC);
CREATE INDEX runs_active_idx ON runs (workspace_id) WHERE status IN ('queued', 'running');
-- At most one queued/running discovery run per project (single-lead research runs excluded).
CREATE UNIQUE INDEX runs_one_active_per_project_uq
  ON runs (project_id) WHERE status IN ('queued', 'running') AND lead_id IS NULL;

ALTER TABLE projects
  ADD CONSTRAINT projects_active_run_fk
  FOREIGN KEY (active_run_id) REFERENCES runs(id) ON DELETE SET NULL;

CREATE TABLE run_logs (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id  uuid        NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  at      timestamptz NOT NULL DEFAULT now(),
  level   text        NOT NULL CHECK (level IN ('info', 'warn', 'error')),
  stage   text        NOT NULL,
  message text        NOT NULL,
  data    jsonb
);
CREATE INDEX run_logs_run_idx ON run_logs (run_id, at);

-- =============================================================================
-- Leads (businesses and professionals in one table, discriminated by kind)
-- =============================================================================
CREATE TABLE leads (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id        uuid    NOT NULL,
  project_id          uuid    NOT NULL,
  tag                 text    NOT NULL,
  kind                text    NOT NULL CHECK (kind IN ('business', 'professional')),
  name                text    NOT NULL,                  -- business name, or person's full name
  -- Location
  country             text,
  country_code        char(2) CHECK (country_code ~ '^[A-Z]{2}$'),
  city                text,
  -- Provenance
  source_id           text    NOT NULL REFERENCES data_sources(id),
  source_record_id    text    NOT NULL,                  -- e.g. 'node:4821137012'
  source_url          text,
  first_run_id        uuid    REFERENCES runs(id) ON DELETE SET NULL,
  dedup_key           text,                              -- normalised domain or name+city
  -- Business fields (NULL = unknown; never estimated)
  industry            text,
  category            text,
  description         text,
  website             text,
  domain              citext,
  address             text,
  business_email      citext,
  business_phone      text,
  socials             jsonb   NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(socials) = 'array'),
  services            text[]  NOT NULL DEFAULT '{}',
  products            text[]  NOT NULL DEFAULT '{}',
  employees           text,                              -- only when a source states it
  -- Professional fields
  title               text,
  role_category       text,
  company_name        text,
  company_lead_id     uuid    REFERENCES leads(id) ON DELETE SET NULL,
  company_website     text,
  profile_url         text,
  public_email        citext,
  -- Pipeline state
  research_status     text    NOT NULL DEFAULT 'not_queued'
                      CHECK (research_status IN ('not_queued', 'queued', 'crawling', 'researching',
                             'researched', 'unchanged_skipped', 'filtered_out', 'failed')),
  state               text    NOT NULL DEFAULT 'new'
                      CHECK (state IN ('new', 'saved', 'contacted', 'removed')),
  tags                text[]  NOT NULL DEFAULT '{}',
  -- Current score (factor rows live in lead_score_factors)
  score_total         smallint CHECK (score_total BETWEEN 0 AND 100),
  score_class         text    CHECK (score_class IN ('highly_relevant', 'relevant', 'potential', 'low')),
  scored_at           timestamptz,
  score_rules_version integer,
  -- Timestamps
  discovered_at       timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  last_researched_at  timestamptz,
  contacted_at        timestamptz,
  UNIQUE (workspace_id, tag),
  UNIQUE (workspace_id, id),
  UNIQUE (project_id, source_id, source_record_id),      -- same record never imported twice
  FOREIGN KEY (workspace_id, project_id) REFERENCES projects (workspace_id, id) ON DELETE CASCADE,
  CHECK ((score_total IS NULL) = (score_class IS NULL)),
  CHECK (kind = 'professional' OR (title IS NULL AND company_lead_id IS NULL AND public_email IS NULL)),
  CHECK (kind = 'business' OR (business_email IS NULL AND business_phone IS NULL))
);
ALTER TABLE runs ADD CONSTRAINT runs_lead_fk
  FOREIGN KEY (lead_id) REFERENCES leads(id) ON DELETE SET NULL;

-- Cross-source dedup inside a project
CREATE UNIQUE INDEX leads_project_dedup_uq ON leads (project_id, dedup_key) WHERE dedup_key IS NOT NULL;
-- Lead table: default view is a project's leads by score
CREATE INDEX leads_project_score_idx    ON leads (project_id, score_total DESC NULLS LAST, id);
CREATE INDEX leads_workspace_score_idx  ON leads (workspace_id, score_total DESC NULLS LAST, id);
CREATE INDEX leads_workspace_disc_idx   ON leads (workspace_id, discovered_at DESC);
CREATE INDEX leads_workspace_state_idx  ON leads (workspace_id, state);
CREATE INDEX leads_workspace_class_idx  ON leads (workspace_id, score_class);
CREATE INDEX leads_workspace_country_idx ON leads (workspace_id, country_code);
CREATE INDEX leads_workspace_industry_idx ON leads (workspace_id, industry);
CREATE INDEX leads_research_queue_idx   ON leads (project_id, research_status)
  WHERE research_status IN ('queued', 'crawling', 'researching');
CREATE INDEX leads_company_idx          ON leads (company_lead_id) WHERE company_lead_id IS NOT NULL;
CREATE INDEX leads_domain_idx           ON leads (workspace_id, domain) WHERE domain IS NOT NULL;
CREATE INDEX leads_tags_gin             ON leads USING gin (tags);
-- Free-text search box (name, domain, city)
CREATE INDEX leads_name_trgm            ON leads USING gin (name gin_trgm_ops);
CREATE INDEX leads_domain_trgm          ON leads USING gin ((domain::text) gin_trgm_ops);

CREATE TABLE lead_notes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id    uuid        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  author_id  uuid        REFERENCES users(id) ON DELETE SET NULL,
  text       text        NOT NULL CHECK (length(trim(text)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_notes_lead_idx ON lead_notes (lead_id, created_at DESC);

-- =============================================================================
-- Website crawling (shared cache of public pages; hash drives "only research on change")
-- =============================================================================
CREATE TABLE web_pages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  url           text        NOT NULL UNIQUE,
  domain        citext      NOT NULL,
  kind          text        CHECK (kind IN ('home', 'about', 'services', 'products', 'contact', 'team', 'careers')),
  http_status   smallint,
  robots        text        NOT NULL DEFAULT 'allowed' CHECK (robots IN ('allowed', 'disallowed')),
  content_hash  text,                                  -- hash of normalised main text
  previous_hash text,
  changed       boolean     NOT NULL DEFAULT false,    -- content_hash <> previous_hash on last fetch
  bytes         integer,
  storage_key   text,                                  -- extracted text in object storage
  fetched_at    timestamptz,
  next_fetch_at timestamptz
);
CREATE INDEX web_pages_domain_idx ON web_pages (domain);
CREATE INDEX web_pages_due_idx    ON web_pages (next_fetch_at) WHERE robots = 'allowed';

CREATE TABLE lead_pages (
  lead_id uuid NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  page_id uuid NOT NULL REFERENCES web_pages(id) ON DELETE CASCADE,
  PRIMARY KEY (lead_id, page_id)
);
CREATE INDEX lead_pages_page_idx ON lead_pages (page_id);

-- =============================================================================
-- AI: models & pricing, provider settings, credentials, routing, budgets, requests
-- =============================================================================
CREATE TABLE ai_pricing_versions (
  version        text PRIMARY KEY,
  effective_from timestamptz NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ai_models (
  id             text PRIMARY KEY,                     -- provider model id
  provider       text    NOT NULL CHECK (provider IN ('openai', 'anthropic')),
  name           text    NOT NULL,
  tier           text    NOT NULL CHECK (tier IN ('economy', 'standard', 'advanced')),
  context_window integer NOT NULL CHECK (context_window > 0),
  active         boolean NOT NULL DEFAULT true
);

-- Prices per million tokens, versioned so old requests keep their original price.
CREATE TABLE ai_model_prices (
  model_id               text NOT NULL REFERENCES ai_models(id) ON DELETE CASCADE,
  pricing_version        text NOT NULL REFERENCES ai_pricing_versions(version),
  input_per_mtok         numeric(10,4) NOT NULL CHECK (input_per_mtok >= 0),
  output_per_mtok        numeric(10,4) NOT NULL CHECK (output_per_mtok >= 0),
  cached_input_per_mtok  numeric(10,4)          CHECK (cached_input_per_mtok >= 0),
  PRIMARY KEY (model_id, pricing_version)
);

CREATE TABLE ai_provider_settings (
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider     text NOT NULL CHECK (provider IN ('openai', 'anthropic')),
  mode         text NOT NULL DEFAULT 'managed' CHECK (mode IN ('managed', 'byok')),
  credential_id uuid,                                  -- active BYOK key (FK below)
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, provider)
);

-- BYOK keys: stored encrypted (AES-256-GCM, app-held master key); only `masked` is ever returned.
CREATE TABLE ai_credentials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id    uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider        text        NOT NULL CHECK (provider IN ('openai', 'anthropic')),
  label           text        NOT NULL,
  key_ciphertext  bytea       NOT NULL,
  key_iv          bytea       NOT NULL,
  key_auth_tag    bytea       NOT NULL,
  key_version     smallint    NOT NULL DEFAULT 1,      -- master-key rotation
  masked          text        NOT NULL,                -- e.g. 'sk-…a91F'
  status          text        NOT NULL DEFAULT 'untested' CHECK (status IN ('valid', 'invalid', 'untested')),
  last_tested_at  timestamptz,
  last_error      text,
  created_by      uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz
);
CREATE INDEX ai_credentials_ws_idx ON ai_credentials (workspace_id, provider) WHERE revoked_at IS NULL;

ALTER TABLE ai_provider_settings ADD CONSTRAINT ai_provider_settings_credential_fk
  FOREIGN KEY (credential_id) REFERENCES ai_credentials(id) ON DELETE SET NULL;

-- Per-task model routing. Labels/descriptions are app constants, not stored.
CREATE TABLE ai_task_policies (
  workspace_id      uuid     NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  task              text     NOT NULL CHECK (task IN (
                      'search_understanding', 'company_research', 'industry_classification',
                      'service_extraction', 'professional_identification', 'lead_qualification',
                      'opportunity_analysis', 'outreach_draft')),
  provider          text     NOT NULL CHECK (provider IN ('openai', 'anthropic')),
  model_id          text     NOT NULL REFERENCES ai_models(id),
  escalate_to_model text     REFERENCES ai_models(id),
  max_output_tokens integer  NOT NULL DEFAULT 1024 CHECK (max_output_tokens BETWEEN 1 AND 64000),
  enabled           boolean  NOT NULL DEFAULT true,
  optional          boolean  NOT NULL DEFAULT false,   -- restricted once spend passes 95%
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, task)
);

-- Budgets: one per workspace, optionally one per project.
-- Thresholds (app logic): 70% warn, 85% strong notice, 95% restrict deep research, 100% stop managed AI.
CREATE TABLE ai_budgets (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id           uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  scope                  text        NOT NULL CHECK (scope IN ('workspace', 'project')),
  project_id             uuid        REFERENCES projects(id) ON DELETE CASCADE,
  limit_usd              numeric(12,4) NOT NULL CHECK (limit_usd >= 0),
  spent_usd              numeric(12,4) NOT NULL DEFAULT 0 CHECK (spent_usd >= 0),
  reserved_usd           numeric(12,4) NOT NULL DEFAULT 0 CHECK (reserved_usd >= 0),
  funding                text        NOT NULL DEFAULT 'managed' CHECK (funding IN ('managed', 'byok')),
  period                 text        NOT NULL DEFAULT 'monthly' CHECK (period IN ('monthly')),
  period_start           timestamptz NOT NULL DEFAULT date_trunc('month', now()),
  resets_at              timestamptz NOT NULL DEFAULT date_trunc('month', now()) + interval '1 month',
  last_threshold_pct     smallint    NOT NULL DEFAULT 0,   -- highest threshold already notified
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CHECK ((scope = 'project') = (project_id IS NOT NULL))
);
CREATE UNIQUE INDEX ai_budgets_workspace_uq ON ai_budgets (workspace_id) WHERE scope = 'workspace';
CREATE UNIQUE INDEX ai_budgets_project_uq   ON ai_budgets (project_id)   WHERE scope = 'project';

-- Every AI Gateway call (append-only ledger; source of usage & spend views).
CREATE TABLE ai_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id    uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id      uuid        REFERENCES projects(id) ON DELETE SET NULL,
  lead_id         uuid        REFERENCES leads(id) ON DELETE SET NULL,
  run_id          uuid        REFERENCES runs(id) ON DELETE SET NULL,
  task            text        NOT NULL,
  provider        text        NOT NULL CHECK (provider IN ('openai', 'anthropic')),
  model_id        text        NOT NULL REFERENCES ai_models(id),
  pricing_version text        REFERENCES ai_pricing_versions(version),
  funding         text        NOT NULL CHECK (funding IN ('managed', 'byok')),
  credential_id   uuid        REFERENCES ai_credentials(id) ON DELETE SET NULL,
  input_tokens    integer     NOT NULL DEFAULT 0,
  output_tokens   integer     NOT NULL DEFAULT 0,
  cached_tokens   integer     NOT NULL DEFAULT 0,
  duration_ms     integer,
  cost_usd        numeric(14,6) NOT NULL DEFAULT 0,
  status          text        NOT NULL CHECK (status IN ('ok', 'cached', 'error', 'budget_blocked')),
  request_hash    text,                                -- response-cache key
  error           text,
  at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ai_requests_ws_at_idx      ON ai_requests (workspace_id, at DESC);
CREATE INDEX ai_requests_project_at_idx ON ai_requests (project_id, at DESC) WHERE project_id IS NOT NULL;
CREATE INDEX ai_requests_lead_idx       ON ai_requests (lead_id) WHERE lead_id IS NOT NULL;
CREATE INDEX ai_requests_hash_idx       ON ai_requests (request_hash) WHERE request_hash IS NOT NULL;

-- =============================================================================
-- Research, scoring, evidence, AI hypotheses, outreach drafts
-- =============================================================================
-- One row per research attempt on a lead (including "skipped, unchanged").
CREATE TABLE research_runs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id        uuid        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  run_id         uuid        REFERENCES runs(id) ON DELETE SET NULL,
  ai_request_id  uuid        REFERENCES ai_requests(id) ON DELETE SET NULL,  -- tokens/cost live there
  trigger        text        NOT NULL CHECK (trigger IN ('new_lead', 'content_changed', 'manual', 'rescore')),
  task           text        NOT NULL,
  outcome        text        NOT NULL CHECK (outcome IN ('ok', 'schema_invalid', 'failed', 'skipped_unchanged')),
  note           text        NOT NULL DEFAULT '',
  at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX research_runs_lead_idx ON research_runs (lead_id, at DESC);

-- Every extracted field carries its source URL and excerpt; facts and inferences kept apart.
CREATE TABLE evidence (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id         uuid        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  field           text        NOT NULL,
  value           text        NOT NULL,
  url             text        NOT NULL,
  excerpt         text        NOT NULL DEFAULT '',
  kind            text        NOT NULL CHECK (kind IN ('fact', 'inference')),
  page_id         uuid        REFERENCES web_pages(id) ON DELETE SET NULL,
  research_run_id uuid        REFERENCES research_runs(id) ON DELETE SET NULL,
  captured_at     timestamptz NOT NULL DEFAULT now(),
  superseded_at   timestamptz                          -- kept for history when re-extracted
);
CREATE INDEX evidence_lead_idx ON evidence (lead_id) WHERE superseded_at IS NULL;

-- Current score breakdown, factor by factor.
CREATE TABLE lead_score_factors (
  lead_id      uuid     NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  key          text     NOT NULL CHECK (key IN (
                 'industry', 'location', 'services', 'size', 'contact', 'role', 'company', 'evidence')),
  label        text     NOT NULL,
  weight       smallint NOT NULL,
  points       smallint NOT NULL CHECK (points >= 0 AND points <= weight),
  status       text     NOT NULL CHECK (status IN ('match', 'partial', 'miss', 'unknown')),
  detail       text     NOT NULL DEFAULT '',
  evidence_ids uuid[]   NOT NULL DEFAULT '{}',
  PRIMARY KEY (lead_id, key)
);

-- AI hypotheses — never presented as fact.
CREATE TABLE lead_opportunities (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id         uuid        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  text            text        NOT NULL,
  based_on        uuid[]      NOT NULL DEFAULT '{}',   -- evidence ids
  research_run_id uuid        REFERENCES research_runs(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_opportunities_lead_idx ON lead_opportunities (lead_id);

-- Drafts only; nothing is ever sent automatically.
CREATE TABLE outreach_drafts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id       uuid        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  subject       text        NOT NULL,
  body          text        NOT NULL,
  based_on      uuid[]      NOT NULL DEFAULT '{}',
  ai_request_id uuid        REFERENCES ai_requests(id) ON DELETE SET NULL,
  created_by    uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outreach_drafts_lead_idx ON outreach_drafts (lead_id, created_at DESC);

-- =============================================================================
-- Activity feed
-- =============================================================================
CREATE TABLE activity_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id    uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id      uuid        REFERENCES projects(id) ON DELETE CASCADE,
  type            text        NOT NULL CHECK (type IN (
                    'lead.discovered', 'lead.updated', 'lead.researched', 'lead.qualified',
                    'website.changed', 'duplicate.skipped', 'job.started', 'job.progress',
                    'job.completed', 'job.failed', 'budget.warning', 'budget.exceeded')),
  severity        text        NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'notice', 'warning', 'alarm')),
  message         text        NOT NULL,
  ref_kind        text        CHECK (ref_kind IN ('lead', 'run', 'project')),
  ref_id          uuid,
  ref_tag         text,
  data            jsonb,
  acknowledged_at timestamptz,
  acknowledged_by uuid        REFERENCES users(id) ON DELETE SET NULL,
  at              timestamptz NOT NULL DEFAULT now(),
  CHECK ((ref_kind IS NULL) = (ref_id IS NULL))
);
CREATE INDEX activity_ws_at_idx      ON activity_events (workspace_id, at DESC);
CREATE INDEX activity_unacked_idx    ON activity_events (workspace_id, at DESC)
  WHERE acknowledged_at IS NULL AND severity IN ('warning', 'alarm');

-- =============================================================================
-- CSV imports
-- =============================================================================
CREATE TABLE csv_imports (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id      uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id        uuid        REFERENCES projects(id) ON DELETE SET NULL,
  file_name         text        NOT NULL,
  storage_key       text,
  mapping           jsonb       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(mapping) = 'object'),
  rows              integer     NOT NULL DEFAULT 0,
  imported          integer     NOT NULL DEFAULT 0,
  duplicates        integer     NOT NULL DEFAULT 0,
  errors            integer     NOT NULL DEFAULT 0,
  status            text        NOT NULL DEFAULT 'mapping'
                    CHECK (status IN ('mapping', 'importing', 'completed', 'failed')),
  created_by        uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz
);
CREATE INDEX csv_imports_ws_idx ON csv_imports (workspace_id, created_at DESC);

CREATE TABLE csv_import_errors (
  import_id  uuid    NOT NULL REFERENCES csv_imports(id) ON DELETE CASCADE,
  row_number integer NOT NULL,
  column_name text,
  message    text    NOT NULL,
  PRIMARY KEY (import_id, row_number, message)
);

-- =============================================================================
-- Exports
-- =============================================================================
CREATE TABLE export_jobs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id        uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  tag                 text        NOT NULL,
  file_name           text        NOT NULL,
  format              text        NOT NULL CHECK (format IN ('csv', 'xlsx')),
  project_id          uuid        REFERENCES projects(id) ON DELETE SET NULL,
  scope               text        NOT NULL CHECK (scope IN ('selected', 'filtered', 'project')),
  lead_ids            uuid[],                         -- scope = 'selected'
  query               jsonb,                          -- scope = 'filtered' (LeadQuery)
  include_provenance  boolean     NOT NULL DEFAULT true,
  row_count           integer     NOT NULL DEFAULT 0,
  suppressed_removed  integer     NOT NULL DEFAULT 0,
  status              text        NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued', 'processing', 'ready', 'failed', 'expired')),
  progress            smallint    NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  storage_key         text,
  error               text,
  created_by          uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  completed_at        timestamptz,
  expires_at          timestamptz,
  UNIQUE (workspace_id, tag),
  CHECK (scope <> 'selected' OR lead_ids IS NOT NULL),
  CHECK (scope <> 'project'  OR project_id IS NOT NULL)
);
CREATE INDEX export_jobs_ws_idx ON export_jobs (workspace_id, created_at DESC);

-- =============================================================================
-- Compliance: suppression list and deletion requests
-- =============================================================================
CREATE TABLE suppressions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id     uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  type             text        NOT NULL CHECK (type IN ('email', 'domain', 'phone', 'person')),
  value            text        NOT NULL,
  value_normalized text        NOT NULL,              -- lower-cased email/domain, E.164 phone
  reason           text        NOT NULL CHECK (reason IN ('opt_out', 'deletion_request', 'client_request', 'legal')),
  added_by         uuid        REFERENCES users(id) ON DELETE SET NULL,
  added_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, type, value_normalized)
);

CREATE TABLE deletion_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id     uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  subject          text        NOT NULL,
  contact          text        NOT NULL,
  status           text        NOT NULL DEFAULT 'received'
                   CHECK (status IN ('received', 'verifying', 'in_progress', 'completed', 'rejected')),
  records_affected integer     NOT NULL DEFAULT 0,
  notes            text,
  handled_by       uuid        REFERENCES users(id) ON DELETE SET NULL,
  received_at      timestamptz NOT NULL DEFAULT now(),
  due_at           timestamptz NOT NULL DEFAULT now() + interval '30 days',
  completed_at     timestamptz
);
CREATE INDEX deletion_requests_ws_idx ON deletion_requests (workspace_id, status, due_at);

-- =============================================================================
-- Audit log (key added/removed, budget changed, member role changed, export created…)
-- =============================================================================
CREATE TABLE audit_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id uuid        REFERENCES workspaces(id) ON DELETE CASCADE,
  actor_id     uuid        REFERENCES users(id) ON DELETE SET NULL,
  action       text        NOT NULL,                  -- e.g. 'ai_credential.created'
  target_kind  text,
  target_id    text,
  data         jsonb,                                 -- never contains secrets
  ip           inet,
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_ws_at_idx ON audit_log (workspace_id, at DESC);

-- =============================================================================
-- updated_at triggers
-- =============================================================================
CREATE TRIGGER users_updated_at            BEFORE UPDATE ON users            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER workspaces_updated_at       BEFORE UPDATE ON workspaces       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER workspace_sources_updated_at BEFORE UPDATE ON workspace_sources FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER data_sources_updated_at     BEFORE UPDATE ON data_sources     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER projects_updated_at         BEFORE UPDATE ON projects         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER leads_updated_at            BEFORE UPDATE ON leads            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER ai_provider_settings_updated_at BEFORE UPDATE ON ai_provider_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER ai_task_policies_updated_at BEFORE UPDATE ON ai_task_policies FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER ai_budgets_updated_at       BEFORE UPDATE ON ai_budgets       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
