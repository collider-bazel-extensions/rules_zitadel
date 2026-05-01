# rules_zitadel — Design Document

## Goals

`rules_zitadel` provides hermetic [Zitadel](https://zitadel.com) instances
for Bazel integration tests via `rules_itest`. Driven by four constraints:

1. **No CDN downloads required in CI.** Air-gapped builds work by pointing
   at a host-installed `zitadel` binary; the downloaded path is the
   optimization, not the requirement.
2. **`rules_itest` first.** A fresh Zitadel takes ≈10 s to bootstrap (DB
   schema + IAM + admin user). Per-test isolation isn't viable. All usage
   goes through `rules_itest` for shared-instance, multi-service tests.
3. **Zero test-code changes.** Tests receive a small, stable set of
   `ZITADEL_*` environment variables and hit the instance over plain HTTP
   from any language.
4. **Consistent env-file contract.** The `$TEST_TMPDIR/<name>.env` readiness
   protocol established by `rules_pg` and `rules_kind` is preserved.

---

## Why this is different from other Zitadel-on-Bazel attempts

The naïve approach is to wrap `zitadel start-from-init` in a `sh_test`,
point it at a local Postgres, and call it done. That works for a one-off
but fails the things you actually want from a Bazel ruleset:

- It can't run in `bazel test //...` with `--jobs > 1` because Postgres
  and Zitadel ports are hardcoded.
- It requires the test to know its DB credentials, master key, and ports
  ahead of time — so it isn't actually hermetic.
- It can't compose with other services without hand-rolled coordination.
- Init/setup phase failures are invisible — you only see "the test
  timed out" with no signal about which sub-step blew up.

`rules_zitadel` solves these by:

- Modeling each Zitadel phase (init / setup / start) as a separate
  rules_itest target so failures attribute to the right phase.
- Pairing each Zitadel instance with a `pg_server` via Bazel deps, not a
  global config file.
- Using rules_itest's autoassigned-port mechanism for both PG and
  Zitadel.
- Generating an ephemeral master key per instance.
- Provisioning a service-account PAT during setup so tests can call
  Zitadel's APIs without an interactive login flow.

---

## Relationship to `rules_pg` and `rules_kind`

These three packages form a coherent tier of integration-test rules:

|                    | `rules_pg`     | `rules_zitadel`            | `rules_kind`              |
|--------------------|----------------|----------------------------|---------------------------|
| Backend            | Postgres       | Zitadel + Postgres         | kind (Docker)             |
| Startup time       | ~1–2 s         | ~10 s                      | ~30–90 s                  |
| Per-test isolation | yes (`pg_test`)| **no**                     | no                        |
| `rules_itest`      | optional       | required                   | required                  |
| Best for           | Schema/SQL tests | IAM/OIDC integration tests | End-to-end with real pods |

The "no per-test" decision is the single biggest design call here. It's
copied directly from `rules_kind`: at ~10 s of bootstrap, running a fresh
Zitadel per test makes the test loop unworkable.

---

## High-level architecture

```
MODULE.bazel / WORKSPACE
        │
        ▼
  extensions.bzl                              ← fetch or symlink Zitadel binary
        │
        ▼
  ZitadelBinaryInfo  (private/binary.bzl)     ← carries paths + version
        │
        ▼
  zitadel_config rule  (private/config.bzl)   ← layered YAML config
        │
        ▼
  zitadel_instance rule  (private/instance.bzl)  ← first-instance bootstrap
        │                                          (org name, admin user/pw,
        │                                          machine-user PAT spec)
        │
        ▼
  ┌─────────────────┬─────────────────┬─────────────────┐
  │                 │                 │                 │
  zitadel_init    zitadel_setup    zitadel_server   zitadel_health_check
  (binary)        (binary)         (binary)          (binary)
  one-shot        one-shot         long-running      HTTP /debug/healthz
  │                │                │                  │
  └────────────────┴──→ wrapped by rules_itest's itest_task / itest_service / health_check
```

The launcher.py entry point branches on phase (`init` / `setup` / `start`)
based on a manifest field. Each rule produces its own wrapper script that
selects the right phase and execs the launcher.

---

## Phase split — three rules, three rules_itest wrappers

Per your decision: each Zitadel phase is its own Bazel rule, wrapped by
the appropriate rules_itest construct.

| Phase | Bazel rule | rules_itest wrapper | What it does |
|-------|------------|---------------------|---------------|
| Init  | `zitadel_init`   | `itest_task`     | `zitadel init --config <effective.yaml>` — create DB schema |
| Setup | `zitadel_setup`  | `itest_task`     | `zitadel setup --config <effective.yaml>` — create IAM, admin user, machine user, PAT |
| Start | `zitadel_server` | `itest_service`  | `zitadel start --config <effective.yaml>` — long-running server |
| Health| `zitadel_health_check` | `itest_service.health_check` | HTTP probe of `/debug/healthz` |

Why split:
- Failures attribute to the phase that actually broke. `init` failing
  (DB connectivity wrong) vs `setup` failing (config invalid) vs
  `start` failing (port collision) become visible signals in
  rules_itest's logs.
- `bazel run` against the service_test can iterate on init/setup
  independently — ibazel reload reruns only the changed phase.
- Cleaner mental model. `init` and `setup` are tasks; `start` is a
  service. That's exactly the rules_itest distinction.

Cost:
- Three targets to wire instead of one. The `zitadel_with_pg` macro
  hides this for the common case.
- All three need a shared "effective config" file. Generated by a
  fourth implicit rule (`_zitadel_effective_config`) that all three
  depend on, so they read identical config.

---

## Database orchestration — choose one

You asked for more information on the DB orchestration model. Here's
each option with its actual code at the use site, so you can compare UX
directly.

### Option A — Vendored PG (rules_zitadel ships its own postgres)

`rules_zitadel` internally fetches and runs a Postgres binary. No
dependency on `rules_pg`.

```starlark
load("@rules_zitadel//:defs.bzl", "zitadel_with_pg")
load("@rules_itest//:defs.bzl", "service_test")

zitadel_with_pg(name = "auth")     # ships PG inside

service_test(
    name     = "oidc_test",
    test     = "//tests:oidc",
    services = [":auth"],
)
```

Pros: zero PG knowledge required. Single `bazel_dep`.
Cons: duplicates rules_pg work; users who already use rules_pg in the
same workspace get two PG implementations side by side; CockroachDB or
managed-PG users (RDS, Cloud SQL) have no path.

### Option B — Composable, PG-agnostic (recommended)

`zitadel_server` takes individual PG connection attributes as strings
that support `rules_itest`'s `$${...}` port substitution. No
`bazel_dep` on `rules_pg` — works with anything that exposes PG conn
details.

```starlark
load("@rules_pg//:defs.bzl", "pg_server", "pg_health_check")
load("@rules_zitadel//:defs.bzl", "zitadel_init", "zitadel_setup", "zitadel_server", "zitadel_health_check", "zitadel_instance")
load("@rules_itest//:defs.bzl", "itest_task", "itest_service", "itest_service_group", "service_test")

pg_server(name = "pg", schema = "//db:auth_schema")
pg_health_check(name = "pg_health", server = ":pg")
itest_service(
    name            = "pg_svc",
    exe             = ":pg",
    health_check    = ":pg_health",
    autoassign_port = True,
)

zitadel_instance(
    name           = "instance",
    org_name       = "test",
    admin_password = "Password1!",
    machine_user_with_pat = "test-bot",
)

zitadel_init(
    name        = "init_bin",
    instance    = ":instance",
    pg_host     = "127.0.0.1",
    pg_port     = "$${@@//:pg_svc:port}",
    pg_database = "zitadel",
)
itest_task(name = "init", exe = ":init_bin", deps = [":pg_svc"])

zitadel_setup(
    name        = "setup_bin",
    instance    = ":instance",
    pg_host     = "127.0.0.1",
    pg_port     = "$${@@//:pg_svc:port}",
    pg_database = "zitadel",
)
itest_task(name = "setup", exe = ":setup_bin", deps = [":init"])

zitadel_server(
    name        = "server_bin",
    instance    = ":instance",
    pg_host     = "127.0.0.1",
    pg_port     = "$${@@//:pg_svc:port}",
    pg_database = "zitadel",
)
zitadel_health_check(name = "z_health", server = ":server_bin")
itest_service(
    name                       = "z_svc",
    exe                        = ":server_bin",
    health_check               = ":z_health",
    deps                       = [":setup"],
    autoassign_port            = True,
    http_health_check_address  = "http://127.0.0.1:$${PORT}/debug/healthz",
    expected_start_duration    = "15s",
)

itest_service_group(name = "auth", services = [":z_svc"])

service_test(name = "oidc_test", test = "//tests:oidc", services = [":auth"])
```

…with a `zitadel_with_pg` macro that expands to the above:

```starlark
zitadel_with_pg(
    name        = "auth",
    schema      = "//db:auth_schema",
    org_name    = "test",
    admin_password = "Password1!",
    machine_user_with_pat = "test-bot",
)
```

Pros: maximum flexibility; works with rules_pg, RDS, CockroachDB, or
any PG. No bazel_dep on rules_pg in core. Aligns with rules_itest's
existing port-substitution mechanism.
Cons: more attributes to set on `zitadel_*` rules. Macro hides this
for the common case.

### Option C — Hidden PG (rules_zitadel internally creates a pg_server)

`rules_zitadel` `bazel_dep`s on `rules_pg`. `zitadel_server` always
creates its own internal `pg_server`. User can't substitute a different
PG.

```starlark
load("@rules_zitadel//:defs.bzl", "zitadel_server", "zitadel_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

zitadel_server(name = "z", schema = "//db:auth_schema")
zitadel_health_check(name = "z_health", server = ":z")
itest_service(name = "z_svc", exe = ":z", health_check = ":z_health")

service_test(name = "oidc_test", test = "//tests:oidc", services = [":z_svc"])
```

Pros: simplest user code; no PG concepts visible.
Cons: bazel_dep on rules_pg in core. Users can't choose CockroachDB or
a managed PG. If they already have a `pg_server` for unrelated reasons,
they pay for two.

### Recommendation

**Option B + the macro.** Same surface as C for the common case, full
flexibility for power users. Mirrors how rules_itest itself is
designed (no opinion on what services the user composes).

---

## Provider chain

```
ZitadelBinaryInfo         path to zitadel binary; declared major version
  │
  └─► ZitadelConfigInfo   ordered list of YAML config files
        │                 (defaults overlay first, user overlays last)
        │
        └─► ZitadelInstanceInfo   first-instance bootstrap fields:
                                  org_name, admin_username, admin_password,
                                  machine_user_with_pat (optional).
```

`zitadel_init`, `zitadel_setup`, and `zitadel_server` each accept a
`config` or `instance` label and pull the binary + config + instance
defaults transitively.

---

## Effective config generation

Each phase needs the same effective config (defaults + overlays + DB
conn + port + master key). To avoid duplicating work and to keep all
three phases' config bit-identical, an internal rule
`_zitadel_effective_config` runs once and emits a YAML file that all
three phases read.

Inputs to `_zitadel_effective_config`:
- The shipped default YAML (TLS off, ExternalSecure false, sane log
  level).
- User overlays from `config_files`.
- DB conn attrs (interpolated at launch time, not build time, since
  port comes from rules_itest).
- Master key path (interpolated at launch time).

The actual interpolation happens in the launcher, not at action time,
because `$${...}` substitutions are resolved by rules_itest's service
manager at runtime. The "effective config" rule emits a template; the
launcher fills in the holes after reading them from env.

---

## PAT provisioning (shipping in v1)

Per your decision: PAT is shipped in v1.

Mechanism: Zitadel's `setup` command supports declaring "Machines"
(service accounts) in the FirstInstance config. Each machine can have
a token written to a configurable path during setup.

Flow:
1. `zitadel_instance(machine_user_with_pat = "test-bot")` declares a
   machine user with that name.
2. The launcher's `setup` phase generates a token-output path under
   `$TEST_TMPDIR/<server-name>.pat` and patches the FirstInstance
   config to point at it.
3. After `zitadel setup` runs, the launcher reads the PAT from the
   file.
4. The `zitadel_server` phase reads the same PAT and includes it in
   the env file as `ZITADEL_PAT`.

If the FirstInstance-config approach proves too brittle across versions
(possible — Zitadel's config schema has churned), v1 fallback is a
small Go helper that calls Zitadel's gRPC management API after start.
This is hidden behind the same attribute (`machine_user_with_pat`), so
the user-facing surface doesn't change.

---

## Toolchain (`extensions.bzl`)

Single `zitadel` extension with two tag classes:

```starlark
zitadel = use_extension("@rules_zitadel//:extensions.bzl", "zitadel")

# Pin one or more versions; downloads sha256-checked tarballs.
zitadel.version(versions = ["v4.14.0"])
zitadel.version(versions = ["v3.4.9"])  # stack: workspace can have both

# Or use the host-installed binary.
zitadel.system()

use_repo(zitadel, "zitadel_v4_14_0_linux_amd64", ...)
```

Per-platform tarballs at `https://github.com/zitadel/zitadel/releases/download/<tag>/zitadel-<os>-<arch>.tar.gz`.
SHA256 is computed and pinned in `_ZITADEL_VERSIONS`. Placeholder
checksums are committed and must be replaced before
`zitadel.version()` is used in production (same convention as rules_pg).

### Test matrix

The CI matrix runs the integration test under each pinned version:

```yaml
matrix:
  zitadel_version: [v3.4.9, v4.14.0]
  platform: [ubuntu-latest]
```

Per-version test ensures Zitadel v3 → v4 schema migrations don't
silently break the rules' assumptions about init/setup CLI surface.
Each version is a registered toolchain in the workspace; the test
target runs against `--extra_toolchains=@zitadel_<ver>//:toolchain`.

---

## Hard problems specific to Zitadel

### 1. Bootstrap latency

`zitadel setup` takes ~10 s on a fresh DB. Mitigations:
- `zitadel_server` defaults to `expected_start_duration = "15s"` when
  wrapped via `itest_service`.
- Long-running instance for dev environments survives across `bazel
  run` iterations.

### 2. Master key generation

Zitadel encrypts secrets at rest with a 32-byte master key. The
launcher generates one per-instance, writes it to
`$TEST_TMPDIR/<name>.master_key`, and exposes it in the env file so
test code that needs to decrypt audit data can read it.

### 3. TLS

Zitadel defaults to TLS. Shipped default config sets
`TLS.Enabled = false` and `ExternalSecure = false`. Users override
via `config_files` for TLS-path tests.

### 4. Config-schema drift across Zitadel versions

Zitadel's YAML config has changed between v3 and v4 (and within v4
minor releases). The shipped defaults are version-aware: a different
default YAML per major version, selected by `ZitadelBinaryInfo.major`.
The test matrix is what catches drift in v1 → v2 of `rules_zitadel`
itself.

---

## Rule surface

| Rule | Purpose |
|------|---------|
| `zitadel_binary` | Internal — produced by repo rule. |
| `zitadel_config` | Layered YAML config bundle. |
| `zitadel_instance` | First-instance bootstrap spec. |
| `zitadel_init` | One-shot binary that runs `zitadel init`. |
| `zitadel_setup` | One-shot binary that runs `zitadel setup`. |
| `zitadel_server` | Long-running binary that runs `zitadel start`. |
| `zitadel_health_check` | Companion health-check binary. |
| `zitadel_with_pg` | Macro: instantiates pg_server + init + setup + server, wires deps, exposes everything as an `itest_service_group`. |

**Notably absent**: no `zitadel_test` macro. By design — see "no per-test
isolation."

---

## Phased implementation

1. **Skeleton.** `MODULE.bazel`, `extensions.bzl`, `zitadel.system()` repo
   rule, `ZitadelBinaryInfo`, smoke `bazel run` of the binary.
2. **`zitadel_init` + `zitadel_setup` + `zitadel_server`** standalone with
   shared effective-config rule. Manual verification against an external
   PG.
3. **rules_itest integration.** Wire init/setup/server as itest_task /
   itest_service. End-to-end `service_test` example.
4. **`zitadel_with_pg` macro.** Hides the wiring.
5. **PAT provisioning.** FirstInstance machine-user declaration; launcher
   reads token file and exports `ZITADEL_PAT`.
6. **Downloaded binaries + test matrix.** `zitadel.version()` extension,
   sha-pinned tarballs for v3.4.9 + v4.14.0 across linux x86_64, darwin
   arm64/x86_64. CI matrix verifies both versions.

---

## Resolved decisions (your answers)

1. **DB orchestration**: pending — see options A/B/C above with code.
2. **Init/setup phase**: split into separate rules wrapped by
   `itest_task`s.
3. **PAT provisioning**: ship in v1 via FirstInstance config + token
   file readback.
4. **Default versions**: v4.14.0 (latest stable v4) and v3.4.9 (latest
   v3) in the test matrix. Toolchain code to be written.
5. **Platforms**: linux x86_64, darwin arm64/x86_64.
