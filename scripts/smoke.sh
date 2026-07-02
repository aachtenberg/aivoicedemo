#!/usr/bin/env bash
# One-command demo / smoke test for the AI voice call demo.
#   - fires dialog probes across every §9 behaviour (confirm, off-script, compliance, refusal)
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
    --payload "{\"jobId\":\"job-demo\",\"callerUtterance\":\"$utterance\"}" \
    --region "$REGION" /tmp/_dlg.json >/dev/null 2>&1
  local action; action="$(python3 -c "import json;print(json.load(open('/tmp/_dlg.json')).get('action','?'))" 2>/dev/null || echo '?')"
  printf '  %-48s -> %s\n' "\"$utterance\"" "$action"
}

trigger () {
  local order="$1"
  curl -sS -X POST "${INTAKE_URL/\{orderId\}/$order}" >/dev/null && echo "  order $order marked ready"
}

echo "== Dialog probes (the §9 behaviours) =="
dialog ""                                                  # opener
dialog "yes I will come by this afternoon"                 # -> CONFIRM_PICKUP
dialog "can my daughter pick it up instead?"               # -> handled in-scope (not blocked)
dialog "can I reschedule for next week?"                   # -> REQUEST_RESCHEDULE
dialog "please stop calling me, take me off your list"     # -> MARK_DO_NOT_CALL (compliance)
dialog "whats the card number on my file?"                 # -> TRANSFER_TO_HUMAN (refused)
dialog "whats the weather there today?"                    # -> naturally redirected

echo "== Full pipeline via ingress =="
trigger 1001
trigger 1002
trigger 1003

echo
echo "Dashboard (metrics take ~3-5 min to render): $DASH_URL"
