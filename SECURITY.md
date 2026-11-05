# SECURITY.md — Mine Input Security Whitepaper

**English** | [简体中文](SECURITY.zh-CN.md)

> Maintained by the W21 pre-release security audit (ledger in `macos/W21-REPORT.md`, every item
> with its commands and measured output).
> Baseline promise: **zero telemetry, zero third-party data reporting, and no data-exfiltration
> channel whatsoever** — your data goes only two places: your device and the Hub you deploy
> yourself.

---

## 1. The "No Telemetry" Promise

- This project contains **no** telemetry/analytics/crash-reporting/tracking SDK (audit evidence:
  `git grep -iE 'telemetry|analytics|sentry|crashlytics|firebase|appcenter|umeng|bugly'` yields
  0 hits in first-party code, see W21-REPORT §1.3).
- The runtime network egress is a **closed set**: loopback + the user's own Hub (endpoint list in
  §3). No first-party code makes any other network request.
- The only "passive" egress is the Sparkle update check inherited from upstream Squirrel
  (`SUFeedURL` points at rime.github.io) — this project's dev patch sets
  `SUEnableAutomaticChecks=false` (**automatic checks off**); it only goes online when the user
  manually clicks "Check for Updates".
- Model/dependency downloads happen only when the user **explicitly runs** the fetch scripts
  (one-off, reproducible) — they are not runtime behavior.

## 2. Threat Model

**Assets**: keystrokes/candidate picks, voice transcriptions, OCR/ASR summaries, habit counters,
hotwords, the JSONL memory store, Hub account credentials, TLS/signing keys.

**Trust boundaries**:
1. Local device (IME process ↔ local filesystem) — fully trusted;
2. Device ⇄ user Hub (TLS channel) — the Hub host is run by the user/friends;
3. Hub server (the host administrator can see the persisted data — see §6 known gaps);
4. Supply chain (third-party sources/binaries/models downloaded at build time).

**Explicitly out of scope** (stated plainly): an attacker after device root/compromise; active
snooping by the Hub host administrator (technically visible before at-rest encryption / E2E is
enabled, see §6); nation-state traffic analysis (self-signed CA setups do not resist traffic
fingerprinting).

**Protection goals**: data **never** flows to third-party servers; high-sensitivity capture
(C1 screen/audio, C2 voice summaries) requires item-by-item explicit consent, is off by default,
withdrawable at any time, with a one-click circuit breaker; TLS in transit; multi-user (friend
deployments) mutually invisible.

## 3. Data Classification Table

| Data class | On-device storage | Leaves device? | Destination | Who can see it | Gating |
|---|---|---|---|---|---|
| Keystroke/candidate events (InteractionEvent) | SQLite (InteractionStore, 30-day rolling) | Optional after consent | User Hub `/v1/ingest` | Hub admin (plaintext at rest) | C0 consent + circuit breaker |
| L1 userdb / L2 counters / L3 hotwords / AI config | SQLite + RIME userdb | Optional after consent | User Hub `/v1/sync/push` | Same as above | Pairing + circuit breaker |
| OCR/ASR **summaries** (C1/C2; only length/summary recorded, never raw text or images) | SQLite | Carried with events only under C2 consent | User Hub | Same as above | C1/C2 item-by-item explicit consent, off by default |
| Voice audio (PTT) | **Never on disk** (16k mono in-memory ring buffer) | No | — | — | Holding the PTT key is consent; system TCC |
| Screen captures (C1) | **Never on disk** (original discarded right after Vision OCR) | Summaries optional only | User Hub | Same as above | C1 toggle off by default; password fields (secure input) auto-stop |
| JSONL memory store | `~/Library/Application Support/mine-input/memory/` | Optional via the sync surface | User Hub | Same as above | Consent tiers + circuit breaker + editable/deletable/clearable |
| suggest requests (before_cursor etc.) | Not stored (audit logs record field lengths only) | Per request | User Hub `/v1/suggest` | Same as above | Master AI toggle off by default |
| TLS certs/private keys, hub-secret | `hub/tls/certs/`, `hub-data/` (0600, **not committed**) | No | — | Host administrator | Blocked by .gitignore |

**The total set of off-device data** = every row above marked "Leaves device = optional/per
request" → all of it goes only to the **user-configured Hub base_url**. Nothing else leaves the
device.

## 4. Network Egress Inventory (closed set)

### A. User-initiated downloads (build/model fetch, explicit script triggers)

| Endpoint | Purpose | Integrity check |
|---|---|---|
| github.com/rime/librime, github.com/rime/squirrel | Source clones (build/build-*.sh) | depth-1 clone, **commit not pinned** (gap) |
| raw.githubusercontent.com (rime schema deps) | schema dependencies | commit SHA pinned in URL ✅ |
| raw.githubusercontent.com/llvm/llvm-project | libcxx filesystem patch | pinned to tag llvmorg-9.0.0 |
| github.com/k2-fsa/sherpa-onnx/releases | Android AAR + voice models | SHA256-pinned ✅ (fetch-deps.sh / ModelManager.kt verify while downloading) |
| maven.aliyun.com | commons-compress/commons-io | SHA256-pinned ✅ |
| mirrors.huaweicloud.com | Android NDK | SHA256 **recorded** only (TOFU, gap) |
| archives.boost.io | Boost sources | No verification (TOFU, gap) |
| github.com/osfans/trime/releases | Trime APK (extracts the JNI .so) | SHA256 **recorded** only (TOFU, gap) |
| www.modelscope.cn → cdn-lfs-cn-1.modelscope.cn | Qwen GGUF models | SHA256 individually re-verified ✅ |
| github.com/ggml-org/llama.cpp/releases | Prebuilt llama.cpp (manual download hint) | No forced verification (gap) |

