#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster_cnpg"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/zitadel_install_cnpg_bin.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: zitadel_install_cnpg_bin not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "install_wrapper_cnpg: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Diagnostic dump: CNPG path adds Cluster CR + per-instance Pods
# to the failure surface. Pull pod state across both `zitadel`
# (Cluster instances + Zitadel) and `cnpg-system` (operator)
# namespaces.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper_cnpg: install_bin exited $rc — dumping cluster state =====" >&2
  echo "---- pods/deploy/jobs (-n zitadel) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel get pods,deploy,jobs -o wide >&2 || true
  echo "---- describe cluster.postgresql.cnpg.io/zitadel-db ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe cluster.postgresql.cnpg.io/zitadel-db >&2 || true
  echo "---- zitadel-db-1 logs (CNPG postgres pod) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs zitadel-db-1 --tail=120 >&2 || true
  for j in zitadel-init zitadel-setup; do
    echo "---- $j Job describe + logs ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe "job/$j" >&2 || true
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs "job/$j" --tail=120 >&2 || true
  done
  echo "---- zitadel deploy logs (current + previous) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --tail=200 >&2 || true
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --previous --tail=200 >&2 || true
  echo "---- cnpg-system operator logs ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n cnpg-system logs deploy/cnpg-cloudnative-pg --tail=120 >&2 || true
  exit "$rc"
}
trap on_install_fail ERR

"$INSTALL_BIN"
