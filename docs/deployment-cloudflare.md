# Cloudflare Pages deployment — CNG Station Management

**Status: DEPLOYED AND LIVE-VERIFIED.** The isolated project serves
`https://cng-station-management.pages.dev`. On 20 September 2026, PR #3 merged the verified
remediation to `main` at `75c1111`; Cloudflare deployed it with the production environment.

---

## 1. Isolation boundary

| Project | Domain | Repository | Relationship to this project |
| --- | --- | --- | --- |
| `cng-station-management` | `cng-station-management.pages.dev` | `theknight87/CNG-Station-Management` | **THIS PROJECT.** |
| `cargas-coding-system` | `coding-system-new.pages.dev` | `theknight87/coding-system-new` | **NONE.** Separate application. Do not modify, redeploy, inspect, copy from, or attach anything to it. |

CNG Station Management uses a **completely separate** Pages project. Nothing is reused from the
Coding System: not environment variables, not secrets, not build settings, not domains, not VAPID
keys. This is the isolation rule in CLAUDE.md §2, and it is not negotiable for convenience.

## 2. Deployment path

The Pages project uses GitHub integration. A pull-request branch receives a preview deployment;
merging to `main` triggers production. This was observed directly during PRs #2 and #3. Do not use
a manual Direct Upload as a second release path unless the Git integration is deliberately retired.

## 3. Settings — read from the repository, not assumed

A clean production build was run to confirm them (`rm -rf dist && npm run build` → **exit 0**).

| Field in the Cloudflare form | Value |
| --- | --- |
| Project name | `cng-station-management` |
| Repository | `theknight87/CNG-Station-Management` |
| Production branch | `main` |
| Framework preset | **None** (or "Vite" — it only prefills the two fields below) |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Root directory | *(leave empty — repository root)* |

Two things that are easy to get wrong:

- **`npm run build` is `tsc -b && vite build`.** The typecheck is deliberately part of the build.
  Do not shorten it to `vite build` to make a red build go green — that would ship code the
  repository's own gate rejects.
- **Node version.** Vite 8 requires Node `^20.19 || >=22.12`. The repository pins nothing, so pin
  it at Cloudflare: add a build-time environment variable `NODE_VERSION = 22`. Without it the
  build may run on an older default Node and fail confusingly.

## 4. SPA routing is already solved in the repository

`public/_redirects` contains:

```
/*    /index.html   200
```

Vite copies it into `dist/`, which the build output confirms. Cloudflare Pages reads
`dist/_redirects` automatically, so deep links such as `/alerts` and `/regions/:id` resolve to the
SPA rather than 404.

**Do not add a Cloudflare-side redirect or rewrite rule.** A second, dashboard-managed rule would
duplicate a repository-managed one, and the two would drift.

## 4A. Browser security and cache policy

`public/_headers` is the repository-owned Cloudflare Pages response policy. Vite copies it to
`dist/_headers` during the production build. It currently provides:

- immutable one-year browser caching for fingerprinted `/assets/*` files;
- revalidation/no-store behavior for HTML and `sw.js`;
- clickjacking, MIME-sniffing, referrer, feature, opener, and transport controls; and
- a Content Security Policy covering only the Clerk, Supabase, Cloudflare challenge, and local
  origins required by the application.

The policy is live-verified on the public site. The root sends the CSP and supporting browser
headers; the deployed hashed JavaScript sends `public, max-age=31536000, immutable`; and `sw.js`
sends `no-store, must-revalidate, no-cache`. Clerk sign-in renders without a browser error. Full
authenticated Supabase and Web Push verification still needs approved credentials. Tighten Clerk
wildcards to the production Frontend API origins after the production instance and custom domain
are final.

## 5. Environment variables

Pages → the new project → **Settings → Environment variables → Production** (and Preview, if you
use preview deployments — a preview build without these will render an unconfigured app).

| Variable | Value |
| --- | --- |
| `VITE_CLERK_PUBLISHABLE_KEY` | from the Clerk application **`CNG Station Management`** — the publishable key, `pk_...` |
| `VITE_SUPABASE_URL` | `https://ypkggegquetvpsflkaxg.supabase.co` |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | from Supabase project `cng-station-management` → API keys |
| `VITE_VAPID_PUBLIC_KEY` | **the PUBLIC half** of this project's dedicated VAPID pair |
| `NODE_VERSION` | `22` |

Paste each value straight into the Cloudflare form. **Do not paste any of them into chat, into a
file, or into this repository.**

### What must never be added here

`VAPID_PRIVATE_KEY` · `RESEND_API_KEY` · `CNG_ALERT_INVOKE_SECRET` ·
`CNG_ALERT_TEST_RECIPIENT` · the Clerk **secret** key · the Clerk webhook signing secret · the
Supabase **service-role** key.

Those are Supabase Edge Function secrets and stay server-side. Marking a Cloudflare variable
"encrypted" does not make it private: this is a static site, so whatever the build inlines is
readable in the shipped bundle by anyone who opens it.

> `VITE_VAPID_PUBLIC_KEY` is browser-visible **by design** — the browser needs it to create a push
> subscription. The private half never leaves Supabase.

## 6. Build timing, which is the part that bites

Vite inlines `VITE_*` values at **build** time, not run time. A deployment built before a variable
existed does not contain it, however correct the dashboard looks afterwards. **Every time you add
or change a `VITE_*` variable, redeploy.** Until then the app will report *"Push notifications are
not configured for this deployment"* — which is the code being honest, not a bug.

## 7. After the first deployment — verify, in this order

1. Open the generated `https://cng-station-management.pages.dev`.
2. **SPA routing:** open `/`, `/dashboard`, `/alerts` and `/regions` **directly in the address
   bar**, not by clicking through. A 404 means `_redirects` did not reach `dist/`.
3. **Clerk:** sign in. It must be the **CNG Station Management** Clerk application. A new account
   is created inactive with the least privilege and an administrator must activate it — that is
   CLAUDE.md §10 working, not a failure.
4. **Supabase target:** in DevTools → Network, confirm every API call goes to
   `ypkggegquetvpsflkaxg.supabase.co` and nothing else.
5. **No Coding System dependency:** no request to `coding-system-new.pages.dev` or any Coding
   System resource. The repository contains no reference to it.
6. **Web Push:** `/alerts` → **Enable notifications** → accept the browser prompt. The subscription
   is saved by `cng_save_push_subscription`, which derives the owning user from the session.
7. **Headers and caching:** verify the root has the browser security policy, hashed `/assets/*`
   responses are `public, max-age=31536000, immutable`, and `/sw.js` is not cached persistently.

Record each result. Until they pass, Cloudflare deployment is **not** LIVE VERIFIED.

## 8. Not in scope here

No custom domain, no DNS record, and no change to any existing Cloudflare setting. The
`*.pages.dev` URL is sufficient to verify the deployment, and a domain is a separate decision.
