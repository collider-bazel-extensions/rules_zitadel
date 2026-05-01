#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster_external_pg"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/zitadel_install_external_pg_bin.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: zitadel_install_external_pg_bin not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "install_wrapper: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Diagnostic dump: external Postgres path adds Postgres
# Deployment to the failure surface — pull pod state + logs for
# both `postgres` and `zitadel` Deployments + the init/setup
# Jobs.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper_external_pg: install_bin exited $rc — dumping cluster state =====" >&2
  echo "---- pods/deploy/jobs (-n zitadel) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel get pods,deploy,jobs -o wide >&2 || true
  echo "---- describe deploy/postgres ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe deploy/postgres >&2 || true
  echo "---- describe deploy/zitadel ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe deploy/zitadel >&2 || true
  for j in zitadel-init zitadel-setup; do
    echo "---- describe + logs $j ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe "job/$j" >&2 || true
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs "job/$j" --tail=120 >&2 || true
  done
  echo "---- postgres logs (--tail=80) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/postgres --tail=80 >&2 || true
  echo "---- zitadel logs (--tail=200, current + previous) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --tail=200 >&2 || true
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --previous --tail=200 >&2 || true
  exit "$rc"
}
trap on_install_fail ERR

"$INSTALL_BIN"
