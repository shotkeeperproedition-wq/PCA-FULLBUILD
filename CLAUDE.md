# CLAUDE.md — Premier Constructions SaaS Platform

> Read this file completely before every session. Every decision you make must be consistent with everything in this document.

---

## Module 1 Status — Foundation (auth, tenancy, RBAC)

**Phase:** 1 — In progress
**Last updated:** 2026-04-18

### Architectural decisions made

- **No MakerKit.** We are rolling our own tenancy/auth schema. MakerKit was removed before any code was written.
- **Many-to-many user ↔ org model.** A single user can belong to multiple organisations. Exactly one membership has `is_active_tenant = TRUE` at any time — enforced by a partial unique index.
- **`is_primary` flag.** Indicates the user's home org (set at signup). Separate from `is_active_tenant` to support future org-switching.
- **JWT claims injected via SECURITY DEFINER hook.** `public.custom_access_token_hook` runs as the function owner (`postgres`) so it can read `memberships` even when called by `supabase_auth_admin`. Locked `search_path` to prevent path hijacking.
- **Fail-safe hook.** Any error inside the hook returns the base JWT unchanged — login still works, user just has no tenant claim and gets redirected to org-creation. Never blocks auth.
- **Migration naming convention.** Changed from `YYYYMMDD_NNN_name.sql` to `YYYYMMDDHHMMSS_name.sql` (full 14-digit timestamp). Supabase CLI requires unique numeric prefixes and this format provides natural ordering and no collision risk.

### What is complete

| Step | Description | Status |
|---|---|---|
| Step 1 | `20260418090000_tenancy_foundation.sql` — organizations, memberships, user_role enum, set_updated_at trigger, current_tenant_id helper, RLS policies | ✅ Applied (local + remote) |
| Step 2 | `20260418090400_jwt_custom_claims_hook.sql` — custom_access_token_hook SECURITY DEFINER function, grants to supabase_auth_admin | ✅ Applied (local + remote) |

### What remains

| Step | Description |
|---|---|
| Step 3 | `proxy.ts` (Next.js 16 equivalent of `middleware.ts`) — wires `updateSession` into the request pipeline. Auth protection active: unauthenticated requests to protected routes → 307 → /login. | ✅ Complete |
| Step 4 | `20260418110000_invitations.sql` — invitations table + RLS + 4 server actions (create, lookup by token, accept, list). Service role client at `lib/supabase/admin.ts`. | ✅ Complete |
| Step 5 | `lib/auth/roles.ts` — `requireRole` (async server guard), `hasRole` (sync null-safe helper), `ROLES` constants. All inline role arrays removed from codebase. | ✅ Complete |

### Manual step still required

The JWT hook function exists in the database but must be enabled in the dashboard:
**Supabase Dashboard → Authentication → Hooks → Custom Access Token → Enable → schema: public, function: custom_access_token_hook**
Without this, no JWT will contain `tenant_id` or `role`.

---

## What we are building

A vertical SaaS platform for the Australian construction industry. It manages labour hire, wet plant hire (cranes and trucks), and contract works. It is being built first for Premier Constructions, then commercialised and sold to other Australian construction companies.

This is a real production system. Real workers, real jobs, real money. Every decision must be production-quality.

---

## Tech stack — never deviate without explicit approval

| Layer | Technology | Notes |
|---|---|---|
| Web framework | Next.js (App Router) + TypeScript | All routes use App Router, never Pages Router |
| Styling | Tailwind CSS + shadcn/ui | Use existing shadcn components before building custom ones |
| Database | Supabase (PostgreSQL) | Sydney region ap-southeast-2 — mandatory |
| Auth | Supabase Auth (custom tenancy) | MakerKit removed — rolling our own tenancy/auth schema. See Module 1 Status above. |
| File storage | Supabase Storage | All uploads go here |
| Mobile | PWA at /field route (phase 1), React Native Expo (phase 2) | |
| Hosting | Vercel (syd1 region) | Deploy after every working feature |
| SMS | Twilio Node.js SDK | Never raw HTTP, always use SDK |
| Invoicing | xero-node SDK only | Never write raw Xero API calls — hallucination risk |
| Payroll export | Employment Hero (KeyPay) API | |
| PDF generation | @react-pdf/renderer | |
| Email | Resend | |
| Background jobs | Supabase Edge Functions + pg_cron | |

