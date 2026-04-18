-- =============================================================================
-- Migration: 20260418120000_workers
-- Module: 2 — Worker Profiles
-- Purpose: Worker profiles table, agencies table, and the two supporting enums.
--          Includes RLS. Rate fields (cost_rate, charge_out_rate) are present
--          in the table but NEVER returned to worker/supervisor roles — that
--          enforcement lives in the server action query layer, not here.
-- =============================================================================
-- Rollback:
--   DROP TABLE IF EXISTS workers CASCADE;
--   DROP TABLE IF EXISTS agencies CASCADE;
--   DROP TYPE IF EXISTS worker_status;
--   DROP TYPE IF EXISTS employment_type;
-- =============================================================================

-- 1. Enums ---------------------------------------------------------------

CREATE TYPE employment_type AS ENUM (
  'full_time',
  'casual',
  'agency',
  'pty_ltd'
);

COMMENT ON TYPE employment_type IS
  'How the worker is engaged. Drives payroll export logic and rate rules.';

CREATE TYPE worker_status AS ENUM (
  'active',
  'inactive',
  'suspended'
);

COMMENT ON TYPE worker_status IS
  'Operational status. Inactive = left. Suspended = compliance hold.';

-- 2. agencies ------------------------------------------------------------
-- Lightweight table for labour-hire agencies. Workers of type "agency" carry
-- an agency_id. Full agency management is out of scope for Module 2.

CREATE TABLE agencies (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name          TEXT NOT NULL CHECK (length(trim(name)) > 0),
  contact_name  TEXT,
  contact_phone TEXT,
  contact_email TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at    TIMESTAMPTZ
);

CREATE INDEX idx_agencies_tenant ON agencies(tenant_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_agencies_updated_at
  BEFORE UPDATE ON agencies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE agencies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "agencies_tenant_select"
  ON agencies FOR SELECT TO authenticated
  USING (tenant_id = current_tenant_id() AND deleted_at IS NULL);

CREATE POLICY "agencies_operations_insert"
  ON agencies FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  );

CREATE POLICY "agencies_operations_update"
  ON agencies FOR UPDATE TO authenticated
  USING (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  )
  WITH CHECK (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  );

-- 3. workers -------------------------------------------------------------

CREATE TABLE workers (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  -- Identity
  first_name              TEXT NOT NULL CHECK (length(trim(first_name)) > 0),
  last_name               TEXT NOT NULL CHECK (length(trim(last_name)) > 0),
  preferred_name          TEXT,

  -- Contact
  mobile                  TEXT,
  email                   TEXT,

  -- Employment
  employment_type         employment_type NOT NULL,
  status                  worker_status NOT NULL DEFAULT 'active',
  agency_id               UUID REFERENCES agencies(id) ON DELETE SET NULL,

  -- Rates — SENSITIVE. Never return these columns to worker or supervisor roles.
  -- Enforcement: server action query layer (select string excludes these columns).
  cost_rate               NUMERIC(10,2),     -- visible to resource_manager+
  charge_out_rate         NUMERIC(10,2),     -- visible to finance/director only

  -- Contractor fields
  abn                     TEXT,

  -- Personal
  date_of_birth           DATE,
  address                 TEXT,
  suburb                  TEXT,
  state                   TEXT,
  postcode                TEXT,

  -- Emergency contact
  emergency_contact_name  TEXT,
  emergency_contact_phone TEXT,

  -- Payroll (never store TFN — just whether it's on file)
  tfn_provided            BOOLEAN NOT NULL DEFAULT FALSE,
  super_fund              TEXT,
  super_member_number     TEXT,

  -- Profile photo (Supabase Storage URL)
  avatar_url              TEXT,

  -- Link to an auth.users account (nullable — some workers may not have app access)
  -- Set when a worker accepts an invitation or is manually linked by a director.
  linked_user_id          UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Mandatory audit columns
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at              TIMESTAMPTZ
);

CREATE INDEX idx_workers_tenant        ON workers(tenant_id)       WHERE deleted_at IS NULL;
CREATE INDEX idx_workers_status        ON workers(tenant_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_workers_employment    ON workers(tenant_id, employment_type) WHERE deleted_at IS NULL;
CREATE INDEX idx_workers_linked_user   ON workers(linked_user_id)  WHERE linked_user_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_workers_agency        ON workers(agency_id)       WHERE agency_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_workers_updated_at
  BEFORE UPDATE ON workers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE workers IS
  'Worker profiles. Rate columns must never be selected for worker/supervisor roles — enforce at query layer.';
COMMENT ON COLUMN workers.cost_rate IS
  'Internal cost to the business. Visible to resource_manager, finance, director only.';
COMMENT ON COLUMN workers.charge_out_rate IS
  'Rate charged to clients. Visible to finance, director only.';
COMMENT ON COLUMN workers.linked_user_id IS
  'Auth user account for this worker, if they have app access. Null = SMS-only dispatch.';

-- 4. RLS for workers -----------------------------------------------------

ALTER TABLE workers ENABLE ROW LEVEL SECURITY;

-- resource_manager, finance, director see all workers in their tenant.
-- worker, supervisor can only see their own profile (if linked_user_id is set).
CREATE POLICY "workers_select"
  ON workers FOR SELECT TO authenticated
  USING (
    deleted_at IS NULL
    AND tenant_id = current_tenant_id()
    AND (
      (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
      OR linked_user_id = auth.uid()
    )
  );

CREATE POLICY "workers_insert"
  ON workers FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  );

CREATE POLICY "workers_update"
  ON workers FOR UPDATE TO authenticated
  USING (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  )
  WITH CHECK (
    tenant_id = current_tenant_id()
    AND (auth.jwt() ->> 'role') IN ('resource_manager', 'finance', 'director')
  );

-- End of migration
