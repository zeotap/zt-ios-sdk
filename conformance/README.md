> **Generated, read-only.** These vectors are generated from the Zeotap browser
> SDK (the reference implementation) in Zeotap's SDK monorepo and copied here on
> every release; every Zeotap mobile SDK runs the same files. Paths below such
> as `sdk/js/...` and `sdk/conformance/...` refer to that monorepo. In this
> repository the vectors are at `Tests/ZeotapSDKTests/Resources/vectors/` and run as part of
> `swift test`. The divergence tables below are the complete list of deliberate
> differences between platforms.

# SDK conformance suite

The browser SDK (`sdk/js`) is the **oracle** for every Zeotap SDK's business logic. The
mobile SDKs (`sdk/android`, `sdk/ios`, `sdk/react-native`) are separate native implementations,
and this directory is what keeps them byte-compatible with the web: a set of **golden vectors
generated from the real `sdk/js` modules**, executed by every platform's own test suite.

```
sdk/conformance/
  MANIFEST.json          # sha256 per vector file + the web-source hash each family derives from
  schema/                # JSON Schema (draft 2020-12) for the envelope and each family
  vectors/*.vectors.json # the golden vectors — GENERATED, never hand-edited
  runners/README.md      # how each platform consumes the vectors
```

## The rule

1. **Never edit a vector by hand.** Change the web SDK (and its unit test), then regenerate.
2. `sdk/js`: `npm run gen:conformance` regenerates everything; `npm run check:conformance`
   regenerates, validates against the schemas and fails if `git diff` shows the committed vectors are
   stale. The `sdk-conformance` step of `cloudbuild-sdk-pr.yaml` runs the check on every PR that
   touches `sdk/**`, so a web-SDK change that moves the contract cannot merge without the vectors —
   and therefore without every platform's runner being re-run against the new truth.
3. A platform that cannot satisfy a vector has a bug, or the vector needs a `platforms` tag (see
   below) plus a note explaining the deliberate divergence. Both are reviewed changes.

## Envelope

Every file is:

```json
{
  "family": "hash",
  "version": 1,
  "sources": ["sdk/js/src/hash.ts", "sdk/js/src/hash.test.ts"],
  "sourceHash": "sha256:…",              // over the sources' contents
  "generatedBy": "sdk/js/scripts/conformance/hash.gen.ts",
  "notes": ["…contract prose the runner author needs…"],
  "cases": [
    { "id": "unique-within-family", "description": "…", "platforms": ["js"], "input": {}, "expected": {}, "tags": [] }
  ]
}
```

`platforms` (optional) restricts a case to the platforms that must satisfy it — e.g. `page()` payload
cases are `["js"]` because mobile has `screen()` only. Absent = all of `js`, `android`, `ios`,
`react-native`.

Placeholders inside `expected`: `$LIBRARY_NAME` / `$LIBRARY_VERSION` stand for the platform's own
`context.library` identity (`@zeotap/browser-sdk`, `@zeotap/android-sdk`, `@zeotap/ios-sdk`).

## Families

| File | Derived from | What a runner must do |
|---|---|---|
| `hash` | `hash.ts` `digestHex` / `hashCaseVariants` / `hashDigits` | SHA-256/SHA-1 hex lowercase over UTF-8; trim → lower/upper → hash; no Unicode normalisation |
| `cellno` | `hash.ts` `cleanCellno` | legacy `"<cc> <number>"` split (`^\+?\d{1,4}$` prefix), `[^\d]` strip, explicit cc precedence |
| `identities` | `user-identities.ts` | scripted `set/unset/clear` → in-memory map + exact persisted JSON under `{ns}_user_identities` |
| `consent-signals` | `consent-state.ts` `resolveSignals` + `cookie-sync.ts` `consentPermitsSync` | ConsentInput → `{track, identify, cookieSync}` |
| `consent-resolution` | `consent.ts` | source precedence default < storage < cmp < manual, re-resolution, `clear()` |
| `tcf` | `tcf.ts` `translateTCData` | TCData maps **and** the IAB TCF-for-Apps `IABTCF_*` bit strings → signals (GVL 1469/301) |
| `consent-persistence` | `consent-persistence.ts` | exact `{ns}_consent` / `{ns}_consent_tcf` records, expiry, corruption, skip-unchanged |
| `payload` | `client.ts` `buildPayload` / `buildContext` / `enqueue` | exact ordered payload per method with pinned uuid/clock; identities + consent attached at enqueue |
| `transport` | `transport.ts` | retry classification (5xx/429/network retry; other 4xx throw), delays 500/1000/2000, header set, `{batch, sentAt}` envelope |
| `gating` | `client.ts` consent gate | scripted scenarios → what reached the transport, callback errors, consent snapshot, persisted keys |
| `storage-keys` | `identity.ts`, `user-identities.ts`, `consent-persistence.ts` | key names per namespace |

