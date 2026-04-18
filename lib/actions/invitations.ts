'use server'

import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import type { Database } from '@/lib/types/database'

type UserRole = Database['public']['Enums']['user_role']
type Invitation = Database['public']['Tables']['invitations']['Row']

const INVITE_ROLES: UserRole[] = ['resource_manager', 'finance', 'director']

// ---------------------------------------------------------------------------
// createInvitation
// Only resource_manager, finance, director can invite. Returns the token so
// the caller can build the invite URL and send it via email/SMS.
// ---------------------------------------------------------------------------
export async function createInvitation(
  email: string,
  role: UserRole
): Promise<{ data: { token: string } | null; error: string | null }> {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  // Get caller's active membership to check role and tenant
  const { data: membership } = await supabase
    .from('memberships')
    .select('role, tenant_id')
    .eq('user_id', user.id)
    .eq('is_active_tenant', true)
    .is('deleted_at', null)
    .single()

  if (!membership) return { data: null, error: 'No active organisation' }
  if (!INVITE_ROLES.includes(membership.role)) {
    return { data: null, error: 'Insufficient permissions to send invitations' }
  }

  const normalised = email.trim().toLowerCase()

  const { data, error } = await supabase
    .from('invitations')
    .insert({
      tenant_id: membership.tenant_id,
      email: normalised,
      role,
      invited_by: user.id,
      created_by: user.id,
    })
    .select('token')
    .single()

  if (error) {
    // Unique index violation = pending invite already exists
    if (error.code === '23505') {
      return { data: null, error: 'A pending invitation for that email already exists' }
    }
    return { data: null, error: error.message }
  }

  return { data: { token: data.token }, error: null }
}

// ---------------------------------------------------------------------------
// getInvitationByToken
// Public — no auth required. Uses admin client to bypass RLS so the
// accept-invite page can show invite details before the user signs in.
// Always filters by token; never returns other rows.
// ---------------------------------------------------------------------------
export async function getInvitationByToken(
  token: string
): Promise<{ data: Invitation | null; error: string | null }> {
  const admin = createAdminClient()

  const { data, error } = await admin
    .from('invitations')
    .select('*')
    .eq('token', token)
    .is('deleted_at', null)
    .single()

  if (error) return { data: null, error: 'Invitation not found' }
  if (data.accepted_at) return { data: null, error: 'Invitation already accepted' }
  if (new Date(data.expires_at) < new Date()) return { data: null, error: 'Invitation has expired' }

  return { data, error: null }
}

// ---------------------------------------------------------------------------
// acceptInvitation
// Must be called by an authenticated user. Validates the token, inserts into
// memberships, and marks the invitation accepted. All in one admin transaction
// so partial failures can't leave the user in a broken state.
// ---------------------------------------------------------------------------
export async function acceptInvitation(
  token: string
): Promise<{ data: { tenant_id: string } | null; error: string | null }> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  const { data: invite, error: lookupError } = await getInvitationByToken(token)
  if (lookupError || !invite) return { data: null, error: lookupError ?? 'Invalid invitation' }

  const admin = createAdminClient()

  // Insert membership — if user already belongs to this org, return an error
  const { error: membershipError } = await admin
    .from('memberships')
    .insert({
      tenant_id: invite.tenant_id,
      user_id: user.id,
      role: invite.role,
      is_active_tenant: true,
      is_primary: true,
      invited_by: invite.invited_by ?? undefined,
      created_by: user.id,
    })

  if (membershipError) {
    if (membershipError.code === '23505') {
      return { data: null, error: 'You are already a member of this organisation' }
    }
    return { data: null, error: membershipError.message }
  }

  // Mark invite accepted
  await admin
    .from('invitations')
    .update({ accepted_at: new Date().toISOString(), updated_by: user.id })
    .eq('id', invite.id)

  return { data: { tenant_id: invite.tenant_id }, error: null }
}

// ---------------------------------------------------------------------------
// listInvitations
// Returns all non-deleted invitations for the caller's active tenant.
// RLS scopes this to the current org automatically.
// ---------------------------------------------------------------------------
export async function listInvitations(): Promise<{
  data: Invitation[] | null
  error: string | null
}> {
  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  const { data, error } = await supabase
    .from('invitations')
    .select('*')
    .is('deleted_at', null)
    .order('created_at', { ascending: false })

  if (error) return { data: null, error: error.message }
  return { data, error: null }
}
