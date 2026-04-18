'use server'

import { createClient } from '@/lib/supabase/server'
import { requireRole, ROLES, type UserRole } from '@/lib/auth/roles'
import type { Database } from '@/lib/types/database'

type Worker      = Database['public']['Tables']['workers']['Row']
type WorkerInsert = Database['public']['Tables']['workers']['Insert']
type WorkerUpdate = Database['public']['Tables']['workers']['Update']

// Column sets — never expose rate fields to worker/supervisor roles
const COLS_FULL       = '*'
const COLS_RESTRICTED =
  'id,tenant_id,first_name,last_name,preferred_name,mobile,email,' +
  'employment_type,status,agency_id,avatar_url,linked_user_id,' +
  'emergency_contact_name,emergency_contact_phone,' +
  'address,suburb,state,postcode,date_of_birth,' +
  'tfn_provided,abn,created_at,updated_at,deleted_at'
// cost_rate deliberately absent from COLS_RESTRICTED
// charge_out_rate deliberately absent from COLS_RESTRICTED

// Return type for callers that may get a partial row
export type WorkerSafe = Omit<Worker, 'cost_rate' | 'charge_out_rate'>
export type WorkerWithRates = Worker

function selectCols(role: UserRole): string {
  if (ROLES.FINANCE.includes(role))     return COLS_FULL          // finance + director
  if (ROLES.OPERATIONS.includes(role))  return COLS_FULL          // resource_manager gets cost_rate too
  return COLS_RESTRICTED                                          // worker + supervisor
}

// ---------------------------------------------------------------------------
// listWorkers
// resource_manager+ see all workers. worker/supervisor see only their own row
// (RLS handles scoping). Rate columns omitted for worker/supervisor.
// ---------------------------------------------------------------------------
export async function listWorkers(): Promise<{
  data: WorkerSafe[] | WorkerWithRates[] | null
  error: string | null
}> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  const { data: membership } = await supabase
    .from('memberships').select('role').eq('user_id', user.id)
    .eq('is_active_tenant', true).is('deleted_at', null).single()

  const role: UserRole = membership?.role ?? 'worker'

  const { data, error } = await supabase
    .from('workers')
    .select(selectCols(role))
    .is('deleted_at', null)
    .order('last_name', { ascending: true })
    .order('first_name', { ascending: true })

  if (error) return { data: null, error: error.message }
  return { data: data as unknown as WorkerSafe[] | WorkerWithRates[], error: null }
}

// ---------------------------------------------------------------------------
// getWorker
// ---------------------------------------------------------------------------
export async function getWorker(id: string): Promise<{
  data: WorkerSafe | WorkerWithRates | null
  error: string | null
}> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  const { data: membership } = await supabase
    .from('memberships').select('role').eq('user_id', user.id)
    .eq('is_active_tenant', true).is('deleted_at', null).single()

  const role: UserRole = membership?.role ?? 'worker'

  const { data, error } = await supabase
    .from('workers')
    .select(selectCols(role))
    .eq('id', id)
    .is('deleted_at', null)
    .single()

  if (error) return { data: null, error: 'Worker not found' }
  return { data: data as unknown as WorkerSafe | WorkerWithRates, error: null }
}

// ---------------------------------------------------------------------------
// createWorker — resource_manager+ only
// ---------------------------------------------------------------------------
export async function createWorker(
  input: Omit<WorkerInsert, 'id' | 'tenant_id' | 'created_at' | 'updated_at' | 'created_by' | 'updated_by' | 'deleted_at'>
): Promise<{ data: Worker | null; error: string | null }> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  let membership
  try {
    membership = await requireRole(user.id, ROLES.OPERATIONS)
  } catch {
    return { data: null, error: 'Insufficient permissions' }
  }

  const { data, error } = await supabase
    .from('workers')
    .insert({ ...input, tenant_id: membership.tenant_id, created_by: user.id })
    .select()
    .single()

  if (error) return { data: null, error: error.message }
  return { data, error: null }
}

// ---------------------------------------------------------------------------
// updateWorker — resource_manager+ only
// Workers cannot update their own profiles directly (go through HR request).
// ---------------------------------------------------------------------------
export async function updateWorker(
  id: string,
  input: Partial<Omit<WorkerUpdate, 'id' | 'tenant_id' | 'created_at' | 'created_by' | 'deleted_at'>>
): Promise<{ data: Worker | null; error: string | null }> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { data: null, error: 'Not authenticated' }

  try {
    await requireRole(user.id, ROLES.OPERATIONS)
  } catch {
    return { data: null, error: 'Insufficient permissions' }
  }

  const { data, error } = await supabase
    .from('workers')
    .update({ ...input, updated_by: user.id })
    .eq('id', id)
    .is('deleted_at', null)
    .select()
    .single()

  if (error) return { data: null, error: error.message }
  return { data, error: null }
}

// ---------------------------------------------------------------------------
// archiveWorker — soft delete, resource_manager+ only
// Sets deleted_at. The worker's history (timesheets, dockets) is preserved.
// ---------------------------------------------------------------------------
export async function archiveWorker(id: string): Promise<{ error: string | null }> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { error: 'Not authenticated' }

  try {
    await requireRole(user.id, ROLES.OPERATIONS)
  } catch {
    return { error: 'Insufficient permissions' }
  }

  const { error } = await supabase
    .from('workers')
    .update({ deleted_at: new Date().toISOString(), updated_by: user.id })
    .eq('id', id)
    .is('deleted_at', null)

  if (error) return { error: error.message }
  return { error: null }
}
