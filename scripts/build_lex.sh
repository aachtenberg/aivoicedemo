#!/usr/bin/env bash
# Phase B — build the Lex V2 "speech pipe" bot and bind it to the code-hook adapter.
#
# The aws Terraform provider has no bot-alias resource (and Lex needs an imperative
# build step), so the bot is built here via CLI. Everything else stays in OpenTofu.
# Idempotent: re-running finds the existing bot/alias and updates it.
#
# Result: a Lex bot alias whose FallbackIntent code hook invokes the connect_adapter
# Lambda -> dialog engine. Ends with a recognize-text self-test (no phone needed).
set -euo pipefail

REGION="${REGION:-us-east-1}"
INFRA_DIR="$(cd "$(dirname "$0")/../infra" && pwd)"
BOT_NAME="${BOT_NAME:-aivoicedemo-demo-dialog}"
ALIAS_NAME="${ALIAS_NAME:-live}"
LOCALE="en_US"

ADAPTER_ARN="$(cd "$INFRA_DIR" && tofu output -raw connect_adapter_function_arn)"
ADAPTER_NAME="$(cd "$INFRA_DIR" && tofu output -raw connect_adapter_function_name)"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
lex() { aws lexv2-models "$@" --region "$REGION"; }

echo "== Lex service-linked role =="
SLR="$(aws iam create-service-linked-role --aws-service-name lexv2.amazonaws.com --query 'Role.Arn' --output text 2>/dev/null \
      || aws iam list-roles --path-prefix /aws-service-role/lexv2.amazonaws.com/ --query 'Roles[0].Arn' --output text)"
echo "  $SLR"

echo "== bot ($BOT_NAME) =="
BOT_ID="$(lex list-bots --query "botSummaries[?botName=='${BOT_NAME}'].botId | [0]" --output text)"
if [[ "$BOT_ID" == "None" || -z "$BOT_ID" ]]; then
  BOT_ID="$(lex create-bot --bot-name "$BOT_NAME" --role-arn "$SLR" \
            --data-privacy childDirected=false --idle-session-ttl-in-seconds 300 \
            --query 'botId' --output text)"
fi
echo "  botId=$BOT_ID"
until [[ "$(lex describe-bot --bot-id "$BOT_ID" --query botStatus --output text)" == "Available" ]]; do sleep 3; done

echo "== locale ($LOCALE) =="
if ! lex describe-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" >/dev/null 2>&1; then
  lex create-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
      --nlu-intent-confidence-threshold 0.4 >/dev/null
fi
# Settle to any editable state (Failed is recoverable — we add an intent and rebuild).
until case "$(lex describe-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" --query botLocaleStatus --output text)" in
  NotBuilt|Built|Failed) true;; *) false;; esac; do sleep 3; done

echo "== FallbackIntent -> fulfillment code hook =="
FB_ID="$(lex list-intents --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
        --query "intentSummaries[?intentName=='FallbackIntent'].intentId | [0]" --output text)"
lex update-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
    --intent-id "$FB_ID" --intent-name FallbackIntent \
    --parent-intent-signature AMAZON.FallbackIntent \
    --fulfillment-code-hook enabled=true >/dev/null

echo "== custom intent 'Talk' (Lex requires >=1 custom intent w/ an utterance) =="
# Real routing is the FallbackIntent (catches everything). This intent exists only to
# satisfy the build requirement; it is also code-hooked so matched utterances still reach
# the adapter. Both intents -> connect_adapter -> dialog engine.
TALK_ID="$(lex list-intents --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
          --query "intentSummaries[?intentName=='Talk'].intentId | [0]" --output text)"
if [[ "$TALK_ID" == "None" || -z "$TALK_ID" ]]; then
  lex create-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" \
    --intent-name Talk \
    --sample-utterances '[{"utterance":"hello"},{"utterance":"yes"},{"utterance":"okay"},{"utterance":"pickup"}]' \
    --fulfillment-code-hook enabled=true >/dev/null
fi

echo "== build locale =="
lex build-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" >/dev/null
until case "$(lex describe-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LOCALE" --query botLocaleStatus --output text)" in
  Built) true;; Failed) echo "build failed"; exit 1;; *) false;; esac; do sleep 5; done

echo "== version =="
VER="$(lex create-bot-version --bot-id "$BOT_ID" \
      --bot-version-locale-specification "{\"$LOCALE\":{\"sourceBotVersion\":\"DRAFT\"}}" \
      --query botVersion --output text)"
until [[ "$(lex describe-bot-version --bot-id "$BOT_ID" --bot-version "$VER" --query botStatus --output text)" == "Available" ]]; do sleep 3; done
echo "  version=$VER"

echo "== alias ($ALIAS_NAME) with Lambda code hook =="
SETTINGS="{\"$LOCALE\":{\"enabled\":true,\"codeHookSpecification\":{\"lambdaCodeHook\":{\"lambdaARN\":\"$ADAPTER_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}}}"
ALIAS_ID="$(lex list-bot-aliases --bot-id "$BOT_ID" --query "botAliasSummaries[?botAliasName=='${ALIAS_NAME}'].botAliasId | [0]" --output text)"
if [[ "$ALIAS_ID" == "None" || -z "$ALIAS_ID" ]]; then
  ALIAS_ID="$(lex create-bot-alias --bot-id "$BOT_ID" --bot-alias-name "$ALIAS_NAME" --bot-version "$VER" \
             --bot-alias-locale-settings "$SETTINGS" --query botAliasId --output text)"
else
  lex update-bot-alias --bot-id "$BOT_ID" --bot-alias-id "$ALIAS_ID" --bot-alias-name "$ALIAS_NAME" \
      --bot-version "$VER" --bot-alias-locale-settings "$SETTINGS" >/dev/null
fi
until [[ "$(lex describe-bot-alias --bot-id "$BOT_ID" --bot-alias-id "$ALIAS_ID" --query botAliasStatus --output text)" == "Available" ]]; do sleep 3; done
ALIAS_ARN="arn:aws:lex:${REGION}:${ACCT}:bot-alias/${BOT_ID}/${ALIAS_ID}"
echo "  aliasId=$ALIAS_ID"

echo "== allow Lex to invoke the adapter Lambda =="
aws lambda add-permission --region "$REGION" --function-name "$ADAPTER_NAME" \
  --statement-id lex-invoke --action lambda:InvokeFunction \
  --principal lexv2.amazonaws.com --source-arn "$ALIAS_ARN" >/dev/null 2>&1 || true

# Persist ids for the contact flow / other scripts.
cat > "$INFRA_DIR/.lex-ids.env" <<EOF
LEX_BOT_ID=$BOT_ID
LEX_BOT_ALIAS_ID=$ALIAS_ID
LEX_BOT_ALIAS_ARN=$ALIAS_ARN
EOF
echo "== wrote $INFRA_DIR/.lex-ids.env =="
cat "$INFRA_DIR/.lex-ids.env"

echo
echo "== self-test: recognize-text (utterance -> Lex -> adapter -> dialog) =="
for U in "yes I will come this afternoon" "can my daughter pick it up instead" "what is the card number on my file"; do
  echo "  caller: \"$U\""
  aws lexv2-runtime recognize-text --region "$REGION" \
    --bot-id "$BOT_ID" --bot-alias-id "$ALIAS_ID" --locale-id "$LOCALE" \
    --session-id "smoke-$RANDOM" \
    --session-state '{"sessionAttributes":{"jobId":"job-5678"}}' \
    --text "$U" \
    --query '{say: messages[0].content, action: sessionState.sessionAttributes.finalAction, dialog: sessionState.dialogAction.type}' \
    --output json
done
