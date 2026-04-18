import { redirect } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/types/database'

type UserRole = Database['public']['Enums']['user_role']

// ---------------------------------------------------------------------------
// Nav definition — roles that can see each link
// ---------------------------------------------------------------------------
const NAV_ITEMS = [
  { href: '/dashboard',         label: 'Dashboard', icon: '▦', roles: ['worker', 'supervisor', 'resource_manager', 'finance', 'director'] as UserRole[] },
  { href: '/dashboard/workers', label: 'Workers',   icon: '◎', roles: ['resource_manager', 'finance', 'director'] as UserRole[] },
  { href: '/dashboard/jobs',    label: 'Jobs',      icon: '⊡', roles: ['worker', 'supervisor', 'resource_manager', 'finance', 'director'] as UserRole[] },
  { href: '/dashboard/schedule',label: 'Schedule',  icon: '▦', roles: ['resource_manager', 'finance', 'director'] as UserRole[] },
  { href: '/dashboard/plant',   label: 'Plant',     icon: '◈', roles: ['resource_manager', 'finance', 'director'] as UserRole[] },
  { href: '/dashboard/billing', label: 'Billing',   icon: '◇', roles: ['finance', 'director'] as UserRole[] },
  { href: '/dashboard/settings',label: 'Settings',  icon: '⚙', roles: ['director'] as UserRole[] },
]

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: membership } = await supabase
    .from('memberships')
    .select('role, tenant_id')
    .eq('user_id', user.id)
    .eq('is_active_tenant', true)
    .is('deleted_at', null)
    .single()

  const role: UserRole = membership?.role ?? 'worker'
  const visibleNav = NAV_ITEMS.filter(item => item.roles.includes(role))

  return (
    <div className="flex h-screen overflow-hidden bg-ink-100">

      {/* ── Sidebar (desktop ≥768px) ──────────────────────────────────────── */}
      <aside className="hidden md:flex md:flex-col md:w-60 bg-ink-900 shrink-0">
        {/* Logo */}
        <div className="flex items-center gap-3 px-5 py-5 border-b border-ink-800">
          {/* Geometric P mark */}
          <svg width="28" height="28" viewBox="0 0 28 28" fill="none" aria-hidden="true">
            <polygon points="4,4 16,4 20,8 8,8"   fill="#6CA739" />
            <polygon points="4,4 8,8 8,24 4,20"   fill="#6CA739" />
            <polygon points="4,4 16,4 16,8 8,8 8,16 4,16" fill="#F2D900" />
            <polygon points="8,8 20,8 20,16 8,16"  fill="#6CA739" opacity="0.7" />
            <polygon points="4,20 8,24 20,24 16,20" fill="#6CA739" />
          </svg>
          <div>
            <p className="text-white text-sm font-semibold leading-tight">Premier</p>
            <p className="text-ink-400 text-xs leading-tight">Constructions</p>
          </div>
        </div>

        {/* Nav */}
        <nav className="flex-1 py-4 overflow-y-auto">
          {visibleNav.map(item => (
            <Link
              key={item.href}
              href={item.href}
              className="flex items-center gap-3 px-5 py-2.5 text-ink-300 hover:text-white hover:bg-ink-800 text-sm font-medium transition-colors"
            >
              <span className="text-base leading-none">{item.icon}</span>
              {item.label}
            </Link>
          ))}
        </nav>

        {/* User footer */}
        <div className="px-5 py-4 border-t border-ink-800">
          <p className="text-ink-400 text-xs truncate">{user.email}</p>
          <p className="text-ink-600 text-xs mt-0.5 uppercase tracking-wide">{role.replace('_', ' ')}</p>
        </div>
      </aside>

      {/* ── Main content ──────────────────────────────────────────────────── */}
      <div className="flex flex-col flex-1 min-w-0">
        <main className="flex-1 overflow-y-auto pb-16 md:pb-0">
          {children}
        </main>
      </div>

      {/* ── Bottom nav (mobile <768px) ────────────────────────────────────── */}
      <nav className="md:hidden fixed bottom-0 inset-x-0 bg-ink-900 border-t border-ink-800 flex z-50">
        {visibleNav.slice(0, 5).map(item => (
          <Link
            key={item.href}
            href={item.href}
            className="flex-1 flex flex-col items-center justify-center gap-0.5 py-2 text-ink-400 hover:text-pca-green active:text-pca-green transition-colors min-h-[56px]"
          >
            <span className="text-lg leading-none">{item.icon}</span>
            <span className="text-[10px] uppercase tracking-wide leading-none">{item.label}</span>
          </Link>
        ))}
      </nav>
    </div>
  )
}
