# rules_zitadel

Hermetic [Zitadel](https://zitadel.com/) install for Bazel test
compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).
Three install paths:

- **`zitadel_install`** (v0.1) — Zitadel + chart-bundled Bitnami
  Postgres subchart. Single self-contained kubectl-apply.
- **`zitadel_install_external_pg`** (v0.2) — Zitadel pointed at a
  hand-rolled standalone `postgres:18-alpine` Deployment. Drops
  the bundled subchart; closer to production shape.
- **`zitadel_install_cnpg`** (v0.3) — Zitadel pointed at a
  [CNPG](https://cloudnative-pg.io/)-managed `Cluster` CR. Most
  production-shaped: HA-ready Postgres with operator-managed
  lifecycle. Cross-rule composition with
  [`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg).

```python
load("@rules_zitadel//:defs.bzl",
     "zitadel_install", "zitadel_health_check",
     "zitadel_install_external_pg", "zitadel_health_check_external_pg",
     "zitadel_install_cnpg", "zitadel_health_check_cnpg")

# Bundled Postgres (v0.1).
zitadel_install(name = "zitadel_install_bin")
zitadel_health_check(name = "zitadel_health_bin")

# External Postgres (v0.2 — standalone Deployment alongside Zitadel).
zitadel_install_external_pg(name = "zitadel_install_external_pg_bin")
zitadel_health_check_external_pg(name = "zitadel_health_external_pg_bin")

# CNPG-managed Postgres (v0.3 — requires CNPG operator installed upstream).
zitadel_install_cnpg(name = "zitadel_install_cnpg_bin")
zitadel_health_check_cnpg(name = "zitadel_health_cnpg_bin")
```

Zitadel is an open-source identity and access management server —
OIDC + SAML + management gRPC API, organizations / projects /
users, asymmetric signing keys for issued tokens. The smoke
fetches the OIDC discovery document and the JWKS, asserting the
issuer + signing keys are reachable. Same smoke for both install
paths — Zitadel's HTTP API is identical regardless of which DB
is behind it.

**Pinned versions:** Zitadel helm chart `9.34.0` (Zitadel
`v4.13.0`). The chart bundles Bitnami's `postgresql` subchart at
`>=16.0.0` (resolves to current 18.x at maintainer-render time).
Smoke-fixture render — single Zitadel replica, single Postgres
replica, emptyDir storage, login UI off, TLS off.

> **NOT a production starting point.** Dev-mode-shaped fixture:
> hardcoded admin password, hardcoded Postgres credentials,
> hardcoded master key, plaintext HTTP, no persistence.
> Production deploys override every credential, point at an
> external Postgres (or CockroachDB), turn TLS back on with
> cert-manager, and pivot from the password-bootstrapped admin to
> OIDC / SAML federation.

> **Init + setup Jobs are load-bearing.** The chart renders three
> Jobs: `zitadel-init` (DB schema migrations), `zitadel-setup`
> (signing-key generation + initial admin user creation), and
> `zitadel-cleanup`. They're declared as `helm.sh/hook:
> pre-install` but `kubectl apply` ignores helm hooks, so they
> run alongside the main Deployment. Zitadel's pod's
> `/debug/ready` probe gates on both Jobs completing — so
> `wait_for_deployments = ["zitadel"]` transitively waits on
> them. The chart's default `startupProbe` only allows 30s of
> grace, far too short for cold CI; the rendered values bump
> `failureThreshold=120, periodSeconds=5` (10 minutes). Bumping
> further if your CI is even slower.

**Supported platforms (v0.1):** any platform where rules_kubectl
runs. Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Macros](#macros)
- [Talking to Zitadel](#talking-to-zitadel)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_zitadel", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl)
≥ 0.2.0.

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_zitadel//:defs.bzl", "zitadel_install", "zitadel_health_check")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Zitadel.
zitadel_install(name = "zitadel_install_bin")
zitadel_health_check(name = "zitadel_health_bin")
sh_binary(name = "zitadel_install_wrapper", srcs = ["install_wrapper.sh"], data = [":zitadel_install_bin"])
sh_binary(name = "zitadel_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":zitadel_health_bin"])

itest_service(
    name = "zitadel_svc",
    exe = ":zitadel_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":zitadel_health_wrapper",
)
```

---

## Macros

### `zitadel_install`

```python
zitadel_install(
    name = "zitadel_install_bin",
    namespace = "zitadel",        # default
    wait_timeout = "900s",        # default — 15 min
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_zitadel//private/manifests:zitadel.yaml`.
- `create_namespace = True`.
- `server_side = True`.
- `wait_for_deployments = ["zitadel"]`.
- `wait_for_rollouts = ["sts/zitadel-postgresql"]`.
- `wait_timeout = "900s"`.

### `zitadel_health_check`

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

### `zitadel_install_external_pg`

```python
zitadel_install_external_pg(
    name = "zitadel_install_external_pg_bin",
    namespace = "zitadel",        # default
    wait_timeout = "900s",        # default
)
```

Same shape as `zitadel_install` but applies **two** manifests in
a single `kubectl_apply` call:

1. `@rules_zitadel//private/manifests:postgres-standalone.yaml` —
   a hand-rolled `postgres:18-alpine` Deployment + Service +
   Secret in the same namespace as Zitadel.
2. `@rules_zitadel//private/manifests:zitadel-external-pg.yaml` —
   Zitadel chart re-rendered with `postgresql.enabled: false` and
   the discrete `Database.Postgres.{Host, Port, ...}` fields
   pointed at the standalone Postgres Service.

Wait shape is `wait_for_deployments = ["zitadel", "postgres"]`
(no StatefulSet here — both Postgres and Zitadel are
Deployments).

### `zitadel_health_check_external_pg`

Pair with the install above. Same wait shape with `--timeout=0s`.

### `zitadel_install_cnpg`

```python
zitadel_install_cnpg(
    name = "zitadel_install_cnpg_bin",
    namespace = "zitadel",        # default
    wait_timeout = "900s",        # default
)
```

Cross-rule composition with `rules_cloudnativepg`. Applies two
manifests in a single `kubectl_apply`:

1. **`@rules_zitadel//private/manifests:zitadel-db-cluster.yaml`** —
   a CNPG `Cluster` CR (1 instance for the smoke fixture; production
   overrides `instances: 3+`) plus a bootstrap credentials Secret.
   The bootstrap owner is promoted to SUPERUSER via
   `postInitApplicationSQL` so Zitadel migrations succeed.
2. **`@rules_zitadel//private/manifests:zitadel-cnpg.yaml`** —
   Zitadel chart re-rendered with `postgresql.enabled: false`,
   pointing at `zitadel-db-rw.<namespace>.svc.cluster.local`.

Wait shape: `wait_for_deployments = ["zitadel"]` (transitively
gates on Cluster readiness via Zitadel's `/debug/ready` probe)
and `wait_for_crds = ["clusters.postgresql.cnpg.io"]` (sanity
check that the CNPG operator is installed).

**Required upstream:** the CNPG operator must be installed before
this macro runs. Wire `cloudnativepg_install` (from
[`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg))
as an `itest_service` dep:

```python
cloudnativepg_install(name = "cnpg_install_bin")
itest_service(name = "cnpg_svc", exe = ":cnpg_install_wrapper",
              health_check = ":cnpg_health_wrapper",
              deps = [":kind_svc"])

zitadel_install_cnpg(name = "zitadel_install_cnpg_bin")
itest_service(name = "zitadel_cnpg_svc",
              exe = ":zitadel_install_cnpg_wrapper",
              health_check = ":zitadel_health_cnpg_wrapper",
              deps = [":cnpg_svc"])    # <-- chains on CNPG
```

See `tests/BUILD.bazel` for the full composition.

### `zitadel_health_check_cnpg`

Pair with the install above. Same wait shape with `--timeout=0s`.

---

## Talking to Zitadel

Once Zitadel is up, the in-cluster Service
`zitadel.<namespace>.svc.cluster.local:8080` accepts HTTP
requests. The chart uses HTTP (not HTTPS) by default in the smoke
render — production flips this back on with a real certificate.

| Path | Use |
|---|---|
| `GET /.well-known/openid-configuration` | OIDC discovery — issuer + endpoints + JWKS URI. |
| `GET /oauth/v2/keys` | JWKS for the issuer's signing keys. |
| `POST /oauth/v2/token` | Token endpoint — exchange auth code or service-account JWT. |
| `gRPC /zitadel.management.v1.ManagementService` | Org / project / user management. Authenticated. |
| `GET /debug/healthz` | Liveness. |
| `GET /debug/ready` | Readiness — gates on DB + setup completion. |

For the management API consumers will:

1. Read the bootstrapped admin SA's private key from the chart-
   created Secret (or pass their own SA private key via the
   chart's `zitadel.serviceAccountKey`).
2. Sign a JWT bearer assertion (audience = the Zitadel issuer URL).
3. Exchange via `POST /oauth/v2/token` for an access token.
4. Authenticate gRPC calls via `Authorization: Bearer <token>`.

v0.1 doesn't exercise the authenticated path — that's a v0.2
candidate.

---

## Gotchas

Three things that will bite anyone bumping the chart or
debugging an install failure. Captured here so future-us doesn't
re-discover them in CI.

### `pre-install` Job hooks are silently ignored by `kubectl apply`

The chart renders three Jobs — `zitadel-init` (DB schema
migrations), `zitadel-setup` (signing keys + initial admin user),
`zitadel-cleanup` (post-uninstall housekeeping) — annotated
`helm.sh/hook: pre-install,pre-upgrade`. Helm CLI honors those
hooks and runs the Jobs to completion before applying the rest of
the manifest. **`kubectl apply -f` doesn't honor helm hooks at
all** — the Jobs apply as regular Jobs alongside the Deployment.

Fine for our purposes: Zitadel's `/debug/ready` readiness probe
gates on init + setup completing, so `wait_for_deployments =
["zitadel"]` transitively waits on the Jobs.

If you ever need to gate explicitly (e.g. fail fast on a migration
error rather than waiting out the startupProbe):
`kubectl wait job/zitadel-init --for=condition=Complete` works
post-apply.

### The chart's default `startupProbe` is too short for cold CI

Default: `failureThreshold: 30`, `periodSeconds: 1` — 30 seconds
of grace before k8s starts respawning the container. Cold CI runs
need much longer:

- Zitadel image pull: ~150 MB
- Postgres image pull: ~120 MB
- Postgres init (initdb)
- `zitadel-init` Job DB migration
- `zitadel-setup` Job signing-key generation
- Zitadel server boot + `/debug/ready` flips to 200

Realistically 5–10 minutes on a cold-pull runner. The Zitadel pod
will crashloop indefinitely if the startupProbe fires before
setup is done.

The rendered values bump it to `failureThreshold: 120`,
`periodSeconds: 5` (10 minutes total).

> **Subtle gotcha within this gotcha:** `startupProbe` is at the
> ROOT of `values.yaml`, NOT nested under `zitadel:`. The chart
> reads `.Values.startupProbe.*` directly. With the override
> nested under `zitadel.startupProbe` it silently doesn't apply
> — caught only by re-rendering and grepping the output.

### `MasterKey` is required at template time

Zitadel uses a 32-byte symmetric key for column encryption (token
signing keys, IDP secrets, etc.). The chart errors at
`helm template` time if `zitadel.masterkey` is missing or not
exactly 32 characters — not at runtime, not at install. The
smoke fixture hardcodes a constant string. **Production wires this
via a Secret + env-var ref**:

```yaml
zitadel:
  masterkeyExistingSecret: "zitadel-masterkey"   # existing Secret with key `masterkey`
```

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Zitadel manifest | Fully hermetic. Chart .tgz + sha256 pinned in `tools/versions.bzl`; rendered + committed. | Re-render via `bash tools/render_zitadel.sh <version>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Zitadel container image | Pulled at runtime. `ghcr.io/zitadel/zitadel:v4.13.0`. | Future: pre-load via `kind_cluster.images`. |
| PostgreSQL container image | Pulled at runtime. `docker.io/bitnami/postgresql:18.x`. | Bundled Bitnami subchart. |
| `curlimages/curl:8.10.1` (smoke) | Pulled at runtime. | |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`,
  add a `helm_template + sh_binary` block in `tools/BUILD.bazel`,
  run `bash tools/render_zitadel.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- Authenticated round-trip smoke (admin SA → JWT bearer →
  `POST /oauth/v2/token` → create User via management gRPC →
  read it back) — v0.2 candidate
- External-Postgres render variant (drop the bundled subchart,
  point at a separately-deployed Postgres) — v0.2 candidate
- Compose with [`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg)
  for production-shaped HA Postgres — v0.3 candidate
- Login UI smoke (Zitadel chart 9.x splits the login flow into
  its own Deployment; v0.1 disables it)
- SAML SP smoke (Zitadel as IdP for a SAML test client)
- TLS-on render variant (chart wires self-signed certs via
  cert-manager — compose with `rules_certmanager`)
