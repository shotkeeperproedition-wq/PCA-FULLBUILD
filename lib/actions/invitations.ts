'use server'

import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import type { Database } from '@/lib/types/database'
import { requireRole, ROLES, type UserRole } from '@/lib/auth/roles'

type Invitation = Database['public']['Tables']['invitations']['Row']

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

  let membership
  try {
    membership = await requireRole(user.id, ROLES.OPERATIONS)
  } catch {
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
// memberships, and marks the invitation accepted.
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