Deliberately **not** vectorised (browser-only, or a documented mobile divergence): cookie-sync and the
first-party-cookie protocol, `__tcfapi` polling timing, `sendBeacon`, the insecure-context PII drop
(native crypto is always available), the in-memory queue (mobile queues are durable), and what happens
*after* retries are exhausted (web drops, mobile releases for a later flush).

### Context the mobile SDKs do not reproduce

The vectors are generated from the **real** browser SDK, so they carry every context block it sends
— including ones no mobile SDK has. The payload runners therefore strip a set of keys from **both**
sides before comparing, for symmetric reasons: each mobile SDK sends `app`/`device`/`os`/`network`/
`screen`/`locale`/`timezone`/`userAgent`, which the web SDK never does, and the web SDK sends the
following, which they do not. What is left is the cross-platform contract, which is the only thing
this suite is for.

| Web-only context key | Status | Why |
|---|---|---|
| `page` | permanent | There is no page on a device. The `page` *cases* are additionally tagged `platforms: ["js"]`, and `screen()` is the mobile primitive. |
| `session` | **deferred feature, not a divergence** | The web SDK stamps `context.session` on every payload. The mobile SDKs have no sessions yet — when they do, delete the entry and the vectors become the contract again. |

`session` is worth a note because of how it arrived: it landed on `main` from the sessions
workstream while the mobile branch was open, and `git` merged it without a conflict — the vectors
and the mobile runners are different files. `make sdk-conformance-check` is what caught it,
regenerating the vectors from the merged web SDK and finding 373 changed lines in
`payload.vectors.json`. That is the check earning its keep: a stale vector set would have gone on
asserting a contract the web SDK no longer had.

The key sets live in `ClientHarness.kt` (`WEB_ONLY_CONTEXT_KEYS`) and `CoreHarness.swift`
(`webOnlyContextKeys`).

### Vectors a platform deliberately does NOT satisfy

One rule, three cases, all in `consent-signals`: **the React Native bridge rejects an empty consent
input instead of granting on it.**

| Vector | Browser SDK | `@zeotap/react-native-sdk` |
|---|---|---|
| `parsed/empty` — `{}` | `track: true, identify: true` | rejects `ZeotapConfigError` |
| `tcf/empty` — `{tcfString: ""}` | `track: true, identify: true` | rejects |
| `usp/empty` — `{usPrivacy: ""}` | `track: true, identify: true` | rejects |

The browser SDK grants because an absent category *is* a grant, which is right for a page whose
`setConsent` is usually driven by a CMP that has already decided. From an app, `setConsent({})` far
more often means "the CMP returned nothing" or "the user consented to nothing", and silently
resolving that to full consent is an invisible privacy failure rather than a recoverable bug. The
rejection names what to pass instead (`{analytics: false}` to deny).

The two native SDKs follow the browser SDK; only the RN bridge's JS layer and its Android module
reject. `sdk/react-native/src/__tests__/conformance.test.ts` pins each case as a deviation, so
"fixing" the mapper to match the vectors fails a test that explains why it should not be fixed.

Note also that `consent-signals` carries two cases whose `input` is **not** a `ConsentInput` at all —
`uniform/granted` and `uniform/denied` pin `uniformSignals(granted)`, an internal helper. The
generator says so in its own notes; a runner that fed them to a public `setConsent` would be
asserting a shape no caller can send.

## Adding or changing a vector

1. Change `sdk/js/src/<module>.ts` and its `*.test.ts`.
2. Add/adjust the case in `sdk/js/scripts/conformance/<family>.gen.ts`. Generators assert their own
   output against the live implementation (and, for hashes, against `node:crypto`) before writing.
3. `cd sdk/js && npm run gen:conformance` → commit `sdk/conformance/**` with the SDK change.
4. Run the platform runners (`make sdk-android-test`, `make sdk-ios-test`, `make sdk-rn-test`) and fix
   what the new truth breaks.

## Generator internals

The generators are vitest files (`sdk/js/vitest.conformance.config.ts`, serial). They pin the web SDK's
non-deterministic seams exactly as `client.test.ts` does: `vi.mock("../../src/utils")` for `uuid()` /
`isoNow()`, `vi.useFakeTimers` for `Date.now()`, a memory `localStorage`, a captured `Transport` and a
stubbed `CookieSync`. `setImmediate` stays real so SubtleCrypto digests complete between scripted
steps. `manifest.mjs` writes `MANIFEST.json`; `validate-schemas.mjs` (ajv) checks every file against
`schema/` and the manifest.
