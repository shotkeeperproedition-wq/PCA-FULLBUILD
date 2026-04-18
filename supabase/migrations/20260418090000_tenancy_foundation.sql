-- =============================================================================
-- Migration: 20260418_001_tenancy_foundation
-- Module: 1 — Foundation (auth, tenancy, RBAC)
-- Purpose: Core multi-tenancy schema. Creates organizations, memberships, the
--          user_role enum, shared updated_at trigger, and RLS policies.
-- =============================================================================
-- Rollback:
--   DROP TABLE IF EXISTS memberships CASCADE;
--   DROP TABLE IF EXISTS organizations CASCADE;
--   DROP FUNCTION IF EXISTS set_updated_at() CASCADE;
--   DROP FUNCTION IF EXISTS current_tenant_id() CASCADE;
--   DROP TYPE IF EXISTS user_role;
-- =============================================================================

-- 1. Shared updated_at trigger function
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $func$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION set_updated_at() IS
  'Shared trigger function. Attach BEFORE UPDATE on any table with an updated_at column.';

-- 2. Role enum (lowest-privilege first)
CREATE TYPE user_role AS ENUM (
  'worker',
  'supervisor',
  'resource_manager',
  'finance',
  'director'
);

COMMENT ON TYPE user_role IS
  'The five platform roles. See CLAUDE.md for permission boundaries per role.';

-- 3. organizations — the tenant table
CREATE TABLE organizations (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL CHECK (length(trim(name)) > 0),
  slug           TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$'),
  abn            TEXT,
  logo_url       TEXT,
  timezone       TEXT NOT NULL DEFAULT 'Australia/Sydney',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at     TIMESTAMPTZ
);

CREATE INDEX idx_organizations_slug ON organizations(slug) WHERE deleted_at IS NULL;
CREATE INDEX idx_organizations_deleted_at ON organizations(deleted_at) WHERE deleted_at IS NOT NULL;

CREATE TRIGGER trg_organizations_updated_at
  BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE organizations IS
  'The tenant table. Every business table has a tenant_id FK referencing this.';
COMMENT ON COLUMN organizations.abn IS
  'Australian Business Number, 11 digits, nullable during onboarding. Validation at app layer.';

-- 4. memberships — user ↔ organization ↔ role
CREATE TABLE memberships (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id            UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role               user_role NOT NULL,
  is_active_tenant   BOOLEAN NOT NULL DEFAULT FALSE,
  is_primary         BOOLEAN NOT NULL DEFAULT FALSE,
  invited_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  joined_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at         TIMESTAMPTZ,
  UNIQUE (user_id, tenant_id)
);

CREATE UNIQUE INDEX uniq_memberships_one_active_per_user
  ON memberships(user_id)
  WHERE is_active_tenant = TRUE AND deleted_at IS NULL;

CREATE UNIQUE INDEX uniq_memberships_one_primary_per_user
  ON memberships(user_id)
  WHERE is_primary = TRUE AND deleted_at IS NULL;

CREATE INDEX idx_memberships_tenant ON memberships(tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_memberships_user ON memberships(user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_memberships_tenant_role ON memberships(tenant_id, role) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_memberships_updated_at
  BEFORE UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE memberships IS
  'User to organization join with role. A user can belong to many orgs; exactly one is active (stamped into JWT).';
COMMENT ON COLUMN memberships.is_active_tenant IS
  'Exactly one membership per user has this TRUE. The JWT custom claims hook reads this row to set tenant_id and role.';
COMMENT ON COLUMN memberships.is_primary IS
  'The user home org. Set once at signup, where they land at login if no active tenant is set.';

-- 5. Row Level Security
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "orgs_visible_to_members"
  ON organizations
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM memberships m
      WHERE m.tenant_id = organizations.id
        AND m.user_id = auth.uid()
        AND m.deleted_at IS NULL
    )
    AND organizations.deleted_at IS NULL
  );

CREATE POLICY "memberships_tenant_isolation_or_own"
  ON memberships
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND (
      tenant_id = NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid
      OR user_id = auth.uid()
    )
  );

-- 6. Helper: current_tenant_id()
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS UUID
LANGUAGE sql
STABLE
AS $func$
  SELECT NULLIF(auth.jwt() ->> 'tenant_id', '')::uuid;
$func$;

COMMENT ON FUNCTION current_tenant_id() IS
  'Returns the active tenant_id from the JWT custom claims, or NULL.';

-- End of migration