#!/usr/bin/env bash
# Runs in the GitHub runner. Rolls a release out to every EC2 instance tagged App=api and
# Environment=<env>, one instance at a time, and fails if any instance fails. No SSH, no open
# port 22: the instances are reached through AWS Systems Manager Run Command.
#
# Env: ENVIRONMENT, RELEASE_SHA, ARTIFACT_BUCKET (AWS credentials come from OIDC in the workflow)
set -euo pipefail

: "${ENVIRONMENT:?}" "${RELEASE_SHA:?}" "${ARTIFACT_BUCKET:?}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"

here="$(cd "$(dirname "$0")" && pwd)"

# The remote script is sent as the command body, prefixed with its inputs. The shebang makes SSM
# run it with bash (Ubuntu's /bin/sh is dash). Values are validated by the workflow before this runs.
params="$(jq -n \
  --arg sha "$RELEASE_SHA" \
  --arg uri "s3://$ARTIFACT_BUCKET/api/$RELEASE_SHA.tar.gz" \
  --rawfile script "$here/remote-deploy.sh" \
  '{commands: ["#!/usr/bin/env bash\nexport RELEASE_SHA=\($sha) ARTIFACT_URI=\($uri)\n" + $script]}')"

send="$(aws ssm send-command \
  --document-name AWS-RunShellScript \
  --targets "Key=tag:App,Values=api" "Key=tag:Environment,Values=$ENVIRONMENT" \
  --max-concurrency 1 \
  --max-errors 0 \
  --timeout-seconds 600 \
  --comment "api $RELEASE_SHA to $ENVIRONMENT" \
  --parameters "$params" \
  --output json)"

command_id="$(jq -r '.Command.CommandId' <<<"$send")"
targets="$(jq -r '.Command.TargetCount' <<<"$send")"
echo "SSM command $command_id sent to $targets instance(s) in $ENVIRONMENT"

# Deploying to zero instances must not look like success
if [[ "$targets" == "0" ]]; then
  echo "No instances matched tags App=api, Environment=$ENVIRONMENT" >&2
  exit 1
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
while :; do
  statuses="$(aws ssm list-command-invocations --command-id "$command_id" \
    --query 'CommandInvocations[].Status' --output text)"
  echo "statuses: ${statuses:-<none yet>}"
  if [[ -n "$statuses" ]] && ! grep -qE 'Pending|InProgress|Delayed' <<<"$statuses"; then
    break
  fi
  if ((SECONDS > deadline)); then
    echo "Timed out waiting for the deployment" >&2
    exit 1
  fi
  sleep 5
done

# Every targeted instance must have succeeded (max-errors 0 cancels the rest after a failure)
# The backticks below are JMESPath string literals, not shell command substitution.
# shellcheck disable=SC2016
ok="$(aws ssm list-command-invocations --command-id "$command_id" \
  --query 'length(CommandInvocations[?Status==`Success`])' --output text)"
if [[ "$ok" != "$targets" ]]; then
  echo "Deployment failed on $((targets - ok)) of $targets instance(s)" >&2
  # shellcheck disable=SC2016
  for id in $(aws ssm list-command-invocations --command-id "$command_id" \
    --query 'CommandInvocations[?Status!=`Success`].InstanceId' --output text); do
    echo "---- $id ----" >&2
    aws ssm get-command-invocation --command-id "$command_id" --instance-id "$id" \
      --query '[Status, StandardOutputContent, StandardErrorContent]' --output text >&2 || true
  done
  exit 1
fi
echo "Deployed $RELEASE_SHA to $ok/$targets instance(s) in $ENVIRONMENT"