---

## Project structure

```
/app                        # Next.js App Router
  /(dashboard)              # Web dashboard — office staff
    /workers                # Worker management
    /jobs                   # Job management
    /schedule               # Weekly schedule view
    /plant                  # Plant & fleet management
    /billing                # Billing queue & invoicing
    /settings               # Org settings, Xero connection
  /(field)                  # Mobile PWA — field workers
    /today                  # Today's jobs
    /job/[id]               # Job detail + clock-in
    /diary/[id]             # Site diary form
    /docket/[id]            # Docket + signature
    /prestart/[id]          # Vehicle pre-start
/components
  /ui                       # shadcn/ui components (never modify)
  /dashboard                # Dashboard-specific components
  /field                    # Field app components (mobile-optimised)
/lib
  /supabase                 # Supabase client, server, middleware
  /types                    # All TypeScript types and interfaces
  /validations              # Zod schemas
  /utils                    # Pure utility functions
/supabase
  /migrations               # All database migrations in order
  /functions                # Supabase Edge Functions
```

---

## Database rules — apply to every single table without exception

### Mandatory columns on every business data table

```sql
id              UUID PRIMARY KEY DEFAULT gen_random_uuid()
tenant_id       UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE
created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
created_by      UUID REFERENCES auth.users(id)
updated_by      UUID REFERENCES auth.users(id)
deleted_at      TIMESTAMPTZ  -- soft delete, never hard delete business data
```

### Row Level Security — mandatory pattern

Every table must have RLS enabled with this policy structure:

```sql
ALTER TABLE [table_name] ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tenant_isolation" ON [table_name]
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
```

### Migration rules

- Every schema change is a new numbered migration file in /supabase/migrations/
- Never modify an existing migration after it has been run
- Always include rollback comments
- Test migrations locally before applying to production
- Name format: `20260418090400_name.sql` — full 14-digit timestamp (YYYYMMDDHHMMSS). This replaced the earlier `YYYYMMDD_NNN_name.sql` format; the CLI requires unique numeric prefixes and full timestamps avoid collisions.

### Never do these things

- Never use sequential integer IDs (use UUIDs)
- Never hard delete business data (use deleted_at soft delete)
- Never bypass RLS in application code
- Never write raw SQL in components (use server actions or Supabase client)
- Never store sensitive data (rates, margins) in client-accessible locations

---

## The five user roles

These are stored in the JWT custom claims and enforced by RLS policies. Every feature must respect these boundaries.

### worker
- Sees: their own allocated jobs, their own clock-in/out, their own dockets, their own hours this week
- Cannot see: other workers, any dollar amounts, rates, margins, invoice values, client financial details
- Field app access: yes — /field routes only by default

### supervisor
- Sees: everything worker sees + full team on their assigned jobs, plant on their jobs
- Can do: fill site diaries, confirm worker hours, sign off dockets
- Cannot see: any dollar amounts, rates, charge-out, margins, invoice values

### resource_manager
- Sees: all workers, all jobs, all plant, worker cost rates (not charge-out rates), availability
- Can do: create and allocate jobs, dispatch workers, manage plant allocation, view skills matrix
- Cannot see: charge-out rates, invoice values, margins

### finance
- Sees: everything resource_manager sees + charge-out rates, invoice values, billing queue, Xero sync
- Can do: generate invoices, manage billing queue, connect Xero
- Cannot do: allocate workers or manage operations

### director
- Full access to everything including margins, profitability, all financial data, business intelligence
- Can do: everything

### Implementing role checks in code

```typescript
// Always use this pattern for role-gated content
import { useRole } from '@/lib/auth/hooks'

const { hasRole } = useRole()

// Show financial data only to finance and above
{hasRole(['finance', 'director']) && (
  <span>{formatCurrency(job.chargeOutRate)}</span>
)}

// Show cost rates only to resource_manager and above
{hasRole(['resource_manager', 'finance', 'director']) && (
  <span>{formatCurrency(worker.costRate)}</span>
)}
```

