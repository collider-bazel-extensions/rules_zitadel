#!/usr/bin/env bash
# Same OIDC discovery + JWKS round-trip as the bundled-Postgres
# smoke. The Zitadel HTTP API is identical regardless of which
# DB is behind it; this smoke proves the external-Postgres path
# also boots end-to-end (DB migrations against the standalone
# Postgres + signing-key generation + the issuer responding).
set -euo pipefail

CLUSTER_NAME="cluster_external_pg"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
ZITADEL_HOST="zitadel.zitadel.svc.cluster.local"

echo "smoke_test_external_pg: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run zitadel-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod zitadel-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/zitadel-curl --for=condition=Ready --timeout=60s

echo "smoke_test_external_pg: GET /.well-known/openid-configuration"
disco_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/.well-known/openid-configuration" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$disco_resp"; then
  echo "smoke_test_external_pg: FAIL — OIDC discovery did not return 200" >&2
  echo "$disco_resp" >&2
  exit 1
fi
if ! grep -q "\"issuer\":" <<<"$disco_resp" || ! grep -q "\"jwks_uri\":" <<<"$disco_resp"; then
  echo "smoke_test_external_pg: FAIL — discovery doc missing issuer/jwks_uri" >&2
  echo "$disco_resp" >&2
  exit 1
fi

echo "smoke_test_external_pg: GET /oauth/v2/keys (JWKS)"
jwks_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/oauth/v2/keys" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$jwks_resp"; then
  echo "smoke_test_external_pg: FAIL — JWKS did not return 200" >&2
  echo "$jwks_resp" >&2
  exit 1
fi
if ! grep -q "\"keys\":" <<<"$jwks_resp"; then
  echo "smoke_test_external_pg: FAIL — JWKS missing 'keys' array" >&2
  echo "$jwks_resp" >&2
  exit 1
fi

echo "smoke_test_external_pg: OK — Zitadel + standalone Postgres OIDC round-trip succeeded"
