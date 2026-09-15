---
name: security-audit
description: End-to-end security audit and remediation methodology for web apps, SaaS products, internal tools and backend-as-a-service projects. Use when asked to audit, review, harden or pen-test an application; to verify RLS/authorization/auth flows; to check for exposed secrets, privilege escalation, forgeable client input, unauthenticated serverless endpoints, or abuse/cost exposure; or to re-verify a previous audit. Covers reconnaissance, evidence-based findings, live-vs-repository drift, approval-gated remediation, attack-based testing, and audit history.
---

# Security Audit

A repeatable method for auditing and hardening an application you did not
write, ending in fixes that are **proven** rather than asserted.

It is written to work well on Postgres/RLS-based stacks (Supabase and
similar), and to degrade gracefully to any other architecture — plain
REST APIs, server-rendered frameworks, serverless, or a classic
three-tier app.

---

## The seven rules that govern everything

1. **Never trust the browser.** Anything the client sends is an
   attacker-chosen value until a trusted side re-derives or re-checks it.
2. **Never assume the repository equals production.** Migrations and
   deployed code drift. Verify live where tooling allows.
3. **Never treat a hidden UI control as authorization.** If the only
   thing stopping an action is a `if (isAdmin)` in the frontend, it is
   not stopped.
4. **Evidence or it did not happen.** Every finding cites a file, line,
   policy, function or live query result. Every fix is proven by running
   the original attack again.
5. **Read-only until authorized.** Phase 1 changes nothing.
6. **Understand every result.** A test that passes for a reason you
   cannot explain has not passed.
7. **A control being *enabled* is not the data being *protected*.**
   Name the property you actually care about — "no unauthenticated
   reader can see this" — and test *that*, by becoming the untrusted
   caller. "Row security is on for every table" is a statement about
   configuration; it can be entirely true while the data is readable by
   anyone through a path the row rules never see.

---

## Phase 0 — Scope and authorization

Before anything, establish in writing:

- **What is in scope**: repository only, or live infrastructure too?
- **Is live read access available?** Platform MCP, CLI, dashboard?
- **Is live *write* authorized?** Auditing is read-only by default.
- **Is this a first audit or a re-audit?**
- **Who approves remediation, and is approval pre-granted?**

If the user has pre-authorized remediation, you may proceed straight
through; otherwise **stop after the report and wait.**

> Never run an availability-affecting test (load, brute force, deletion,
> mass email) against production. Never exfiltrate real data. Never print
> a real secret, even one you found exposed — reference it by name and
> location.

---

## Phase 1 — Reconnaissance (read-only)

**Do not infer architecture from filenames or framework conventions.
Prove it.** A folder called `api/` may contain only client helpers; a
"full-stack" framework may have zero server code in this particular repo.

Produce a short **"What I found"** list. Write **"not present"** for
anything missing. Never guess.

| Question | How to establish it |
|---|---|
| Language, framework, versions | Package/lock manifests, build config, runtime files |
| Does ANY code run on a trusted side? | Look for API routes, server actions, serverless/edge functions, a separate backend service, middleware. Absence is a finding in itself. |
| Where does data live? | Hosted DB, BaaS, ORM, files, browser storage, nothing yet |
| How is a user identified? | Auth provider, hand-rolled sessions, API keys, none |
| How does it deploy, and where do env vars come from? | CI config, platform config files, build scripts |
| What external/paid services are integrated? | Email, SMS, payments, AI/model APIs, storage, push |

### The decisive question

> **Does the browser talk to the database or a privileged service
> directly, using a credential shipped in the bundle?**

If yes, the entire security model is whatever the database enforces.
Application-side filtering is irrelevant, because the attacker can skip
the application. Say this explicitly in the report — it reframes every
other finding.

### Trust boundary map

List each boundary and what crosses it:

```
browser ──(public key)──> database/BaaS        [enforced by: ?]
browser ──> API route ──> database             [enforced by: ?]
scheduler ──> serverless function ──> DB       [enforced by: ?]
third-party webhook ──> endpoint               [enforced by: ?]
```

Any box with `?` is where the audit concentrates.

---

## Phase 2 — Security history

Look for `SECURITY_HISTORY.md`, `SECURITY.md`, prior audit reports,
architecture notes, threat models, `CLAUDE.md`/`AGENTS.md`.

Read them as **historical context only**. A previous audit is evidence
about the past, not proof about the present. Fixes regress, migrations
get reverted, someone restores a database from an old snapshot.

**Re-verify every previously "fixed" item.** If no history file exists,
recommend creating one (see Phase 9).

**Re-examine every previously *accepted* item too, and ask what
accepting it costs elsewhere.** An accepted risk is a decision made
against one consideration; it usually has consequences nobody
enumerated at the time. "These views run as their owner, which we
accept" was a decision about one column in one screen — and it silently
made the grants on those views the only access control protecting them.
For each accepted item, write down what it *disables*, then go and check
whatever that was protecting.