---

## The three job types

### Day works
Single-day or short-term jobs. Franna lift with operator and rigger, or labour hire for a shift.

Key rules:
- Must have PO number before invoice can be generated (not before work commences)
- Each machine invoiced separately with its own docket
- Minimum 4-hour billing for all wet hire plant — enforced in billing calculation
- Docket must be signed by client supervisor before going to billing queue

### Contract works (including T2D)
Accepted contract with staged delivery over weeks or months.

Key rules:
- Each zone on T2D has its own PO number, cost code, supervisor, and geofence
- Multi-stop truck days: cost split automatically by time on site per stop
- Site diary required every working day — feeds progress claim billing
- Timesheet match check runs automatically when diary is submitted
- Progress claims generated from approved diaries

### Wet hire
Machine hire only (Franna, flatbed, tilt tray) — client may supply their own operators.

Key rules:
- Absolute minimum 4 hours billing regardless of actual time — enforce in code, not just UI
- Each machine is a separate line item on the invoice
- Docket generated per machine per day
- Operator licence must match machine requirements — check before allocation

---

## Special business rules — encode these in the system

### Sleeper dockets
When a worker completes a night shift and has no following night shift:
- System automatically generates an 8-hour sleeper docket
- Rate: sleeper day rate (stored per worker or as a system rate)
- Billed to the same client as the original night shift
- Trigger: detect in the shift scheduling logic when a night shift has no following night shift for that worker

### 38-hour obligation
Full-time (FT) workers are entitled to 38 hours per week whether or not they work them:
- Track hours allocated per FT worker per week
- Flag to resource_manager when an FT worker is projected to be under 38 hours by Wednesday
- Suggest available jobs that match their skills to fill the gap
- Weekly summary visible on Monday morning dashboard

### PO number tracking
- Jobs can commence without a PO number
- Every job without a PO must have a `po_owner` assigned — the person responsible for getting it
- Automated weekly email to po_owners listing their outstanding POs
- 5 days before month end: escalate to resource_manager if still missing
- Billing queue blocks invoice generation for jobs with no PO number — shows clear warning with owner name

### T2D multi-zone specifics
T2D (tunnel project) has 6 zones. Each zone is effectively a separate client engagement:
- Zone A: Rozelle Ave, Gate 1, PO-T2D-4401, cost code CC-301
- Zone B: Canal Rd, Gate 4, PO-T2D-4418, cost code CC-302
- Zone C: Lilyfield Rd, Gate 3, PO-T2D-4471, cost code CC-304
- Zone D, E, F: configured in the system, not hardcoded
- Workers must have T2D site induction AND zone-specific induction
- Zones a worker is not inducted for must be greyed out and untappable in field app

### Multi-stop cost splitting
When a truck visits multiple job sites in one day:
- Record arrival and departure time at each site via geo clock-in/out
- Calculate each site's percentage of total billable time
- Apply that percentage to the daily machine cost
- Show split clearly on each site's docket
- Auto-calculate — resource_manager should never do this manually

---

## The 18 modules — build sequence

| # | Module | Phase | Status |
|---|---|---|---|
| 1 | Foundation — auth, tenancy, RBAC | Phase 1 | ✅ Complete |
| 2 | Worker profiles | Phase 2 | Not started |
| 3 | Skills & tickets matrix | Phase 2 | Not started |
| 4 | Clients & projects | Phase 3 | Not started |
| 5 | Plant & fleet | Phase 3 | Not started |
| 6 | Job scheduler | Phase 3 | Not started |
| 7 | Resource allocation engine | Phase 3 | Not started |
| 8 | Dispatch & SMS notifications | Phase 3 | Not started |
| 9 | Field app — PWA shell | Phase 4 | Not started |
| 10 | Geo clock-in / out | Phase 4 | Not started |
| 11 | Universal site diary | Phase 4 | Not started |
| 12 | Timesheet match engine | Phase 4 | Not started |
| 13 | Dockets & client signatures | Phase 4 | Not started |
| 14 | Billing queue | Phase 5 | Not started |
| 15 | PO tracking & alerts | Phase 5 | Not started |
| 16 | Invoice generation + Xero sync | Phase 5 | Not started |
| 17 | HR — leave, 38hr, sleeper dockets, payroll | Phase 6 | Not started |
| 18 | AI priority engine & forecasting | Phase 6 | Not started |

