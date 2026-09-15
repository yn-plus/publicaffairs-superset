#!/usr/bin/env bash

set -euo pipefail

readonly SSM_POLL_INTERVAL_SECONDS=5
readonly SSM_COMMAND_TIMEOUT_SECONDS=1800
readonly SSM_COMMAND_RESULT_GRACE_SECONDS=30

log() {
  echo "[$(date --iso-8601=seconds)] $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

find_instance() {
  local aws_region=$1
  local instance_ids
  local -a instances

  instance_ids=$(aws ec2 describe-instances \
    --region "$aws_region" \
    --filters \
      'Name=tag:Name,Values=publicaffairs-production' \
      'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  read -r -a instances <<< "$instance_ids"
  if [[ ${#instances[@]} -ne 1 ]]; then
    fail "Expected one running instance named publicaffairs-production, found ${#instances[@]}"
  fi

  INSTANCE_ID=${instances[0]}
}

run_ssm_command() {
  local aws_region=$1
  local comment=$2
  local remote_command=$3
  local bash_remote_command
  local command_parameters
  local command_id
  local elapsed=0
  local invocation
  local status
  local status_details

  # AWS-RunShellScript does not guarantee Bash as its interpreter. Keep the
  # deployment body inside an explicitly invoked Bash process because it uses
  # Bash features such as arrays, [[ ... ]], and set -o pipefail.
  bash_remote_command=$(printf \
    "/bin/bash -s -- <<'PUBLIC_AFFAIRS_SUPERSET_REMOTE_SCRIPT'\\n%s\\nPUBLIC_AFFAIRS_SUPERSET_REMOTE_SCRIPT\\n" \
    "$remote_command")

  command_parameters=$(jq -n \
    --arg command "$bash_remote_command" \
    --arg timeout "$SSM_COMMAND_TIMEOUT_SECONDS" \
    '{commands: [$command], executionTimeout: [$timeout]}')

  command_id=$(aws ssm send-command \
    --region "$aws_region" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "$comment" \
    --parameters "$command_parameters" \
    --query 'Command.CommandId' \
    --output text)

  log "SSM command started: ${command_id} on ${INSTANCE_ID}"

  while ((elapsed <= SSM_COMMAND_TIMEOUT_SECONDS + SSM_COMMAND_RESULT_GRACE_SECONDS)); do
    if invocation=$(aws ssm get-command-invocation \
      --region "$aws_region" \
      --command-id "$command_id" \
      --instance-id "$INSTANCE_ID" \
      --output json 2>/dev/null); then
      status=$(jq -r '.Status' <<< "$invocation")
      status_details=$(jq -r '.StatusDetails' <<< "$invocation")

      case "$status" in
        Success)
          jq -r '.StandardOutputContent' <<< "$invocation"
          return 0
          ;;
        Cancelled|Failed|TimedOut)
          jq -r '.StandardOutputContent' <<< "$invocation"
          jq -r '.StandardErrorContent' <<< "$invocation" >&2
          fail "SSM command ${command_id} ${status_details}"
          ;;
      esac
    fi

    sleep "$SSM_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + SSM_POLL_INTERVAL_SECONDS))
  done

  fail "Timed out waiting for SSM command ${command_id}"
}

AWS_REGION=${1:-}
INFRASTRUCTURE_ENVIRONMENT=${2:-}
ARTIFACT_BUCKET=${3:-}
ARTIFACT_KEY=${4:-}
ARTIFACT_SHA256=${5:-}
SUPERSET_RELEASE_REVISION=${6:-}

[[ -n "$AWS_REGION" ]] || fail "Missing AWS region"
[[ "$INFRASTRUCTURE_ENVIRONMENT" = production ]] || fail "Superset is deployed only to production"
[[ -n "$ARTIFACT_BUCKET" ]] || fail "Missing artifact bucket"
[[ "$SUPERSET_RELEASE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid Superset release revision"
[[ "$ARTIFACT_KEY" = "releases/superset/${SUPERSET_RELEASE_REVISION}/superset-source.tar.gz" ]] || \
  fail "Unexpected Superset artifact key"
[[ "$ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid Superset artifact checksum"

find_instance "$AWS_REGION"

remote_command=$(cat <<EOF
set -euo pipefail

AWS_REGION='${AWS_REGION}'
ARTIFACT_BUCKET='${ARTIFACT_BUCKET}'
ARTIFACT_KEY='${ARTIFACT_KEY}'
ARTIFACT_SHA256='${ARTIFACT_SHA256}'
SUPERSET_RELEASE_REVISION='${SUPERSET_RELEASE_REVISION}'
SUPERSET_RUNTIME_SECRETS_PARAMETER_NAME='/production/public-affairs/superset-runtime-secrets'
SUPERSET_RELEASES_DIRECTORY='/home/ubuntu/superset/releases'
SUPERSET_CURRENT_RELEASE_FILE='/opt/public-affairs/superset/current-release-revision'
SUPERSET_PREVIOUS_RELEASE_FILE='/opt/public-affairs/superset/previous-release-revision'
LEGACY_SUPERSET_DIRECTORY='/home/ubuntu/superset'
NETWORK_NAME='publicaffairs-network'

wait_for_superset() {
  local attempts=0

  while [ "\$attempts" -lt 30 ]; do
    if curl --fail --silent --show-error http://127.0.0.1:8088/health >/dev/null; then
      return 0
    fi

    attempts=\$((attempts + 1))
    sleep 2
  done

  return 1
}

wait_for_init() {
  local attempts=0
  local state
  local exit_code

  while [ "\$attempts" -lt 150 ]; do
    state=\$(docker inspect --format '{{.State.Status}}' superset_init 2>/dev/null || true)
    if [ "\$state" = exited ]; then
      exit_code=\$(docker inspect --format '{{.State.ExitCode}}' superset_init)
      [ "\$exit_code" = 0 ]
      return
    fi

    if [ "\$state" != running ] && [ "\$state" != created ] && \
      [ "\$state" != restarting ]; then
      return 1
    fi

    attempts=\$((attempts + 1))
    sleep 2
  done

  return 1
}

container_is_running() {
  [ "\$(docker inspect --format '{{.State.Running}}' "\$1" 2>/dev/null || true)" = true ]
}

ensure_superset_network() {
  docker network inspect "\$NETWORK_NAME" >/dev/null

  if ! docker network inspect "\$NETWORK_NAME" \
    --format '{{range .Containers}}{{.Name}}{{"\\n"}}{{end}}' | grep -Fxq superset_app; then
    docker network connect "\$NETWORK_NAME" superset_app
  fi
}

compose_for_release() {
  local release_directory=\$1
  shift

  docker compose \
    --project-name superset \
    --project-directory "\$release_directory" \
    -f "\$release_directory/docker-compose-non-dev.yml" \
    -f "\$release_directory/yn-scripts/docker-compose-non-dev.override.yml" \
    "\$@"
}

image_is_used_by_container() {
  local image_id=\$1
  local container_id

  for container_id in \$(docker ps -aq); do
    if [ "\$(docker inspect --format '{{.Image}}' "\$container_id")" = "\$image_id" ]; then
      return 0
    fi
  done

  return 1
}

image_is_dangling() {
  docker image ls --filter dangling=true --no-trunc --format '{{.ID}}' | grep -Fqx "\$1"
}

image_references=(
  'superset-superset:latest'
  'superset-superset-init:latest'
  'superset-superset-worker:latest'
  'superset-superset-worker-beat:latest'
)
old_image_ids=()
candidate_image_ids=()
old_image_ids_captured=false
candidate_image_ids_captured=false
candidate_init_started=false

capture_image_ids() {
  local target_array_name=\$1
  local image_reference
  local image_id
  local -n target_array="\$target_array_name"

  target_array=()
  for image_reference in "\${image_references[@]}"; do
    image_id=\$(docker image inspect "\$image_reference" --format '{{.Id}}' 2>/dev/null || true)
    target_array+=("\$image_id")
  done
}

restore_old_image_references() {
  local index
  local image_reference
  local image_id

  for index in "\${!image_references[@]}"; do
    image_reference="\${image_references[\$index]}"
    image_id="\${old_image_ids[\$index]}"

    if [ -n "\$image_id" ]; then
      docker tag "\$image_id" "\$image_reference" || \
        echo "WARNING: Could not restore Superset image reference \$image_reference" >&2
    else
      docker image rm "\$image_reference" >/dev/null 2>&1 || true
    fi
  done
}

remove_unused_dangling_images() {
  local image_id

  for image_id in "\$@"; do
    [ -n "\$image_id" ] || continue
    docker image inspect "\$image_id" >/dev/null 2>&1 || continue

    if image_is_used_by_container "\$image_id"; then
      continue
    fi

    if image_is_dangling "\$image_id"; then
      docker image rm "\$image_id" >/dev/null || \
        echo "WARNING: Could not remove displaced Superset image \$image_id" >&2
    fi
  done
}

write_environment_file() {
  local release_directory=\$1
  local secret_blob
  local database_password
  local postgres_password
  local superset_secret_key

  if ! secret_blob=\$(aws ssm get-parameter \
    --name "\$SUPERSET_RUNTIME_SECRETS_PARAMETER_NAME" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text \
    --region "\$AWS_REGION"); then
    echo "ERROR: Could not read Superset runtime parameter \$SUPERSET_RUNTIME_SECRETS_PARAMETER_NAME" >&2
    return 1
  fi

  if ! database_password=\$(jq -er '.DATABASE_PASSWORD | strings | select(length > 0)' <<< "\$secret_blob"); then
    echo 'ERROR: Superset runtime secret is missing DATABASE_PASSWORD' >&2
    return 1
  fi
  if ! postgres_password=\$(jq -er '.POSTGRES_PASSWORD | strings | select(length > 0)' <<< "\$secret_blob"); then
    echo 'ERROR: Superset runtime secret is missing POSTGRES_PASSWORD' >&2
    return 1
  fi
  if ! superset_secret_key=\$(jq -er '.SUPERSET_SECRET_KEY | strings | select(length > 0)' <<< "\$secret_blob"); then
    echo 'ERROR: Superset runtime secret is missing SUPERSET_SECRET_KEY' >&2
    return 1
  fi

  umask 077
  {
    printf 'DATABASE_PASSWORD=%s\\n' "\$database_password"
    printf 'POSTGRES_PASSWORD=%s\\n' "\$postgres_password"
    printf 'SUPERSET_SECRET_KEY=%s\\n' "\$superset_secret_key"
    printf '%s\\n' 'SERVER_WORKER_AMOUNT=2'
    printf '%s\\n' 'DEV_MODE=false'
    printf '%s\\n' 'FLASK_DEBUG=false'
    printf '%s\\n' 'SUPERSET_ENV=production'
    printf '%s\\n' 'SUPERSET_LOAD_EXAMPLES=no'
    printf '%s\\n' 'SUPERSET_CONFIG_PATH=/app/docker/superset_config.py'
  } > "\$release_directory/docker-compose.env"
  unset secret_blob database_password postgres_password superset_secret_key
}

cleanup_release_directories() {
  local current_revision=\$1
  local previous_revision=\$2
  local release_directory
  local release_name

  for release_directory in "\$SUPERSET_RELEASES_DIRECTORY"/*; do
    [ -d "\$release_directory" ] || continue
    release_name=\$(basename "\$release_directory")
    if [ "\$release_name" != "\$current_revision" ] && \
      [ "\$release_name" != "\$previous_revision" ]; then
      rm -rf -- "\$release_directory"
    fi
  done
}

for required_container in superset_db superset_cache; do
  if ! container_is_running "\$required_container"; then
    echo "ERROR: \$required_container is not running before Superset deployment" >&2
    exit 1
  fi
done

mkdir -p "\$SUPERSET_RELEASES_DIRECTORY"
work_directory=\$(mktemp -d "\$SUPERSET_RELEASES_DIRECTORY/.staging.XXXXXX")
release_directory="\$SUPERSET_RELEASES_DIRECTORY/\$SUPERSET_RELEASE_REVISION"
staged_release_directory="\$work_directory/release"
active_revision=''
previous_revision=''
active_release_directory=''
deployment_started=false
deployment_succeeded=false

if [ -f "\$SUPERSET_CURRENT_RELEASE_FILE" ]; then
  active_revision=\$(tr -d '\\r\\n' < "\$SUPERSET_CURRENT_RELEASE_FILE")
  [[ "\$active_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'ERROR: Stored Superset release revision is invalid' >&2
    exit 1
  }
  active_release_directory="\$SUPERSET_RELEASES_DIRECTORY/\$active_revision"
  [ -d "\$active_release_directory" ] || {
    echo 'ERROR: Stored Superset release directory is missing' >&2
    exit 1
  }
fi

if [ -f "\$SUPERSET_PREVIOUS_RELEASE_FILE" ]; then
  previous_revision=\$(tr -d '\\r\\n' < "\$SUPERSET_PREVIOUS_RELEASE_FILE")
  [[ "\$previous_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'ERROR: Stored previous Superset release revision is invalid' >&2
    exit 1
  }
fi

cleanup() {
  if [ "\$deployment_succeeded" != true ]; then
    if [ "\$old_image_ids_captured" = true ]; then
      restore_old_image_references
    fi

    if [ "\$deployment_started" = true ]; then
      echo 'Restoring the previous Superset service containers'

      if [ -n "\$active_release_directory" ]; then
        compose_for_release "\$active_release_directory" \
          up --no-deps --force-recreate -d superset superset-worker superset-worker-beat || \
          echo 'CRITICAL: Could not restore the previous Superset release' >&2
      elif [ -d "\$LEGACY_SUPERSET_DIRECTORY" ]; then
        compose_for_release "\$LEGACY_SUPERSET_DIRECTORY" \
          up --no-deps --force-recreate -d superset superset-worker superset-worker-beat || \
          echo 'CRITICAL: Could not restore the legacy Superset release' >&2
      else
        echo 'CRITICAL: No previous Superset release is available for rollback' >&2
      fi

      ensure_superset_network || \
        echo 'CRITICAL: Could not reconnect the restored Superset container to Caddy' >&2
    fi

    if [ "\$candidate_init_started" = true ]; then
      docker rm -f superset_init >/dev/null 2>&1 || true
    fi
    if [ "\$candidate_image_ids_captured" = true ]; then
      remove_unused_dangling_images "\${candidate_image_ids[@]}"
    fi

    if [ "\$release_directory" != "\$active_release_directory" ] && \
      [ "\$release_directory" != "\$SUPERSET_RELEASES_DIRECTORY/\$previous_revision" ]; then
      rm -rf -- "\$release_directory"
    fi
  fi

  rm -rf "\$work_directory"
}

trap cleanup EXIT

if [ "\$active_revision" = "\$SUPERSET_RELEASE_REVISION" ] && wait_for_superset; then
  echo 'Superset release already active; no deployment changes were needed'
  deployment_succeeded=true
  exit 0
fi

aws s3 cp "s3://\$ARTIFACT_BUCKET/\$ARTIFACT_KEY" "\$work_directory/superset-source.tar.gz" \
  --region "\$AWS_REGION" \
  --only-show-errors
echo "\$ARTIFACT_SHA256  \$work_directory/superset-source.tar.gz" | sha256sum --check --status

mkdir -p "\$staged_release_directory"
tar -xzf "\$work_directory/superset-source.tar.gz" \
  --strip-components=1 \
  -C "\$staged_release_directory"
[ -f "\$staged_release_directory/Dockerfile" ]
[ -f "\$staged_release_directory/docker-compose-non-dev.yml" ]
[ -f "\$staged_release_directory/yn-scripts/docker-compose-non-dev.override.yml" ]
[ -f "\$staged_release_directory/yn-scripts/superset_config.py" ]

cp "\$staged_release_directory/yn-scripts/superset_config.py" \
  "\$staged_release_directory/docker/superset_config.py"
write_environment_file "\$staged_release_directory"
compose_for_release "\$staged_release_directory" config -q

rm -rf -- "\$release_directory"
mv "\$staged_release_directory" "\$release_directory"

capture_image_ids old_image_ids
old_image_ids_captured=true
for service in superset superset-init superset-worker superset-worker-beat; do
  compose_for_release "\$release_directory" build "\$service"
done
capture_image_ids candidate_image_ids
candidate_image_ids_captured=true

candidate_init_started=true
compose_for_release "\$release_directory" \
  up --no-deps --force-recreate -d superset-init
wait_for_init

deployment_started=true
compose_for_release "\$release_directory" \
  up --no-deps --force-recreate -d superset superset-worker superset-worker-beat
ensure_superset_network
wait_for_superset

if [ -n "\$active_revision" ]; then
  printf '%s\\n' "\$active_revision" > "\$work_directory/previous-release-revision"
  mv "\$work_directory/previous-release-revision" "\$SUPERSET_PREVIOUS_RELEASE_FILE"
  previous_revision="\$active_revision"
else
  rm -f "\$SUPERSET_PREVIOUS_RELEASE_FILE"
  previous_revision=''
fi

printf '%s\\n' "\$SUPERSET_RELEASE_REVISION" > "\$work_directory/current-release-revision"
mv "\$work_directory/current-release-revision" "\$SUPERSET_CURRENT_RELEASE_FILE"

remove_unused_dangling_images "\${old_image_ids[@]}"
cleanup_release_directories "\$SUPERSET_RELEASE_REVISION" "\$previous_revision"
deployment_succeeded=true
echo 'Superset deployment completed'
EOF
)

run_ssm_command \
  "$AWS_REGION" \
  "Deploy Superset release ${SUPERSET_RELEASE_REVISION}" \
  "$remote_command"
