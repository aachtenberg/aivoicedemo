#!/usr/bin/env bash
# Voice spike — place one real outbound call via Amazon Connect.
#   Source (claimed) number + contact flow -> StartOutboundVoiceContact -> the flow plays
#   a Polly "your item is ready" message to the destination.
#
# Prereqs: claim_phone_number = true and `tofu apply` (claims a ~$1/mo DID).
# Usage:   ./scripts/place_call.sh +15551234567     # destination you control, E.164
set -euo pipefail

REGION="${REGION:-us-east-1}"
INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"

DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "usage: $0 <destination E.164, e.g. +15551234567>" >&2
  exit 2
fi

INSTANCE="$(cd "$INFRA_DIR" && tofu output -raw connect_instance_id)"
FLOW="$(cd "$INFRA_DIR" && tofu output -raw connect_contact_flow_id)"
SRC="$(cd "$INFRA_DIR" && tofu output -raw connect_source_number 2>/dev/null || echo '')"

if [[ -z "$SRC" || "$SRC" == "null" ]]; then
  echo "No source number claimed. Set 'claim_phone_number = true' in terraform.tfvars and run 'tofu apply'." >&2
  exit 1
fi

echo "Placing call:  $SRC  ->  $DEST"
echo "  instance=$INSTANCE  flow=$FLOW  region=$REGION"
aws connect start-outbound-voice-contact \
  --region "$REGION" \
  --instance-id "$INSTANCE" \
  --contact-flow-id "$FLOW" \
  --destination-phone-number "$DEST" \
  --source-phone-number "$SRC"
echo "Requested. The destination should ring shortly and hear the pickup message."