Update the status column as modules are completed.

---

## Design principles — every screen must follow these

### Mobile-first
Every screen must work perfectly on a phone browser before desktop. Test on a real phone after every feature. Field app screens: large tap targets (minimum 44px), minimal typing, one action per screen.

### Role-based visibility — the golden rule
Never show dollar amounts, rates, margins, or invoice values to worker or supervisor roles. This is enforced at the component level AND at the database query level (never return financial data in queries for those roles).

### Pre-populate everything
Workers should never enter data the system already has. When a worker opens their job in the field app:
- Client name, site address, start time — already there
- Their required tickets for the site — already verified
- Their ute allocation — already assigned
- The docket — already pre-populated from the schedule

### Field app UX rules
- Maximum 3 taps to complete any common action (clock-in, submit diary, sign docket)
- Every action must have a clear confirmation state
- All data must save immediately — never lose a clock-in or signature due to connectivity
- Use the browser's native camera for photos, native geolocation for GPS

---

## How to work with Claude Code — session rules

### Start every session with this
```
Read CLAUDE.md completely. We are working on [module name] today.
Current state: [brief description of where we left off].
```

### One thing at a time
Never ask for more than one feature per message. Break complex features into steps:
1. Database migration first
2. TypeScript types second
3. Server action / API route third
4. UI component last

### After every feature
```
Run: npm run build
If it passes: git add . && git commit -m "feat: [description]"
Then: git push (triggers Vercel auto-deploy)
Test on phone at the Vercel preview URL
```

### When something breaks
```
"Revert the last change completely and let's try a different approach."
```
Never try to patch broken code — revert and restart the step cleanly.

### Things Claude must never do without explicit confirmation
- Modify RLS policies
- Change the auth flow or middleware
- Modify .env files or environment variable handling
- Change the tenant_id column or RLS on existing tables
- Delete or modify existing migrations
- Add new npm packages without checking for existing alternatives first

---

## TypeScript conventions

```typescript
// All database types generated from Supabase schema
// Run: npx supabase gen types typescript --local > lib/types/database.ts

// Naming conventions
type Worker = Database['public']['Tables']['workers']['Row']
type NewWorker = Database['public']['Tables']['workers']['Insert']
type UpdateWorker = Database['public']['Tables']['workers']['Update']

// All server actions in /lib/actions/[module].ts
// All queries in /lib/queries/[module].ts
// All Zod schemas in /lib/validations/[module].ts

// Role check utility — always use this, never check roles inline
import { requireRole, hasRole } from '@/lib/auth/roles'

// In server actions: throw if wrong role
await requireRole(userId, ['resource_manager', 'director'])

// In components: conditional render
{hasRole(user, ['finance', 'director']) && <FinancialData />}
```

---

## Environment variables reference

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=           # Never expose to client

# Xero — connect via /dashboard/settings/xero OAuth flow
XERO_CLIENT_ID=
XERO_CLIENT_SECRET=
XERO_REDIRECT_URI=

# Twilio
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=

# Email
RESEND_API_KEY=

# App
NEXT_PUBLIC_APP_URL=
```

---

## Current build status

**Boilerplate:** Next.js App Router + Supabase SSR (custom — MakerKit removed)
**Database:** Supabase — Sydney (ap-southeast-2), project ref: `yevnpnnapjsrucndabnu`
**Hosting:** Vercel — syd1 region (deployment protection active — test locally via `npm run dev`)
**Phase:** 2 — Worker Profiles

Update this section at the start of each module as work progresses.

---

## Key contacts and accounts

*(Fill these in as you set them up)*

- GitHub repo: `github.com/[your-username]/premier-constructions`
- Vercel project: `premier-constructions.vercel.app`
- Supabase project: `yevnpnnapjsrucndabnu.supabase.co`
- Xero app: registered at developer.xero.com
- Twilio account: console.twilio.com

---

*Last updated: 2026-04-18*
*This file must be updated whenever a module is completed or a significant architectural decision is made.*
