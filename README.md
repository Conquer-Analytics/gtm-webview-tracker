# In-App Browser Detector — GTM Custom Variable Template

A Google Tag Manager **custom variable template** that detects in-app (webview)
browsers — Facebook, Instagram, TikTok, and friends — from the User-Agent, so
you can see how much of your traffic is funneled through these embedded browsers
and how that skews your analytics vs. ad-platform numbers.

It exists because GA4 can tell you a hit *is* an in-app browser (it reports
`Safari (in-app)` / `Android Webview`), but it throws away the vendor tokens, so
it can't tell you **which** app. This template keeps that signal.

## What it returns

A GTM variable returns a single value, so the template has an **output
selector**. Create one variable instance per field you want:

| Output | Type | Example | Use as |
|--------|------|---------|--------|
| `is_inapp` | boolean | `true` | custom dimension `webview` |
| `app_name` | string | `facebook`, `instagram`, `tiktok` (generic bucket like `android_webview` if unidentified) | custom dimension `traffic_env` (prefix to taste, e.g. `inapp_facebook`) |
| `token` | string | `FBIOS`, `FB4A`, `BytedanceWebview`, `wv` | custom dimension `traffic_token` — granular signal, good for spotting unknown variants |
| `ua_tail` | string | `[FBAN/FBIOS;…]` (in-app), or the last 100 chars of the UA (everything else) | event param `ua_tail` — a ≤100-char, GA4-safe slice of the UA. Send it as a plain event parameter for the BigQuery export; *not* a custom dimension (truncation + high-cardinality — [see below](#using-with-bigquery-recommended)). GA4 doesn't collect the UA otherwise |
| `all` | object | `{raw_ua, ua_tail, is_inapp, app_name, token}` | advanced: feed another Custom JS variable (this is the only output carrying the **full, untruncated** UA — route it to a non-GA4 sink if you need it) |

Not an in-app browser → `is_inapp` is `false` and `app_name` / `token` are
`undefined` (so GA4 simply omits those params).

## Install

1. GTM → **Templates** → **Variables** → **New** → ⋮ menu → **Import**, and pick
   [`template.tpl`](template.tpl). Save. (No permissions to grant — the template
   requests none.)
2. Create a **User-Agent** variable to feed it: **Variables** → **New** →
   **JavaScript Variable** (*not* Custom JavaScript) → Global Variable Name
   `navigator.userAgent`. Name it `User Agent`. GTM's sandboxed templates can't
   read `navigator` directly, so this is how the UA gets in.
3. **Variables** → **New** → choose **In-App Browser Detector**. Set the
   **User-Agent** field to `{{User Agent}}`, pick an output, and name it (e.g.
   `Webview - app_name`). Repeat per output you want — all instances reuse the
   same `{{User Agent}}` variable.

## Wire into GA4

1. In your **GA4 Configuration / Event** tag, add event parameters:
   `webview` → `{{Webview - is_inapp}}`, `traffic_env` → `{{Webview - app_name}}`,
   `traffic_token` → `{{Webview - token}}`, `ua_tail` → `{{Webview - ua_tail}}`.
2. GA4 Admin → **Custom definitions** → register `webview`, `traffic_env`, and
   `traffic_token` as **event-scoped custom dimensions** (they're low-cardinality
   and safe). Applies **going forward only**.

> **⚠ Send `ua_tail` as a plain event parameter — don't register it as a custom
> dimension.** Two separate limits make the full UA unusable, and `ua_tail` works
> around both:
>
> 1. **Ingestion truncation.** GA4 caps *every* text event-parameter value at 100
>    characters and keeps the **first** 100 — and a UA's first 100 chars are
>    boilerplate (`Mozilla/5.0 (…) AppleWebKit/537.36 (KHTML, like Gecko)…`), so
>    the vendor token at the *end* is gone before the value is ever stored. This
>    bites the normal **GA4 → BigQuery export too**: BQ receives the
>    already-truncated value, *not* the full UA. `ua_tail` sidesteps it by sending
>    the ≤100-char signal end instead of the boilerplate head.
> 2. **Cardinality.** The UA is still effectively unique per device + app +
>    version. Register it as a dimension and the GA4 UI caps the distinct values,
>    collapsing the rest into a single `(other)` bucket — so you lose exactly the
>    detail you captured. Leave `ua_tail` **unregistered**; it still rides the
>    BigQuery export, where cardinality is a non-issue.
>
> Do all UA analysis in BigQuery — see
> [Using with BigQuery](#using-with-bigquery-recommended). If you need the
> **full, untruncated** UA (lossless history, backfill), GA4 can't carry it at
> all — capture it in a server-side beacon instead (the `all` output exposes it
> client-side for that).

> **Consent caveat.** GTM tags fire after your CMP, so GA4 only ever sees the
> *post-consent* in-app population. The full in-app picture still only lives in
> your server-side beacon. This template enriches GA4; it doesn't close that gap.

## Coverage & confidence

The token list is cross-checked against [**inapp-spy**](https://github.com/shalanah/inapp-spy)
— the maintained, de-facto open-source reference (a TS refactor of
[detect-inapp](https://github.com/f2etw/detect-inapp); it powers
[inappdebugger.com](https://inappdebugger.com)). Entries fall into tiers:

- **High confidence — matches inapp-spy:** `facebook`, `messenger`, `instagram`,
  `threads` (codename *Barcelona*), `tiktok` (`musical_ly`/`Bytedance`),
  `snapchat`, `linkedin`, `wechat` (`MicroMessenger`), `line`, `twitter`,
  `googleapp` (`GSA`), `whatsapp` (`WAiOS`/`WA4A`).
- **Beyond the curated list — verify before trusting:** `pinterest`, `reddit`,
  `kakaotalk`, `telegram` (upstream detects Telegram *client-side*, not by UA),
  and TikTok's `Trill`/`aweme` aliases. Plausible and seen in the wild, but not
  in inapp-spy — treat as best-effort.

**Generic detection (catches everything else).** These set `is_inapp = true`
with a **generic `app_name` bucket** — the specific app is unknown. The
detection method is also recorded in `token`:

- **`android_webview`** (token `wv`) — any Android in-app browser, via the
  reliable Android System WebView flag.
- **`webview`** (token `WebView`) — any UA carrying the literal `WebView` token
  (inapp-spy's generic catch).
- **`ios_webview`** (token `no-safari-token`) — iOS WKWebView heuristic: an iOS
  WebKit UA missing the `Safari` token that real Mobile Safari always carries.
  **Imperfect** — an unknown iOS app that appends no vendor token is
  indistinguishable from Safari, so expect iOS false negatives on unknown apps.
  Known apps (FB/IG/etc.) are still caught by their tokens regardless.

### The discovery loop

The fields are layered by reliability: **`is_inapp`** is the dependable "is this
any in-app view" signal; **`app_name`** is best-effort — a specific app when
identified, otherwise a generic bucket; **`ua_tail`** is the escape hatch. So:

> `is_inapp = true` **AND** `app_name` is a generic bucket (`android_webview` /
> `webview` / `ios_webview`) → an in-app view we couldn't name. Pivot on
> `ua_tail` to find the new/missed token, add a row to the table, re-import.

That query is your maintenance feed — it surfaces exactly the UAs the table
doesn't cover yet.

**Why `ua_tail` is pre-trimmed.** Reading full UA strings is noisy — and GA4
can't keep them anyway (the 100-char ingestion cap above). So the `ua_tail`
output does the isolation **in GTM**: apps *append* their tokens after the
standard browser UA, so it keeps only the **tail** after the last standard
landmark — `Mobile/<build>` on iOS, `Safari/<version>` on Android. That residual
is exactly where unmapped tokens live (`[FBAN/…]`, `Instagram 333…`,
`BytedanceWebview/… musical_ly_…`). Browsers with no appended block (desktop,
regular mobile web) fall back to the last 100 chars of the UA, so the field is
still populated for non-in-app traffic. In BigQuery you then `GROUP BY ua_tail`
directly — the tail is already isolated, no extraction step needed.

> **Why trim to a landmark rather than parse the whole UA?** A *full* "remove all
> boilerplate" strip is **not** reliable — device models and version numbers
> inside the UA vary and aren't fixed boilerplate, and any over-eager rule risks
> deleting the novel token you're hunting. Anchoring on one known landmark and
> keeping the tail is the robust shortcut; enumerating every non-token component
> is not worth the effort. (This is also why the trim happens in GTM, not the
> warehouse: with the full UA truncated at ingestion, the warehouse never sees
> the tail unless we isolate it first.)

> **Why not just bundle inapp-spy?** It's a regex-based npm module; GTM's
> sandboxed JS has no `RegExp` and can't import packages. This template ports
> the same signal to substring matching. When in doubt about a token, check
> inapp-spy's `src/regexAppName.ts` as the upstream source of truth.

## Using with BigQuery (recommended)

Do the analysis in BigQuery, not the GA4 UI. The GA4 → BigQuery export keeps
**every** event-parameter value regardless of cardinality, so `ua_tail` — which
is useless as a GA4 dimension — is perfectly usable here, with full SQL (and real
`RegExp`) for parsing and the tail-scan discovery above. Remember the value is
already the ≤100-char tail, not the full UA: GA4 truncates at ingestion, *before*
the export, so the full string never reaches BQ on the GA4 path (capture it
server-side if you need it).

**Cardinality, restated:** `webview` / `traffic_env` / `traffic_token` are
low-cardinality and fine *both* as GA4 custom dimensions and in BQ. `ua_tail` is
high-cardinality: register it in GA4 and reports collapse to `(other)`; leave it
unregistered, let it flow to BQ, and it just works.

Event params arrive as key/value rows in `event_params`, so unnest them:

```sql
SELECT
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'traffic_env')   AS app_name,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'traffic_token') AS token,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'ua_tail')       AS ua_tail,
  -- booleans may land as int_value (1/0) or string_value ('true'/'false') depending
  -- on your tag config — check your export and pick the matching field.
  (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'webview')       AS is_inapp
FROM `your_project.analytics_XXXXXX.events_*`
```

**Discovery query** — in-app views we couldn't name, bucketed by UA tail so you
read residuals instead of full strings. `ua_tail` is already the isolated tail
(trimmed in GTM), so you just group on it — no `REGEXP_EXTRACT` needed:

```sql
WITH ua AS (
  SELECT
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'traffic_env') AS app_name,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'ua_tail')     AS ua_tail
  FROM `your_project.analytics_XXXXXX.events_*`
)
SELECT
  ua_tail,
  COUNT(*) AS hits
FROM ua
WHERE app_name IN ('android_webview', 'webview', 'ios_webview')   -- in-app but unnamed
GROUP BY ua_tail
ORDER BY hits DESC
```

Each high-volume `ua_tail` is a candidate for a new `APPS` row (see below). For a
fully warehouse-driven categorization — token → env via a version-controlled seed
CSV, dbt-style — see [Relationship to the warehouse approach](#relationship-to-the-warehouse-approach).

## Adding a newly-spotted app

Detection lives in one ordered table (`APPS`) in the sandboxed JS — first match
wins, so list specific markers before generic ones. To support a new app:

1. Add a row: `{ match: '<UA substring>', app: '<name>', token: '<token>' }`
   (or `extract: '<key>/'` to pull a value out of the UA, like Meta's codes).
2. Add a test scenario mirroring the real UA.
3. Re-import the updated `template.tpl` into GTM.

Run the bundled tests in the template editor (**Tests** tab → **Run all**)
before publishing.

## How it works (notes for maintainers)

- The User-Agent comes in through the `userAgent` template field
  (`data.userAgent`), **not** `copyFromWindow`. GTM's `access_globals` permission
  rejects any path whose first token is a predefined browser global, and
  `navigator` is one — so `navigator.userAgent` can't be granted. The supported
  route is a container-level **JavaScript Variable** (`navigator.userAgent`)
  passed into the field. This also means the template requests **zero**
  permissions.
- Matching is plain `indexOf` substring search: **sandboxed JS has no `RegExp`**.
- Meta tokens (`FBAN/`, `FB_IAB/`) are the most durable signal — because apps
  build their own full UA, these are **not** subject to Chrome's UA Client Hints
  reduction that's freezing the normal browser/OS portion.

## Relationship to the warehouse approach

For *backfillable, discover-unknown-apps* analysis on the **full** UA, the
cleaner split is to capture the complete User-Agent in your own **server-side
beacon** (not GA4) and do the token→env categorization in BigQuery/dbt with a
seed CSV. GA4 can't carry the full string on any path — it truncates every UA
param to 100 chars at ingestion, *before* the export — so the lossless UA has to
be collected off the GA4 path. The `all` output exposes the untruncated UA
client-side if you want to route it to such a sink. Use this template's
`app_name` / `token` outputs when you need the classification **live in the GA4
UI**, `ua_tail` when you want the discovery signal to survive into the GA4 → BQ
export, and a server-side model when you need full history and lossless
unknown-app discovery.