---

## Phase 3 — The audit domains

Work the domains that apply. Skip inapplicable ones explicitly with one
line of reasoning — do not pad the report by mechanically scanning
categories the stack cannot have.

> **"Test" in this phase means read-only probing.** Reading catalogues,
> inspecting configuration, building with marker values, and reasoning
> from code are all in scope now. Anything that *writes* — creating a
> user, inserting a row, invoking an endpoint that has side effects,
> changing a policy — waits for approval, even inside a transaction you
> intend to roll back. If a finding can only be settled by a write, say
> so and mark it ⚪ pending, rather than performing it.

### 3.1 Secrets and credentials

Search code, config, committed env files, CI definitions, infrastructure
files, scheduled-job definitions, and **git history** where practical.

Look for: API keys, tokens, passwords, connection strings, private
signing keys, service-role/admin keys, SMTP credentials, OAuth secrets,
webhook signing secrets, push/VAPID private keys, storage credentials,
CI/CD secrets.

For each, answer the only question that matters:

> **Does it end up in what the browser downloads?**

Decide that from **this project's own build and env rules**, not from
convention. Frontend build tools inline variables by prefix at build
time; the prefix and the rules differ per tool and per version.

**Prove it with a marker build.** Give each variable a unique
recognisable value *through whatever mechanism the build actually reads*
(the env file the tool loads, or exported shell variables), build, then
grep the emitted bundle:

```bash
# generic shape — use this project's real env mechanism and build command
MY_PUBLIC_VAR=MARKER_AAA MY_SECRET_VAR=MARKER_BBB <build command>
grep -c 'MARKER_AAA' <output dir>/**/*.js    # non-zero => reaches the browser
grep -c 'MARKER_BBB' <output dir>/**/*.js    # non-zero => LEAK
```

A non-zero count proves client exposure. This takes two minutes and
replaces an argument with a fact. Restore the previous environment
afterwards, and never use a real secret as a marker.

Classify every credential as exactly one of:

- **Public by design** — e.g. a publishable/anon client key, a public
  half of a keypair. Correct to ship. *But say what it implies:* if that
  key reaches a database, the database's own rules are the only control.
- **Sensitive** — must not reach the browser; would let an attacker act
  as the app.
- **Privileged server-side** — service-role/admin credentials that
  bypass all access rules. Highest blast radius.

Also check: are env files git-ignored? Was a secret *ever* committed?
(History matters: rotating is required even if it was later removed.)

If nothing runs on a trusted side, say plainly: **every key this project
holds is public.**

### 3.2 Client-controlled values

Find every value that arrives from the browser and then **decides**
something:

roles · permissions · ownership · user/tenant/org IDs · prices · totals ·
quantities · transaction direction · discount codes · approval state ·
subscription tier · account status · feature flags · workflow state ·
billing state · audit attribution · `created_by`/`updated_by` ·
`isAdmin`-style flags · any id that selects *which record* to read or write.

For each, state whether the trusted side **re-derives**, **re-checks**,
or **takes it as sent**.

Anything in the browser is UX, not enforcement: a disabled button, a
form validator, a client-side schema, a hidden route.

> **Pattern to look for:** a value is validated in one path (a policy, an
> API handler) but a *second* path writes the same column without that
> check — a database trigger, an RPC, an admin endpoint, a bulk import,
> a webhook handler. Enumerate every writer of a security-sensitive
> column, not just the obvious one.

If there is no trusted side, list the values that are therefore forgeable
and treat that as the finding.

### 3.3 Authentication

Inspect: signup, login, password reset, magic links / OTP, invitations,
OAuth, email verification, anonymous sign-in, session handling, refresh
tokens, logout, account-creation triggers, profile creation, role
initialization.

Specific things that are wrong surprisingly often:

- **Role or entitlement taken from signup metadata.** The client chooses
  the metadata; a trigger or callback copies it into a privileged table.
  Any unauthenticated account-creation endpoint then becomes a
  self-service privilege grant.
- **Account-creation hooks that bypass access rules.** A database trigger
  or server-side hook that runs with elevated rights is *not* subject to
  the row-level rules you audited. A policy fix does not cover it.
- **Invite flows that carry privilege in the request.**
- **Auth settings that live outside the repository** — whether signup is
  open, password policy, leaked-password checks, session lifetimes, MFA.
  These are dashboard/console settings. Verify via platform tooling if
  possible; otherwise flag as manual.

> **Design principle:** a new account should be created at the *lowest*
> privilege, always, with elevation as a separate authenticated action by
> someone already privileged. That removes the dependency on a console
> toggle being set correctly.

### 3.4 Authorization and access control

Map every role and every permission. Then, for **every entry point that
reads or writes data**, state whether it requires a verified identity and
**where that check runs**.

Flag anything that:

- returns or changes user data with no check;
- relies on the interface hiding it;
- takes a **user/tenant id from the request** to decide whose data to
  return, instead of deriving it from the session.

Say whether **one choke point** covers every route, or the check is
repeated per handler — and if per-handler, list any handler not covered.

Test, where safe: horizontal escalation (another user's row), vertical
escalation (self-promotion), cross-tenant access, unauthorized bulk
operations, and privilege change via an alternate code path.

### 3.5 Database-enforced access (RLS / policy-based)

If the data store can enforce its own rules:

- **Verify live whether row-level security is actually ENABLED**, not
  merely that policies exist. *Policies without RLS enabled are inert.*
  This is a real and common failure: the `CREATE POLICY` statements apply
  while the `ENABLE ROW LEVEL SECURITY` statements silently do not, and
  the result looks correct in the repository and is wide open in
  production.
- Inspect SELECT / INSERT / UPDATE / DELETE policies **separately**. A
  table can be safe to read and open to write.
- Hunt for `USING (true)` and `WITH CHECK (true)` on write commands.
- Check **generated/dynamic policies** too — policies created in a loop
  or via dynamic SQL are invisible to a naive text search. Enumerate from
  the live catalogue, not by grepping migrations.
- Identify tables with RLS on and **zero** policies — usually deliberate
  (service-role only), sometimes an accident. Confirm which.
- Inspect elevated-privilege functions: what they do, who may execute
  them, whether their search path is pinned, and who owns them.
- Check whether the browser can reach the store directly with a bundled
  key. If it can, **these rules are the entire perimeter.**

Useful live census (adapt to your engine):

```sql
-- tables: is RLS on, how many policies, any permissive write rule
SELECT c.relname, c.relrowsecurity, COUNT(p.polname) AS policies,
       COUNT(*) FILTER (WHERE pg_get_expr(p.polqual,p.polrelid)='true'
                          AND p.polcmd <> 'r') AS permissive_writes
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
LEFT JOIN pg_policy p ON p.polrelid=c.oid
WHERE n.nspname='public' AND c.relkind='r'
GROUP BY 1,2 ORDER BY 2, 3;

-- insert policies that check nothing
SELECT c.relname, p.polname
FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid
WHERE p.polcmd='a' AND pg_get_expr(p.polwithcheck,p.polrelid)='true';
```

> **Elevated-privilege functions bypass row rules.** A function that runs
> as its owner is not subject to the policies you just verified. Audit
> those functions as separate, independent entry points — and remember
> that *triggers* written that way are entry points too.

#### Row rules are not the only gate: check the grants too

"RLS is enabled on every table" and "the data is protected" are two
different statements. A project can satisfy the first completely and
fail the second, because **a view that runs as its owner does not apply
the caller's row rules** — for such a view, the table-level grant is the
only thing between it and an unauthenticated reader.

So audit the grant table as its own domain, not as a footnote to RLS:

- **List what every role can read**, especially the anonymous / public
  role. Do not infer it from the policies; they do not apply here.
- **Assume the untrusted role and select from every object.** This is
  the only check that answers the real question. It takes one loop and
  it is the single highest-value query in this whole section.
- **Check the schema's DEFAULT privileges too.** Many platforms seed
  them so that every future object is granted to every role. Revoking
  the current grants without changing the defaults fixes nothing
  durably: the next migration that creates a table silently re-opens
  it. After changing them, prove it — create an object the way your
  migrations do, inside a transaction that rolls back, and read its
  ACL.
- Some default ACLs belong to a platform-owned role you cannot alter.
  Say so explicitly in the migration and in the report, and name what
  remains exposed. Do not let an `EXCEPTION WHEN insufficient_privilege`
  turn into a silent success.

```sql
-- what can the anonymous role actually read? (adapt the role name)
DO $$
DECLARE r record; n int; leaks text := '';
BEGIN
  SET LOCAL ROLE anon;                      -- the untrusted role
  FOR r IN SELECT c.relname FROM pg_class c
           JOIN pg_namespace ns ON ns.oid=c.relnamespace
           WHERE ns.nspname='public' AND c.relkind IN ('r','v') LOOP
    BEGIN
      EXECUTE format('SELECT COUNT(*) FROM public.%I', r.relname) INTO n;
      IF n > 0 THEN leaks := leaks || r.relname || '=' || n || '  '; END IF;
    EXCEPTION WHEN others THEN NULL;        -- denied is the good outcome
    END;
  END LOOP;
  RESET ROLE;
  RAISE EXCEPTION 'READABLE BY ANON >> % <<', leaks;   -- forces rollback
END $$;

-- and what will the NEXT object be granted?
SELECT pg_get_userbyid(d.defaclrole) AS granted_by,
       array_to_string(d.defaclacl, ' | ') AS default_acl
FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace
WHERE n.nspname='public';
```

#### Probe every object kind, and say which you probed

A census that loops over one `relkind` proves nothing about the other.
This is not hypothetical: an audit that enumerated only views reported
eleven leaking objects and called the exposure fully described. A later
pass that enumerated tables as well found five more, holding rows the
first report never mentioned. The fix had already covered both, so
nothing was actually exposed — but the *report* was wrong, and a reader
deciding what to prioritise would have been misled.

- Loop over tables **and** views (`relkind IN ('r','v')`), plus
  materialized views and foreign tables if the platform has them.
- Write down which kinds the probe covered, in the finding itself. A
  finding that does not say what it searched cannot be re-checked.
- The same applies to roles: probing the anonymous role says nothing
  about a second untrusted role, if the platform has one.

#### Read the policy's ROLE list, not just its expression

A policy with no `TO` clause applies to **PUBLIC** — which includes the
anonymous role. A project can have a careful-looking policy set where
every expression is correct and still have every policy addressed to
everyone, because `TO authenticated` was never written.

Check both halves, and treat them as independent controls:

```sql
-- policies addressed to PUBLIC rather than a named role
SELECT c.relname, p.polname, p.polcmd,
       pg_get_expr(p.polqual, p.polrelid) AS using_expr
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
WHERE p.polroles = '{0}'::oid[]          -- {0} means PUBLIC
ORDER BY 1, 2;
```

A `USING (true)` SELECT policy addressed to PUBLIC is protected only by
the grant. That is one layer. When the grant is also the thing you just
found wrong, it is zero layers with a lucky outcome — report it as a
finding even when the current grant makes it unreachable, and say
plainly that it is defence-in-depth rather than an open door.

When you re-declare a policy to fix its role list, **write each one out**
rather than regenerating them from the catalogue in a loop. A policy
rebuilt by dynamic SQL is unreviewable in a diff, and these are the
rules the system's security rests on. Re-state the expression exactly;
if you are also tightening it, that belongs on its own line where a
reviewer can see it.

Before changing any policy, establish which callers **bypass** row
security entirely — a platform service identity usually does, and so
does the owner of a definer function used by the signup path. Check
that first: it tells you which of your worries are real, and it is
cheaper than discovering after the fact that account creation broke.

#### A documented rule that nothing enforces is a finding

Specifications, role tables and README files describe intent; only code
enforces it. Where a document says "role X may only do Y", go and test
whether anything stops them doing Z. Treat the gap as a finding in its
own right, classified by consequence — often a scope gap rather than an
escalation, but never "already handled because it is written down".

When you close such a gap, check what the rule would break **before**
implementing it. A restriction written years earlier may contradict a
feature shipped since, and the people affected are usually the ones with
the least say. Enumerate every path that writes the columns or calls the
operation you are about to restrict — including pages that are not
gated, and privileged routines that already permit the role — and put
the conflict to the owner rather than resolving it silently in either
direction.

Two implementation notes that generalise:

- **Per-column authorization usually cannot be a grant.** Column
  privileges are per database role, and in a backend-as-a-service every
  signed-in user shares one. A grant intended to restrict the lesser
  role takes the column from the greater one too. The check belongs in
  a trigger or a policy that reads the application role.
- **Compare old to new, not "was the column supplied".** Clients
  commonly send the whole record on every save. A guard that fires on a
  column being present rejects every edit anyone makes, which looks like
  a broken feature rather than a security rule, and gets reverted.

#### A platform advisory is not always an actionable task

Managed platforms ship security linters, and they are worth running — but
they report the desired state, not what your plan or tier can actually
do. A warning that cannot be cleared without a paid upgrade looks
identical to one that is a five-second toggle, and a reader who trusts
the list will chase it repeatedly and each time conclude they missed a
setting.

So when an advisory resists being cleared:

- Check the subscription tier or licence before assuming it was missed.
  Read it from the API rather than from the dashboard's appearance —
  some consoles render a paid control as available and only refuse on
  save.
- Attempt the change and **keep the refusal message as evidence**. It is
  the difference between "not done" and "cannot be done here".
- Record the reason where the next reader will look, and say explicitly
  that the advisory will keep firing. Otherwise the same hour is spent
  again at the next audit.
- State the residual risk in one sentence, and whether an upgrade is
  warranted for that risk alone at this size. That is the decision the
  owner actually faces, and it is theirs, not yours.

#### When every user shares one database role

In backend-as-a-service architectures, every signed-in user typically
arrives as the *same* database role, with the application's own roles
(admin, editor, viewer) held in a table. Two consequences:

- **A grant cannot express per-role authorization.** Revoking SELECT to
  hide something from one application role hides it from all of them.
  The distinction has to live in a policy or in the object itself, via a
  lookup of the caller's application role.
- **When you add such a restriction to a shared object, enumerate every
  caller first.** Background jobs, schedulers and serverless functions
  usually read the same objects under a service identity. If you do not
  admit that identity explicitly, they fail silently — and a report that
  stops arriving is noticed weeks later, if at all. Verify each caller
  class separately and state the row counts for all of them.

### 3.6 Repository vs production drift

Where live tooling exists, compare and classify **each** item as
`verified matching` / `drift found` / `cannot verify`:

schema · policies · RLS enabled state · functions · triggers · scheduled
jobs · deployed serverless code · runtime configuration · role grants.

Comparing **deployed function source against repository source** is
cheap and occasionally reveals that production is running something
nobody has in git.

### 3.7 Serverless / edge functions

For each deployed function, check: authentication, JWT/token
verification, authorization, privileged credential usage, whether it can
be invoked publicly, replay protection, rate limiting, deduplication,
idempotency, input validation, origin assumptions, webhook signature
verification, and whether invoking it **costs money or sends something**.

> **Do not trust a source comment that claims the function is protected.**
> Read the *deployed* configuration. A comment saying "deployed with auth
> disabled, but it's harmless" is a finding, not a reassurance — and the
> claim that it is harmless is usually out of date.

**Any function holding a privileged/service-role credential is a
high-risk trust boundary**, regardless of what it currently does, because
the credential's blast radius is the whole database.

### 3.8 Scheduled jobs and background triggers

Database cron, platform cron, CI schedules, external schedulers.

Check: do they call a public endpoint? How do they authenticate? **Is a
broad privileged credential embedded in stored command text** (readable
by anyone with database or repository access)? Are repeated runs safe? Can
a failure cause duplicate work? Can the job trigger billable or
externally visible actions repeatedly?

> **Prefer a purpose-scoped secret over a broad credential.** A secret
> whose only power is "trigger this one job" is vastly better than an
> admin key in a cron command. Generate it server-side so it is never
> typed, printed or committed; store it in a secret store; have the
> caller present it and the receiver verify it **without ever returning
> the secret** (compare a digest, or compare inside the trusted system
> and return only a boolean).

### 3.9 Rate limiting and abuse

List **every entry point reachable without logging in**, and **every one
that costs money or time per call** — paid APIs, mail, SMS, generated
media, model inference, heavy compute, report generation, file
processing.

For each: is there a limit per IP / per user / per key? Where is it
enforced? What happens when exceeded? Include login, signup, password
reset, OTP issuance, and webhook receivers.

Distinguish application-side limits, provider/platform limits,
deduplication, idempotency and replay protection — they are different
controls and only some of them cap cost.

> **Defence in depth for cost:** authentication alone is not enough,
> because secrets leak. Add a control that caps damage *even if the
> caller is authenticated* — per-period deduplication, an idempotency
> key, or a hard quota. Ask: "if the trigger secret leaked today, what is
> the maximum bill?" If the answer is unbounded, the control is missing.

If nothing is limited, state concretely what an attacker could run up in
an hour, and where the limit belongs in this stack.

### 3.10 Data integrity

Inspect business-critical calculations and state transitions. Prefer
server/database derivation for: direction of a movement, balances,
totals, prices, ownership, timestamps, status, approval state, creator
identity, monetary and billing state.

Ask: **can a manipulated client corrupt accounting, inventory, audit,
billing, entitlement or workflow state?**

Good patterns to recognise and credit: generated/computed columns,
append-only ledgers with reversing entries, database-side triggers that
reject direct writes to derived values, constraints that make an invalid
state unrepresentable.

### 3.11 Audit trail integrity

Review audit logs and attribution columns: `created_by`, `updated_by`,
`deleted_by`, transaction author, timestamps.

> **The client must not be able to impersonate another user in the
> record of who did something.** An audit log an attacker can write as
> anyone is worse than no audit log, because it is trusted.

When attribution is broken on **one** table, check all of them. This is
almost always systemic — the same helper writes the same column
everywhere. Enumerate from the schema:

```sql
SELECT table_name, column_name, column_default
FROM information_schema.columns
WHERE column_name IN ('created_by','updated_by','user_id','deleted_by','owner_id')
ORDER BY table_name;
```

A `NULL` default plus no policy mentioning the column means it is
client-supplied and unchecked.

### 3.12 Multi-tenancy

Where applicable (`tenant_id`, `organization_id`, `workspace_id`,
`project_id`): verify a user cannot read or mutate another tenant's data
by changing an id in a request. Test **both** direct row access **and**
indirect paths through RPCs, functions, reports, exports and search.

A tenant filter applied only in application code is not isolation when
the client can reach the data store directly.

### 3.13 File and object storage

Bucket/container policies · public vs private · signed URL generation and
expiry · upload permissions · MIME and size restrictions · path traversal
· predictable or enumerable paths · overwrite and delete permissions ·
tenant isolation · metadata leakage · virus/type validation on user
uploads.

### 3.14 Injection and input handling

Prioritise what the stack can actually suffer: SQL/NoSQL injection,
command injection, XSS (stored and reflected), HTML injection, SSRF,
path traversal, unsafe redirects, template injection, unsafe
deserialization, prototype pollution, formula injection in exported
spreadsheets.

Pay attention to **dynamic SQL built by string concatenation** inside
database functions — it is easy to miss and runs with the function's
privileges.

### 3.15 Browser-side security

CORS configuration · cookie flags (`SameSite`, `HttpOnly`, `Secure`) ·
CSRF protection for cookie-authenticated state changes · CSP ·
clickjacking/frame options · what is kept in `localStorage` (tokens?) ·
postMessage origin checks.

### 3.16 Dependencies and supply chain

Outdated or known-vulnerable packages (where tooling allows), abandoned
packages, install/postinstall scripts, unnecessary privileged packages,
suspicious transitive dependencies, lockfile integrity.

> **Do not upgrade dependencies during an audit** unless explicitly
> approved. An unplanned major bump inside a security change set makes
> the change set impossible to review and impossible to revert cleanly.

### 3.17 Infrastructure and deployment

Platform configuration, CI/CD definitions, secret handling in pipelines,
preview/branch environments (do they point at production data?), branch
protection, deploy previews exposed publicly, container/base image
hygiene, backup and restore posture.

Clearly separate **repository evidence** from **dashboard-only
configuration**.

---

## Phase 4 — Live platform tooling

If platform MCP/CLI/API access is available, **use it**. Verify
production state yourself rather than asking the user to run queries you
could run.

When a setting is genuinely dashboard-only or otherwise unreachable, mark
it:

```
⚪ CANNOT VERIFY — MANUAL CHECK REQUIRED
Setting:   <exact name>
Where:     <exact navigation path>
Expected:  <recommended value>
Why:       <one line on what it protects>
```

**Do not block the audit on it.** Report the rest and list the manual
checks together at the end.

If your environment restricts outbound network access, say so plainly
rather than reporting a capability as absent. "Blocked by my sandbox's
egress proxy" and "the project does not have this" are very different
statements.

> **Better still: remove the dependency.** If a fix can make a
> dashboard-only setting *not* security-critical, that is superior to
> documenting the setting. Design the fix so the toggle being wrong is
> merely untidy rather than exploitable.

---

## Phase 5 — Severity and evidence

| Level | Meaning |
|---|---|
| 🔴 **Critical / High** | Directly exploitable: privilege, data, credential, money or control impact |
| 🟠 **Medium** | Meaningful integrity or security weakness; needs a precondition |
| 🟡 **Low** | Defence in depth, hardening, missing belt-and-braces |
| 🟢 **Fine** | Reviewed and found correctly protected — say so, it is information |
| ⚪ **Cannot verify** | Evidence unavailable; state exactly what you would need |

**Do not inflate severity.** An audit that marks everything critical is
ignored. Record the 🟢 items too: knowing what *is* enforced is half the
value, and it prevents the next person "fixing" something that was
deliberate.

Every finding carries: **file / function / migration / table / policy /
line reference**, plus live evidence where available. Never claim a
vulnerability from intuition alone. Where a claim depends on runtime
behaviour, **test it** if that is safe and practical, or label it
explicitly as unverified.

---

## Phase 6 — The report (read-only deliverable)

Structure:

1. **What I found** — architecture, in plain list form, "not present"
   where absent.
2. **Trust boundaries** and the decisive question (§Phase 1).
3. **Findings**, ordered by severity, each with: problem, location,
   why it matters, evidence, exploitability, proposed fix *in this
   stack*.
4. **One table**: item · status · evidence · what goes wrong if left ·
   fix.
5. **Ordering**: exploitable now / weak / fine / cannot verify.
6. **Manual checks** required, with exact paths.

Then **stop and request approval** unless remediation was pre-authorized.

---

## Phase 7 — Remediation

Fix in severity order, one item at a time, smallest secure change first.

Rules:

- **Where the project uses migrations, add a new one.** Never edit an
  already-applied migration. Where it does not, follow whatever
  change-tracking convention the project already has — do not introduce
  a migration system during a security fix.
- **Inspect live state immediately before changing it** — again, even if
  you looked an hour ago.
- **Do not alter unrelated business logic**, permissions, or UI behaviour
  beyond what the fix requires.
- **Do not weaken any existing permission** to make a fix simpler.
- **Preserve legitimate workflows.** If a fix would break a real user
  journey, redesign the fix.
- **Prefer a systemic fix for a systemic problem.** If the same flaw
  exists on twelve tables, fixing two named ones and leaving ten is worse
  than it looks — it creates the illusion of coverage. Enumerate the full
  surface first, then fix the class.
- **Add defence in depth where the impact justifies it**, especially for
  privilege and cost. Two independent controls, where one failing does
  not silently disable the other.
- **Avoid destructive changes.** Never delete data to make a fix easier.

### Force vs reject

For **attribution and identity**, prefer *forcing* the correct value
server-side (overwrite with the session identity) over *rejecting* a
mismatch:

- rejecting breaks every existing caller that sends the value;
- forcing leaves callers working and simply makes the value true;
- for a "who did this" field the right outcome is the correct name on the
  row, not an error.

For **privilege and entitlement**, prefer *rejecting* or *downgrading* —
never silently granting.

### Fail closed

Any guard you add must fail closed. A guard that passes when its input is
missing, when a lookup returns nothing, or when an error is caught is not
a guard.

Be especially suspicious of a guard based on a **heuristic** ("refuse if
this looks like production"). Test the heuristic against the real
environment: if it would have passed where it must have failed, replace
it with an explicit token/flag that must be deliberately supplied.

### When the fix reveals the check was never deciding

If a security check returns a **generic error** instead of its intended
denial — a 500 where a 401 belongs — the check is not deciding the
outcome; the error handler is. **Fix the root cause.** Do not wrap the
call in a try/catch that treats the error as a denial, and never as
success. "The auth check throws" is precisely the condition a later
change "fixes" by making it pass.

### Keep the UI honest

If a backend fix makes a UI control meaningless — a role selector that no
longer selects anything, a button whose action is now always refused —
**update the UI**. Remove the control rather than disabling it, and say
plainly what happens now. A control that implies a capability the user no
longer has is a defect you introduced.

Equally: removing a control is **not** a fix on its own. Verify the
underlying API/database permission too. Security must hold when the
attacker skips the UI entirely.

---

## Phase 8 — Testing

**Every remediation is tested against the original attack.** For each:

```
1. Original malicious action   (the exact request/statement)
2. Expected secure result
3. Actual result
4. PASS / FAIL
```

Plus **regression tests for legitimate workflows** — at minimum, one
normal action per role, and one calculation whose value you can predict
exactly (e.g. a known before/after balance).

### Safe testing method

Prefer **transaction-based tests that roll back**. In SQL, a pattern that
reports results while guaranteeing rollback:

```sql
DO $$
DECLARE r1 text; r2 text;
BEGIN
  -- ... perform the attack, capture outcomes into r1, r2 ...
  RAISE EXCEPTION 'RESULTS >> a=[%] b=[%] <<', r1, r2;   -- rolls everything back
END $$;
```

Wrap each individual attempt in its own `BEGIN … EXCEPTION … END` so one
rejection does not abort the whole suite, and capture `SQLSTATE` so you
can tell *how* it failed.

**After testing, verify production is unchanged.** Query for every
artefact you might have created — test users, rows, secrets, seeded
dedup entries, uploaded files — and confirm the count is zero.

**Side effects escape a rollback.** An outbound HTTP request, an email,
a webhook or a queue message issued from inside a transaction still
happens even though the transaction rolls back. Rollback protects your
*data*, not the outside world. So if a test cannot be rolled back,
design it so the *safe* path is exercised: pre-seed state so the
expensive branch is skipped, or test only the denial paths — then say
which branch you did not exercise and why.

That pre-seeding is itself test data: remove it afterwards and confirm
removal, or you will suppress the next legitimate run.

### Traps that produce false results

These cost real time. Check them before concluding a fix failed:

- **`INSERT … RETURNING` also applies the read policy.** A write can be
  perfectly legal while `RETURNING` fails because the caller may not
  *read* the table. That is not the insert being rejected. Re-test
  without `RETURNING` and read the row back as a privileged role.
- **Running a function as its owner changes `current_user` but not
  `session_user`.** Some platform internals (secret decryption, key
  management) behave differently depending on which connection role is
  in play. **A passing direct-SQL test does not guarantee a passing test
  through the application's real connection path.** Test through the
  real path.
- **Elevated-privilege functions bypass row rules**, so a test that
  exercises them proves nothing about the policies.
- **A column may not be assignable** — generated/computed columns cannot
  be written in a before-trigger. A "rebuild the whole row" approach will
  break on them; assign named fields instead.
- **An existing column may carry a constraint** that blocks the value you
  planned to reuse (e.g. namespacing a channel into a status column with
  a `CHECK` allow-list). Verify constraints before designing around a
  column.
- **A view may expose a column under a different name** than the base
  table (`id` vs `record_id`). Verify the actual column list before
  shipping a query that depends on it.
- **Ordering of checks**: a row rule may be evaluated before a table
  constraint, so an invalid test fixture can mask the result you wanted.
  Use valid data in security tests.
- **An error code can be ambiguous** — the same code may mean "policy
  denied" and "insufficient privilege". Read the error *message*, not
  just the code.
- **A revoke that does not touch DEFAULT privileges is temporary.** The
  objects you fixed stay fixed; the next one created re-inherits the
  grant you removed. Re-run the census after creating an object, not
  just after the revoke.
- **Testing a restriction only as the role you restricted proves half
  of it.** The other half is that everyone else still works. Enumerate
  every caller class — each application role, the service/automation
  identity, the anonymous role — and record a row count for each. A
  restriction that also silenced a scheduled job looks like a pass from
  the attacker's side.

> **Do not record a test as passed until you understand why it produced
> that result.** If a test fails unexpectedly, first determine whether
> the vulnerability remains **or the test itself is flawed** — before
> changing production code. Changing the fix to satisfy a broken test is
> how a real hole gets re-opened.

---

## Phase 9 — Final verification and report

Re-check, live: RLS/policy state · policies per command · roles ·
triggers · functions and their execution grants · serverless function
config · scheduled jobs · secret exposure · authorization · attribution ·
drift · **test artefacts removed**.

Re-run the critical attack tests one final time, after all changes are
in, because fixes interact.

Run any platform security advisor/linter and compare to the pre-audit
baseline: the goal is **no new findings**, and a documented reason for
each remaining one.

### Final report contents

Architecture summary · trust boundaries · findings by severity ·
evidence · exploitability · fixes made · tests performed with results ·
regression results · live verification output · remaining risks ·
manual/dashboard checks · files and migrations changed · live objects
changed · commits created.

> **Never conclude "the application is secure."** State exactly what was
> verified, by what means, and what remains unknown. An audit is a
> snapshot taken with specific tools; say what the tools could not see.

---

## Phase 10 — Security history

Maintain `SECURITY_HISTORY.md` at the repository root. After each
approved remediation cycle, **append** (never erase) a dated record:

```markdown
## YYYY-MM-DD — <audit title>

**Scope:** repository + live / repository only
**Tooling:** what live access was available

### Findings
| # | Severity | Finding | Status |

### Remediation
- migrations added
- live objects changed (functions, triggers, policies, jobs, config)
- application files changed

### Tests
| Attack | Expected | Result |

### Regression
...

### Final verified state
<the verification query and its output>

### Unresolved / accepted
- item, why accepted, who accepted it

### Commits
<hashes>
```

Also maintain a `SECURITY.md` describing the **current** model: what
enforces what, the verification query with its expected output, and the
attack tests to re-run after touching auth or policies. History is the
log; `SECURITY.md` is the current truth.

One combined document is fine too, and often better for a small
project — keep the current-state sections at the top, edited in place,
and an append-only dated log of findings below them. What matters is
that the log is never rewritten: each finding keeps the date, the fix,
and the evidence, so a later reader can see what was once wrong and why
the fix is shaped the way it is. Extend the verification query every
time a finding teaches you a new check, and record the new expected
output alongside the date it was measured.

---

## Phase 11 — Re-audits

A previous audit is historical evidence, not proof of present state.
Every re-audit: inspect the repository again, inspect live state again,
compare against the previous results, identify **regressions**, identify
**new attack surface** added since, and verify each previously fixed
finding is still fixed — by re-running its attack test, not by reading
the old report.

---

## Appendix A — Adapting to non-Postgres stacks

| If the stack has… | The equivalent audit is… |
|---|---|
| An API layer instead of direct DB access | Every handler is a boundary; check the auth middleware covers *all* routes, and list any that bypass it |
| An ORM with app-side scoping | Confirm **every** query is scoped to the session identity; one unscoped query is the hole |
| A NoSQL/document store with rules | Same as RLS: verify rules are deployed, check per-operation, hunt for `allow read, write: if true` |
| No database rules at all | State it: all safety depends on application code, then verify every query path individually |
| Server-rendered framework | Check server actions/handlers, not just routes; verify they re-check identity rather than trusting a form field |
| Third-party auth only | Verify token validation (signature, issuer, audience, expiry) happens server-side on every request |

---

## Appendix B — Pre-delivery checklist

- [ ] Architecture proven from the repo, not assumed
- [ ] Trust boundaries drawn; the "direct DB access?" question answered
- [ ] Every credential classified; client exposure proven by build test
- [ ] Every client-controlled security value traced to its enforcement
- [ ] Every writer of a privileged column enumerated
- [ ] Live state verified where tooling allowed; drift classified
- [ ] Deployed serverless config read, not inferred from comments
- [ ] Cost-triggering and unauthenticated endpoints listed
- [ ] Severity honest; 🟢 items recorded
- [ ] Every finding cites evidence
- [ ] Read-only respected until approval
- [ ] Each fix tested with the original attack; regressions tested
- [ ] Every test result understood, not just observed
- [ ] Read access enumerated **as the untrusted role**, object by
      object — not inferred from the policy list
- [ ] DEFAULT privileges checked, and re-checked by creating an object
- [ ] Every caller class row-counted after each restriction (each app
      role, the service identity, the anonymous role)
- [ ] Production confirmed unchanged after tests
- [ ] Manual/dashboard checks listed with exact paths
- [ ] `SECURITY.md` and `SECURITY_HISTORY.md` updated
- [ ] No secret printed anywhere in the report or commits
