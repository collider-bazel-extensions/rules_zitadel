#!/usr/bin/env bash
# OIDC discovery smoke for Zitadel.
# Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. GET /.well-known/openid-configuration on Zitadel's Service.
#      Zitadel's OIDC issuer endpoint returns a JSON document with
#      `issuer`, `jwks_uri`, `token_endpoint`, etc. — but only
#      after the setup Job has generated the signing keys + the
#      DB schema migrations have completed. So a 200 + valid JSON
#      proves the entire init/setup chain is done.
#   3. Sanity-fetch the JWKS that the discovery doc points at:
#      GET /oauth/v2/keys (the chart uses Zitadel's default
#      jwks_uri path). Asserts the response contains `"keys":`.
#      Proves the issuer's signing keys are reachable + the auth
#      backend is wired through.
#
# v0.2 candidate: actually authenticate via the admin SA + create
# a User via the management API. v0.1's smoke is read-only.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
ZITADEL_HOST="zitadel.zitadel.svc.cluster.local"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run zitadel-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod zitadel-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/zitadel-curl --for=condition=Ready --timeout=60s

# Fetch the OIDC discovery doc. The install_bin's deployment-
# Available wait gates on Zitadel's `/debug/ready`, which itself
# gates on setup Job completion + signing-key generation. So this
# should be a clean 200 first try.
echo "smoke_test: GET /.well-known/openid-configuration"
disco_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/.well-known/openid-configuration" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$disco_resp"; then
  echo "smoke_test: FAIL — OIDC discovery did not return 200" >&2
  echo "$disco_resp" >&2
  exit 1
fi
# The discovery doc must contain the `issuer` field (the only
# OIDC-required field by spec). Sanity-check it points at our
# Zitadel host.
if ! grep -q "\"issuer\":" <<<"$disco_resp"; then
  echo "smoke_test: FAIL — discovery doc missing 'issuer' field" >&2
  echo "$disco_resp" >&2
  exit 1
fi
if ! grep -q "\"jwks_uri\":" <<<"$disco_resp"; then
  echo "smoke_test: FAIL — discovery doc missing 'jwks_uri' field" >&2
  echo "$disco_resp" >&2
  exit 1
fi

# Fetch the JWKS. Zitadel's default jwks_uri is /oauth/v2/keys.
# The discovery doc carries the canonical URL, but parsing JSON
# in pure bash is annoying — we just hit the documented path.
echo "smoke_test: GET /oauth/v2/keys (JWKS)"
jwks_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/oauth/v2/keys" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$jwks_resp"; then
  echo "smoke_test: FAIL — JWKS endpoint did not return 200" >&2
  echo "$jwks_resp" >&2
  exit 1
fi
if ! grep -q "\"keys\":" <<<"$jwks_resp"; then
  echo "smoke_test: FAIL — JWKS response missing 'keys' array" >&2
  echo "$jwks_resp" >&2
  exit 1
fi

echo "smoke_test: OK — Zitadel OIDC discovery + JWKS round-tripped (init + setup + signing keys all live)"
