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

def zitadel_install(
        name,
        namespace = "zitadel",
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
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_zitadel//private/manifests:zitadel.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_ZITADEL_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_ZITADEL_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def zitadel_health_check(
        name,
        namespace = "zitadel",
        **kwargs):
    """Readiness probe paired with `zitadel_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_ZITADEL_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_ZITADEL_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        **kwargs
    )
