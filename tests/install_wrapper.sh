#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/zitadel_install_bin.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: zitadel_install_bin not at $INSTALL_BIN" >&2; exit 1; }

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

# Diagnostic dump: Zitadel's failure modes are diverse — Postgres
# unreachable, init Job migration failure, setup Job signing-key
# generation failure, the main pod's `/debug/ready` perma-failing
# because TLS / config is misconfigured. Pull pod state +
# describe + logs (current AND --previous) for everything in the
# zitadel namespace.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper: install_bin exited $rc — dumping cluster state =====" >&2
  echo "---- pods/deploy/sts/jobs (-n zitadel) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel get pods,deploy,sts,jobs -o wide >&2 || true
  echo "---- describe deploy/zitadel ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe deploy/zitadel >&2 || true
  echo "---- describe jobs ----" >&2
  for j in zitadel-init zitadel-setup; do
    echo "    -- $j --" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel describe "job/$j" >&2 || true
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs "job/$j" --tail=120 >&2 || true
  done
  echo "---- zitadel logs ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --tail=200 >&2 || true
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs deploy/zitadel --previous --tail=200 >&2 || true
  echo "---- postgres logs ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n zitadel logs sts/zitadel-postgresql --tail=80 >&2 || true
  exit "$rc"
}
trap on_install_fail ERR

"$INSTALL_BIN"
