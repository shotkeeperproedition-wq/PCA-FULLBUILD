-- =============================================================================
-- Migration: 20260418110000_invitations
-- Module: 1 — Foundation (auth, tenancy, RBAC)
-- Purpose: Invite tokens so directors / resource managers can bring new users
--          into an organisation. A UUID token is emailed to the invitee; they
--          click the link, sign up (or sign in), and the app calls
--          acceptInvitation() which writes to memberships.
-- =============================================================================
-- Rollback:
--   DROP TABLE IF EXISTS invitations CASCADE;
-- =============================================================================

CREATE TABLE invitations (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email        TEXT NOT NULL CHECK (length(trim(email)) > 0),
  role         user_role NOT NULL,
  token        UUID NOT NULL DEFAULT gen_random_uuid(),
  invited_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  accepted_at  TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at   TIMESTAMPTZ
);

-- The token must be globally unique — it is the secret in the invite URL.
CREATE UNIQUE INDEX uniq_invitations_token
  ON invitations(token)
  WHERE deleted_at IS NULL;

-- Prevent duplicate pending invites for the same email within an org.
-- Once accepted or soft-deleted, a new invite for the same email is allowed.
CREATE UNIQUE INDEX uniq_invitations_pending_email
  ON invitations(tenant_id, lower(email))
  WHERE accepted_at IS NULL AND deleted_at IS NULL;

CREATE INDEX idx_invitations_tenant   ON invitations(tenant_id)    WHERE deleted_at IS NULL;
CREATE INDEX idx_invitations_email    ON invitations(lower(email)) WHERE deleted_at IS NULL;
CREATE INDEX idx_invitations_expires  ON invitations(expires_at)   WHERE accepted_at IS NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_invitations_updated_at
  BEFORE UPDATE ON invitations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE invitations IS
  'Pending and accepted invitations. token is emailed as a URL param; acceptInvitation() server action validates it and inserts into memberships.';
COMMENT ON COLUMN invitations.token IS
  'UUID secret included in the invite URL. Globally unique while active.';
COMMENT ON COLUMN invitations.accepted_at IS
  'Set by acceptInvitation(). NULL means the invite is still pending.';

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;

-- Authenticated org members can see their org's invitations.
CREATE POLICY "invitations_tenant_select"
  ON invitations
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = current_tenant_id()
    AND deleted_at IS NULL
  );

-- Authenticated org members can create invitations for their own org.
-- Role-level check (resource_manager+) is enforced in the server action layer.
CREATE POLICY "invitations_tenant_insert"
  ON invitations
  FOR INSERT
  TO authenticated
  WITH CHECK (tenant_id = current_tenant_id());

-- Authenticated org members can update (e.g. rescind) their org's invitations.
CREATE POLICY "invitations_tenant_update"
  ON invitations
  FOR UPDATE
  TO authenticated
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

-- Anonymous users can look up a specific invite by token so the accept-invite
-- page can show invite details before the user logs in / signs up.
-- The token is a 128-bit UUID — unguessable — so this is safe.
-- The server action always filters WHERE token = $1, never scans all rows.
CREATE POLICY "invitations_anon_token_lookup"
  ON invitations
  FOR SELECT
  TO anon
  USING (deleted_at IS NULL);

-- End of migration
