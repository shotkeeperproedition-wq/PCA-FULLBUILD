-- =============================================================================
-- Migration: 20260418_002_jwt_custom_claims_hook
-- Module: 1 — Foundation (auth, tenancy, RBAC)
-- Purpose: Postgres function called by Supabase Auth every time a JWT is
--          issued or refreshed. Injects tenant_id and role into the token
--          so RLS policies can filter on auth.jwt() ->> 'tenant_id'.
-- =============================================================================
-- This is the critical link between the memberships table (Step 1) and
-- every RLS policy on every business table. Without this hook enabled in
-- the Supabase dashboard, auth.jwt() ->> 'tenant_id' returns NULL and
-- every tenant-scoped query returns zero rows (fail-closed — correct but
-- looks like a broken app).
--
-- DESIGN PRINCIPLES:
-- 1. Fail-safe: any error or missing data returns the base JWT unchanged,
--    never blocks login. A missing tenant_id claim is recoverable; locking
--    every user out of the app is not.
-- 2. Single source of truth: reads from memberships.is_active_tenant.
--    Step 1's partial unique index guarantees at most one such row per user.
-- 3. Minimal claims: only tenant_id and role go into the JWT. Nothing
--    sensitive (no names, no emails beyond what Supabase already includes).
--
-- ENABLING THE HOOK:
-- This migration creates the function and grants permissions. You MUST then
-- enable the hook manually in the Supabase dashboard — see instructions at
-- the end of this file. There is no SQL-only way to do this on hosted
-- Supabase.
--
-- Rollback:
--   (First disable the hook in the Supabase dashboard)
--   DROP FUNCTION IF EXISTS public.custom_access_token_hook(jsonb);
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The hook function
-- -----------------------------------------------------------------------------
-- Supabase Auth calls this with a single jsonb argument shaped like:
--   {
--     "user_id": "<uuid>",
--     "claims": { ...default JWT claims Supabase would have issued... }
--   }
-- The function must return a jsonb with the (possibly modified) claims.
-- We copy the claims, add our custom fields, and return. Anything we don't
-- touch is passed through unchanged.

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
-- SECURITY DEFINER: runs with the privileges of the function owner (postgres),
-- not the caller. Needed because the hook is invoked by the supabase_auth_admin
-- role which doesn't have direct access to memberships. We grant execute to
-- that role below.
SECURITY DEFINER
-- Lock down search_path so a malicious search_path can't redirect lookups.
SET search_path = public
AS $func$
DECLARE
  v_user_id  UUID;
  v_claims   JSONB;
  v_tenant   UUID;
  v_role     TEXT;
BEGIN
  -- Extract inputs with null-safety. If anything is malformed, return the
  -- event unchanged rather than erroring — an erroring hook blocks login.
  v_user_id := (event ->> 'user_id')::uuid;
  v_claims  := COALESCE(event -> 'claims', '{}'::jsonb);

  IF v_user_id IS NULL THEN
    RETURN event;
  END IF;

  -- Look up the user's active membership. At most one row thanks to the
  -- partial unique index uniq_memberships_one_active_per_user.
  SELECT m.tenant_id, m.role::text
    INTO v_tenant, v_role
  FROM memberships m
  WHERE m.user_id = v_user_id
    AND m.is_active_tenant = TRUE
    AND m.deleted_at IS NULL
  LIMIT 1;

  -- If no active membership, the user is authenticated but not scoped to any
  -- tenant yet (new signup, pre-org-creation). Return the base JWT unchanged;
  -- the app-layer middleware will redirect them to the org-creation flow.
  IF v_tenant IS NULL THEN
    RETURN event;
  END IF;

  -- Inject custom claims. These live at the top level of the JWT payload,
  -- readable via auth.jwt() ->> 'tenant_id' and auth.jwt() ->> 'role' in
  -- Postgres, and via the session user's access token on the client.
  v_claims := v_claims
    || jsonb_build_object('tenant_id', v_tenant::text)
    || jsonb_build_object('role', v_role);

  -- Return the event with our modified claims.
  RETURN jsonb_set(event, '{claims}', v_claims);

EXCEPTION
  WHEN OTHERS THEN
    -- Belt-and-braces: if anything unexpected happens (schema change,
    -- permission glitch, etc), return the original event. Login still works,
    -- user just has no tenant_id claim, app redirects them to create/join org.
    RETURN event;
END;
$func$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase Auth JWT hook. Reads memberships.is_active_tenant and injects tenant_id and role into the access token claims. Must be enabled in Supabase dashboard: Authentication > Hooks > Custom Access Token.';

-- -----------------------------------------------------------------------------
-- 2. Grants
-- -----------------------------------------------------------------------------
-- supabase_auth_admin is the role Supabase Auth uses when invoking hooks.
-- It needs EXECUTE on our function. We also revoke public EXECUTE as
-- defence in depth — only Supabase Auth should be calling this.

REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated, anon;

GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;

-- supabase_auth_admin also needs to be able to SELECT from memberships to
-- do the lookup inside the function. Because the function is SECURITY DEFINER,
-- it runs as the function owner (postgres), so this grant isn't strictly
-- required for the SELECT to work — but it's belt-and-braces in case the
-- ownership changes. Also grant the ability to read the role enum values.
GRANT SELECT ON TABLE public.memberships TO supabase_auth_admin;
GRANT USAGE ON TYPE public.user_role TO supabase_auth_admin;

-- =============================================================================
-- MANUAL STEPS REQUIRED AFTER APPLYING THIS MIGRATION
-- =============================================================================
-- 1. Go to Supabase Dashboard > Authentication > Hooks (or Auth Hooks)
-- 2. Find "Custom Access Token" hook
-- 3. Enable it, select "Postgres" as the hook type
-- 4. Select schema: public
-- 5. Select function: custom_access_token_hook
-- 6. Save
--
-- Until this is done, the function exists but is NEVER called. No JWT will
-- contain tenant_id or role. This is by design — the migration is safe to
-- apply without enabling the hook; enabling the hook is a separate, reversible
-- action you control from the dashboard.
-- =============================================================================
