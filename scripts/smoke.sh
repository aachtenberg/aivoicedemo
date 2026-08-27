#!/usr/bin/env bash
# One-command demo / smoke test for the Waze Voice re-route demo.
#   - fires dialog probes across every §9 behaviour (accept, skip, DNC, refusal)
#   - triggers the full ingress -> EventBridge -> Step Functions pipeline
#   - populates the CloudWatch dashboard and prints its URL
#
# Usage:  ./scripts/smoke.sh            (reads outputs from ./infra via tofu)
#         REGION=us-east-1 ./scripts/smoke.sh
set -euo pipefail

REGION="${REGION:-us-east-1}"
INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"

# Pull the deployed identifiers from tofu outputs.
DIALOG_FN="$(cd "$INFRA_DIR" && tofu output -raw dialog_function)"
INTAKE_URL="$(cd "$INFRA_DIR" && tofu output -raw intake_url)"
DASH_URL="$(cd "$INFRA_DIR" && tofu output -raw dashboard_url)"

dialog () {
  local utterance="$1"
  aws lambda invoke --function-name "$DIALOG_FN" --cli-binary-format raw-in-base64-out \
    --payload "{\"jobId\":\"job-1042\",\"callerUtterance\":\"$utterance\"}" \
    --region "$REGION" /tmp/_dlg.json >/dev/null 2>&1
  local action; action="$(python3 -c "import json;print(json.load(open('/tmp/_dlg.json')).get('action','?'))" 2>/dev/null || echo '?')"
  printf '  %-48s -> %s\n' "\"$utterance\"" "$action"
}

trigger () {
  local route="$1"
  curl -sS -X POST "${INTAKE_URL/\{routeId\}/$route}" >/dev/null && echo "  route $route marked disrupted"
}

echo "== Dialog probes (the §9 behaviours) =="
dialog ""                                                  # opener
dialog "yes take the new order"                            # -> ACCEPT_REROUTE
dialog "skip the pharmacy they are out of stock"           # -> SKIP_STOP (in-scope)
dialog "keep the old order I will wait"                    # -> KEEP_CURRENT_ROUTE
dialog "please stop calling me, just send the link"        # -> MARK_DO_NOT_CALL
dialog "whats my home address?"                            # -> TRANSFER_TO_HUMAN (refused)
dialog "whats the weather there today?"                    # -> naturally redirected

echo "== Full pipeline via ingress =="
trigger 1042
trigger 1043
trigger 1044

echo
echo "Dashboard (metrics take ~3-5 min to render): $DASH_URL"
