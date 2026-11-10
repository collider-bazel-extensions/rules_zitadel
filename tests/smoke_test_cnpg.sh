#!/usr/bin/env bash
# Same OIDC discovery + JWKS round-trip as the bundled and
# external-PG smokes. Zitadel's HTTP API is identical regardless
# of which DB is behind it; this run proves the CNPG-Cluster path
# also boots end-to-end.
set -euo pipefail

CLUSTER_NAME="cluster_cnpg"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
ZITADEL_HOST="zitadel.zitadel.svc.cluster.local"

echo "smoke_test_cnpg: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run zitadel-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod zitadel-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/zitadel-curl --for=condition=Ready --timeout=60s

echo "smoke_test_cnpg: GET /.well-known/openid-configuration"
disco_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/.well-known/openid-configuration" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$disco_resp"; then
  echo "smoke_test_cnpg: FAIL — OIDC discovery did not return 200" >&2
  echo "$disco_resp" >&2
  exit 1
fi
if ! grep -q "\"issuer\":" <<<"$disco_resp" || ! grep -q "\"jwks_uri\":" <<<"$disco_resp"; then
  echo "smoke_test_cnpg: FAIL — discovery doc missing issuer/jwks_uri" >&2
  echo "$disco_resp" >&2
  exit 1
fi

echo "smoke_test_cnpg: GET /oauth/v2/keys (JWKS)"
jwks_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/oauth/v2/keys" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$jwks_resp"; then
  echo "smoke_test_cnpg: FAIL — JWKS did not return 200" >&2
  echo "$jwks_resp" >&2
  exit 1
fi
if ! grep -q "\"keys\":" <<<"$jwks_resp"; then
  echo "smoke_test_cnpg: FAIL — JWKS missing 'keys' array" >&2
  echo "$jwks_resp" >&2
  exit 1
fi

# Sanity-check: confirm the Cluster CR is Healthy.
echo "smoke_test_cnpg: checking CNPG Cluster status"
cluster_status=$("${KCTL[@]}" -n zitadel get cluster.postgresql.cnpg.io/zitadel-db \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$cluster_status" != "Cluster in healthy state" ]]; then
  echo "smoke_test_cnpg: WARN — CNPG Cluster phase: '$cluster_status' (Zitadel works regardless, but worth flagging)" >&2
fi

# Login V2. Zitadel v4 defaults a new instance to Login V2, so the
# authorize endpoint redirects browsers to /ui/v2/login/..., which
# only the separate zitadel-login app serves. Ask for an authorize
# redirect as the console would (its client id is in the console's
# environment.json), then fetch the redirect target from the
# zitadel-login Service, as an ingress routing /ui/v2/login would.
echo "smoke_test_cnpg: Login V2 authorize redirect"
env_json=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/ui/console/assets/environment.json" 2>/dev/null || true)
client_id=$(sed -n 's/.*"clientid": *"\([^"]*\)".*/\1/p' <<<"$env_json")
if [[ -z "$client_id" ]]; then
  echo "smoke_test_cnpg: FAIL — no console clientid in environment.json" >&2
  echo "$env_json" >&2
  exit 1
fi
redirect_uri="http://${ZITADEL_HOST}:8080/ui/console/auth/callback"
challenge="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
authz_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -s -o /dev/null -w "HTTP %{http_code}\nLocation: %{redirect_url}\n" \
    -H "Host: ${ZITADEL_HOST}" \
    "http://${ZITADEL_HOST}:8080/oauth/v2/authorize?client_id=${client_id}&redirect_uri=${redirect_uri}&response_type=code&scope=openid&code_challenge=${challenge}&code_challenge_method=S256" 2>/dev/null || true)
login_url=$(sed -n 's/^Location: //p' <<<"$authz_resp")
login_path="/${login_url#*://*/}"
if [[ "$login_path" != /ui/v2/login/* ]]; then
  echo "smoke_test_cnpg: FAIL — authorize did not redirect to /ui/v2/login" >&2
  echo "$authz_resp" >&2
  exit 1
fi
# --connect-to plays the ingress: requests for the external host go to
# the zitadel-login Service, and -L follows the app's own redirects
# (e.g. on to its loginname step), which stay under /ui/v2/login.
echo "smoke_test_cnpg: GET ${login_path%%\?*} from the zitadel-login Service"
login_resp=$("${KCTL[@]}" -n "$NS" exec zitadel-curl -- \
    curl -sL --max-redirs 5 -w "\nHTTP %{http_code}\nURL %{url_effective}\n" \
    --connect-to "${ZITADEL_HOST}:8080:zitadel-login.zitadel.svc.cluster.local:3000" \
    "http://${ZITADEL_HOST}:8080${login_path}" 2>/dev/null || true)
final_path="/$(sed -n 's/^URL [a-z]*:\/\/[^/]*\///p' <<<"$login_resp")"
if ! grep -q "^HTTP 200\$" <<<"$login_resp" || ! grep -qi "<html" <<<"$login_resp" \
    || [[ "$final_path" != /ui/v2/login/* ]]; then
  echo "smoke_test_cnpg: FAIL — the login app did not serve ${login_path%%\?*} (HTTP 200 HTML under /ui/v2/login)" >&2
  tail -c 2000 <<<"$login_resp" >&2
  exit 1
fi
echo "smoke_test_cnpg: login app served ${final_path%%\?*}"

echo "smoke_test_cnpg: OK — Zitadel + CNPG-managed Postgres OIDC round-trip and Login V2 succeeded"