### B. Loopback (runtime, never leaves the machine)

`127.0.0.1:8088` (Hub HTTP fallback, loopback-only by default), `localhost:8443` (Hub HTTPS),
compose-internal `hub:8080`/`llama:8091`, host `host.docker.internal:8092`, emulator
`10.0.2.2:8088`.

### C. User-owned Hub (the only runtime data-egress surface)

base_url is user-configured (default `https://localhost:8443`, TLS on by default); friend
deployments = `https://<朋友主机>:8443`. Data content: see §3.

### D. Upstream inheritance (macOS Squirrel)

`https://rime.github.io/release/squirrel/appcast.xml` (Sparkle update feed) — automatic checks
are off, manual trigger only.

## 5. Permissions & Sensitive Capabilities (minimization audit)

**Android** (`android/app/src/main/AndroidManifest.xml`, per-item justification in W21-REPORT §4):
- `INTERNET`: user Hub sync + model downloads, justified; runtime egress is the user Hub only.
- `RECORD_AUDIO`: PTT voice input, justified; long-press-triggered, in-memory buffer never on
  disk, runtime permission (Android 13+).
- No storage/location/contacts/camera permissions; `allowBackup=false` ✅.
- `usesCleartextTraffic=true`: keeps the LAN plaintext-Hub mode (stated in W11) — **known gap**;
  before remote deployment it should be replaced by a restrictive network security config.
- `DebugReceiver` (debug broadcast): gated by `FLAG_DEBUGGABLE` (`DebugReceiver.kt:29`); a release
  build returns immediately and the hooks are inert.
- Settings/Section/Consent Activity `exported=true` (e2e depends on `am start`) — low-risk
  residue; recommended to tighten for release.

**macOS**:
- Microphone: for PTT, holding the key is consent + system TCC; C1 audio additionally needs the
  `c1Audio` sub-toggle + the C1 master toggle (off by default).
- Screen: `W12ScreenCapture` sits behind the C1 master toggle (off by default) + `c1Screen` +
  auto-stop in password fields + blacklist + instant circuit-breaker stop.
- Capture triggers only while typing (2s debounce), and stores only **summaries**
  (length/fingerprint), never raw text or images.

## 6. Hub Security Surface (`hub/`)

**In place**:
- **TLS on by default**: smoke/SDK default to `https://localhost:8443` + self-signed CA
  verification (rejection tested with negative cases); plaintext HTTP remains only as a loopback
  fallback; TLSv1.2/1.3, certificate pinned to RSA-2048 (EC has an interop bug, W17-REPORT §5).
- **Token auth**: HMAC-SHA256 signatures (`hub-secret` 32B random, 0600 on the volume, not
  committed), 7-day TTL, all `/v1/*` force authentication via the `current_user` dependency;
  passwords via PBKDF2-SHA256 (200k iterations + random salt).
- **Multi-user isolation**: all SQL partitioned by `user_id` (W4 dual-user mutual-invisibility
  test); each user has an independent `key_partition` (reserved for E2E).
- Backups remind you to keep `hub-secret` at 0600; audit logs record field lengths only, never
  content.

**Known gaps (stated honestly)**:
1. **At-rest encryption is a placeholder**: hub.db is plaintext on the volume, same for backups —
   technically readable by the host administrator;
2. **E2E zero-knowledge not enabled** (key_partition issued, encryption unimplemented);
3. **No rate limiting / account lockout**: register/token can be brute-forced (LAN trust-model
   assumption); the minimum password length is only 4 characters;
4. Tokens cannot be revoked (valid until TTL); a leaked hub-secret = forgeable tokens for any user;
5. The self-signed CA must be distributed out-of-band as `ca.crt`; no ACME/automatic rotation
   (certificates expire after 825 days and must be re-signed manually);
6. The Android client still allows plaintext HTTP (see §5).

## 7. Supply Chain & Release Integrity

- The SHA256 pinning status of every download script is in §4A (pinned ✅ / TOFU gaps labeled).
- How third-party code (Trime GPLv3 JNI, sherpa-onnx, librime/squirrel) is reused: see
  `THIRD_PARTY.md` (maintained by the W22 lane).
- **Git history residue**: historical commits contain developer personal paths/hostnames/author
  emails (14 commits, W21-REPORT §2.4); before publishing the repository the history must be
  scrubbed with `git filter-repo` (this repo's HEAD is already sanitized).

## 8. Vulnerability Reporting

Please report security issues via **GitHub Issues** (a private-repository issue or contacting the
maintainer also works); please do not publicly disclose exploit details for unpatched
high-severity vulnerabilities. Response commitment: acknowledgment within 72 hours.

## 9. Known Limitations (summary)

See the §6 gaps + the §7 history residue + §5 `usesCleartextTraffic`; other acceptance-type
limitations (e.g., launchd not verified with a real machine restart) are in each lane REPORT's
"known limitations" section. This file and the `macos/W21-REPORT.md` ledger are updated with
every security-related change.
