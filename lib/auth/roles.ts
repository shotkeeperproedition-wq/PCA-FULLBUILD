import type { Database } from '@/lib/types/database'
import { createAdminClient } from '@/lib/supabase/admin'

export type UserRole = Database['public']['Enums']['user_role']
type MembershipRow = Database['public']['Tables']['memberships']['Row']

// ---------------------------------------------------------------------------
// Named role sets — import these instead of writing inline arrays
// ---------------------------------------------------------------------------
export const ROLES = {
  /** Every authenticated user */
  ALL: ['worker', 'supervisor', 'resource_manager', 'finance', 'director'] as UserRole[],
  /** Supervisors and above */
  SUPERVISOR_PLUS: ['supervisor', 'resource_manager', 'finance', 'director'] as UserRole[],
  /** Operations managers and above */
  OPERATIONS: ['resource_manager', 'finance', 'director'] as UserRole[],
  /** Finance and directors only — can see rates, invoices, margins */
  FINANCE: ['finance', 'director'] as UserRole[],
  /** Director only */
  DIRECTOR: ['director'] as UserRole[],
} as const

// ---------------------------------------------------------------------------
// requireRole — async server-side guard
// Use in server actions and route handlers. Throws "Unauthorised" so the
// caller can propagate it as a 401/403 response or convert to { error }.
// Returns the active membership row so callers get tenant_id for free.
// ---------------------------------------------------------------------------
export async function requireRole(
  userId: string,
  allowedRoles: UserRole[]
): Promise<MembershipRow> {
  const admin = createAdminClient()

  const { data: membership, error } = await admin
    .from('memberships')
    .select('*')
    .eq('user_id', userId)
    .eq('is_active_tenant', true)
    .is('deleted_at', null)
    .single()

  if (error || !membership) throw new Error('Unauthorised')
  if (!(allowedRoles as string[]).includes(membership.role)) throw new Error('Unauthorised')

  return membership
}

// ---------------------------------------------------------------------------
// hasRole — sync client-side / server-component helper
// Safe to call with null or undefined user — returns false.
// ---------------------------------------------------------------------------
export function hasRole(
  user: { role?: UserRole | null } | null | undefined,
  allowedRoles: UserRole[]
): boolean {
  if (!user?.role) return false
  return (allowedRoles as string[]).includes(user.role)
}
