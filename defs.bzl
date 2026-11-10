"""Public API for rules_zitadel."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# In v0.1's smoke render (Zitadel chart 9.34.0 with bundled Bitnami
# `postgresql` subchart), the chart emits one Zitadel Deployment +
# one Postgres StatefulSet + three Jobs (`zitadel-init` for DB
# schema, `zitadel-setup` for the initial org/admin/signing keys,
# `zitadel-cleanup` for post-uninstall housekeeping).
#
# The init + setup Jobs are rendered with `helm.sh/hook:
# pre-install` annotations, but `kubectl apply` IGNORES helm hooks
# — so they're applied as regular Jobs alongside everything else.
# That's fine: the Zitadel pod's `/debug/ready` readiness probe
# (which the chart wires) returns 503 until DB migrations + setup
# are complete, so waiting on the Deployment Available status
# implicitly waits on the Jobs. The chart's startup probe is
# overridden in the rendered values to give 10 minutes of grace
# (failureThreshold=120, periodSeconds=5) — long enough for cold
# CI image pulls + Postgres init + the migration + setup chain.
_ZITADEL_DEPLOYS = [
    "zitadel",
]
_ZITADEL_ROLLOUTS = [
    "sts/zitadel-postgresql",
]

# Login V2 (`login = True`, the default on every install macro).
# Zitadel v4 defaults a new instance to Login V2, so browser sign-in
# redirects to /ui/v2/login/..., which only the chart's separate
# `zitadel-login` Deployment serves (port 3000 on the `zitadel-login`
# Service). Its render is shared by all three install paths: it reads
# only ExternalDomain, the `zitadel` Service and the `login-client`
# PAT the setup Job writes, which are the same in each. Route
# /ui/v2/login to that Service in your ingress. `login = False`
# leaves the app out (the v0.3 renders), for instances that turn
# Login V2 off themselves.
_LOGIN_MANIFEST = "@rules_zitadel//private/manifests:zitadel-login.yaml"
_LOGIN_DEPLOYS = ["zitadel-login"]

def _login_manifests(login):
    return [_LOGIN_MANIFEST] if login else []

def _login_deploys(login):
    return list(_LOGIN_DEPLOYS) if login else []

def zitadel_install(
        name,
        namespace = "zitadel",
        login = True,
        wait_timeout = "900s",
        **kwargs):
    """Apply the pinned Zitadel manifest into `namespace` and block
    until the Zitadel Deployment AND chart-bundled PostgreSQL
    StatefulSet are Ready before idling.

    Drops into `itest_service.exe`. Wait timeout **900s** (15 min) —
    Zitadel's `/debug/ready` gates on DB schema migrations + the
    setup Job (which generates issuer signing keys and creates the
    initial admin user). On cold CI runners with image pulls (~150
    MB Zitadel + ~120 MB Postgres), the full chain can hit 6-8
    minutes.

    `login` (default True) also applies the Login V2 app
    (`zitadel-login` Deployment + Service on port 3000) and waits for
    it; see the note above `_LOGIN_MANIFEST`.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_zitadel//private/manifests:zitadel.yaml"] + _login_manifests(login),
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_ZITADEL_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(_ZITADEL_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def zitadel_health_check(
        name,
        namespace = "zitadel",
        login = True,
        **kwargs):
    """Readiness probe paired with `zitadel_install`. Pass the same
    `login` as the install."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_ZITADEL_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(_ZITADEL_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        **kwargs
    )

# ---- v0.2: external Postgres (drop bundled subchart) ------------------------
# Same Zitadel chart 9.34.0 but with `postgresql.enabled: false`.
# Zitadel is pointed at a separately-deployed standalone Postgres
# Deployment (`postgres` Service in the same namespace, hand-rolled
# in private/manifests/postgres-standalone.yaml). Production-shape
# closer than v0.1's bundled subchart — operators typically
# external-DB. v0.3 swaps the hand-rolled Postgres for a
# CNPG-managed Cluster (rules_cloudnativepg compose).
_ZITADEL_EXTERNAL_PG_DEPLOYS = [
    "zitadel",
    "postgres",
]

def zitadel_install_external_pg(
        name,
        namespace = "zitadel",
        login = True,
        wait_timeout = "900s",
        **kwargs):
    """Apply Zitadel + a hand-rolled standalone Postgres in
    `namespace` and block until both Deployments are Ready before
    idling.

    Drops into `itest_service.exe`. Same wait_timeout as
    `zitadel_install` (15 min) — DB migrations + setup are equally
    slow against an external Postgres. The chart's
    `postgresql.enabled: false` plus the hand-rolled Postgres
    means there's no chart-bundled StatefulSet here; both Postgres
    and Zitadel are Deployments.

    `login` (default True) also applies the Login V2 app and waits
    for it, as in `zitadel_install`.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        # Apply Postgres first so the Service / pod is creating
        # before Zitadel's init Job tries to connect. Apply order
        # within a single kubectl_apply -f -f isn't strictly
        # ordered (kubectl batches), but the manifest sequence
        # at least communicates intent.
        manifests = [
            "@rules_zitadel//private/manifests:postgres-standalone.yaml",
            "@rules_zitadel//private/manifests:zitadel-external-pg.yaml",
        ] + _login_manifests(login),
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_ZITADEL_EXTERNAL_PG_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def zitadel_health_check_external_pg(
        name,
        namespace = "zitadel",
        login = True,
        **kwargs):
    """Readiness probe paired with `zitadel_install_external_pg`. Pass
    the same `login` as the install."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_ZITADEL_EXTERNAL_PG_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        **kwargs
    )

# ---- v0.3: CloudNativePG-managed Postgres ----------------------------------
# Cross-rule composition: requires CNPG operator already installed
# (rules_cloudnativepg's `cloudnativepg_install` upstream in the
# itest_service dep chain). Applies a CNPG Cluster CR + bootstrap
# credentials Secret + Zitadel rendered with `postgresql.enabled:
# false` and pointed at the cluster's read-write Service
# (`zitadel-db-rw`).
#
# Race note worth flagging: the kubectl_apply applies all manifests
# at once, including the Zitadel init Job. CNPG takes ~30-60s to
# initdb + come up; Zitadel's init Job's backoffLimit=5 retries
# (~3 min total with default backoff) cover the gap. If your CI
# runs slow enough to exhaust the retries, switch to chaining via
# two `kubectl_apply` targets and `itest_service.deps`.
_ZITADEL_CNPG_DEPLOYS = [
    "zitadel",
]
_ZITADEL_CNPG_CRDS = [
    # Sanity-check the operator's CRD is present before the apply.
    # Without this the apply races CNPG operator startup and fails
    # at validation time.
    "clusters.postgresql.cnpg.io",
]

def zitadel_install_cnpg(
        name,
        namespace = "zitadel",
        login = True,
        wait_timeout = "900s",
        **kwargs):
    """Apply a CNPG-managed Postgres Cluster + Zitadel pointed at it.

    Drops into `itest_service.exe`. **Requires CNPG operator
    already installed** — wire `cloudnativepg_install` (from
    `rules_cloudnativepg`) as an `itest_service` dep upstream.

    Applies two manifests:
      - `private/manifests/zitadel-db-cluster.yaml` — Cluster CR
        (1 instance) + bootstrap credentials Secret. The
        bootstrap owner is promoted to SUPERUSER via
        postInitApplicationSQL so Zitadel migrations succeed.
      - `private/manifests/zitadel-cnpg.yaml` — Zitadel chart
        re-rendered with `postgresql.enabled: false`, discrete
        Database.Postgres.Host: zitadel-db-rw.

    The wait_for_deployments=["zitadel"] gate transitively
    covers Cluster readiness — Zitadel's init Job retries until
    the DB is reachable, then setup runs, then `/debug/ready`
    flips to 200. Same 15-minute wait_timeout as the other
    install paths.

    `login` (default True) also applies the Login V2 app and waits
    for it, as in `zitadel_install`.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = [
            "@rules_zitadel//private/manifests:zitadel-db-cluster.yaml",
            "@rules_zitadel//private/manifests:zitadel-cnpg.yaml",
        ] + _login_manifests(login),
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_ZITADEL_CNPG_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_ZITADEL_CNPG_CRDS) + list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def zitadel_health_check_cnpg(
        name,
        namespace = "zitadel",
        login = True,
        **kwargs):
    """Readiness probe paired with `zitadel_install_cnpg`. Pass the
    same `login` as the install."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_ZITADEL_CNPG_DEPLOYS) + _login_deploys(login) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_ZITADEL_CNPG_CRDS) + list(extra_crds),
        **kwargs
    )
