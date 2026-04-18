import { createClient } from '@/lib/supabase/server'
import { ROLES, hasRole, type UserRole } from '@/lib/auth/roles'

function greeting() {
  const h = new Date().getHours()
  if (h < 12) return 'Good morning'
  if (h < 17) return 'Good afternoon'
  return 'Good evening'
}

function todayLabel() {
  return new Date().toLocaleDateString('en-AU', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  })
}

export default async function DashboardPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  const { data: membership } = await supabase
    .from('memberships')
    .select('role')
    .eq('user_id', user!.id)
    .eq('is_active_tenant', true)
    .is('deleted_at', null)
    .single()

  const role: UserRole = membership?.role ?? 'worker'
  const firstName = (user?.user_metadata?.full_name as string | undefined)?.split(' ')[0]
    ?? user?.email?.split('@')[0]
    ?? 'there'

  const showFinancial = hasRole({ role }, ROLES.FINANCE)

  return (
    <div className="p-6 max-w-5xl mx-auto">
      {/* Header */}
      <div className="mb-8">
        <h1 className="text-[36px] font-semibold leading-[1.1] tracking-[-0.02em] text-ink-900">
          {greeting()}, {firstName}
        </h1>
        <p className="text-ink-500 text-sm mt-1 font-mono">{todayLabel()}</p>
      </div>

      {/* Stat cards */}
      <div className={`grid gap-4 ${showFinancial ? 'grid-cols-2 md:grid-cols-4' : 'grid-cols-2 md:grid-cols-3'} mb-8`}>
        <StatCard label="Workers on site" value="0" hint="today" />
        <StatCard label="Jobs active"     value="0" hint="right now" />
        <StatCard label="Plant deployed"  value="0" hint="units" />
        {showFinancial && (
          <StatCard label="Invoices pending" value="0" hint="to generate" accent />
        )}
      </div>

      {/* Empty state */}
      <div className="rounded-[10px] border border-ink-200 bg-white p-8 text-center">
        <p className="text-ink-500 text-sm">
          No data yet — jobs and workers will appear here once Module 3 is built.
        </p>
      </div>
    </div>
  )
}

function StatCard({
  label, value, hint, accent = false,
}: {
  label: string
  value: string
  hint: string
  accent?: boolean
}) {
  return (
    <div className={`rounded-[10px] border p-5 ${accent ? 'border-pca-yellow bg-pca-yellow/10' : 'border-ink-200 bg-white'}`}>
      <p className="text-[11px] font-medium uppercase tracking-[0.06em] text-ink-500 mb-2">{label}</p>
      <p className="text-[28px] font-semibold leading-[1.1] text-ink-900 tabular-nums">{value}</p>
      <p className="text-xs text-ink-400 mt-1">{hint}</p>
    </div>
  )
}
