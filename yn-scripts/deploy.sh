#!/usr/bin/env bash
set -e
set -o pipefail

aws_region=eu-west-1
env_name=$1

instance_name="Publicaffairs $env_name"
container_name=superset-$env_name
# container_port=8088
superset_secret_id=publicaffairs-superset-$env_name
repo=git@github.com:yn-plus/publicaffairs-superset.git
repo_branch=publicaffairs-4-1-1

echo "aws region is $aws_region"
echo "environment is $env_name"
echo "instance name is $instance_name"
echo "container name is $container_name"
# echo "container port is $container_port"
echo "superset secret id is $superset_secret_id"
echo "repo is $repo"
echo "repo branch is $repo_branch"


if ! SECRET_BLOB=$(aws secretsmanager get-secret-value --secret-id "$superset_secret_id" --query SecretString --output text --region "$aws_region"); then
    echo "Failed to fetch Superset secrets"
    exit 1
fi
DATABASE_PASSWORD=$(echo $SECRET_BLOB | jq -r '.DATABASE_PASSWORD')
POSTGRES_PASSWORD=$(echo $SECRET_BLOB | jq -r '.POSTGRES_PASSWORD')
SUPERSET_SECRET_KEY=$(echo $SECRET_BLOB | jq -r '.SUPERSET_SECRET_KEY')
if [[ -z $DATABASE_PASSWORD || -z $DATABASE_PASSWORD || -z $SUPERSET_SECRET_KEY ]]; then
  echo "Some Superset secrets are missing (check AWS SecretManager permissions)."
  exit 1
fi

# validations

if [[ -z $aws_region ]]; then
  echo "You need to provide a region (eu-west1, ...)"
  exit 1
fi

if [[ -z $env_name ]]; then
  echo "You need to provide a env name (prod, staging)"
  exit 1
fi

function listInstances() {
  instanceIds=`aws ec2 describe-instances --region $aws_region --filters "Name=tag:Name,Values=$instance_name" "Name=instance-state-name,Values=running" | jq -c -r '.Reservations[].Instances[].InstanceId'`
  instances=( )
  for id in $instanceIds; do
    instances+=($id)
  done
}


function deploy() {
  echo "\n=> Deploying to $instance_name instances"
  total=${#instances[@]}
  i=1

  # clonar el repo
  # elegir la rama
  # compose up --build
  for instance in "${instances[@]}"; do
    echo "Deploying to: $instance - ($i/$total)";
    COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceIds,Values=$instance" \
    --region "$aws_region" \
    --parameters "commands=[
      'cd /home/ubuntu',
      'sudo -u ubuntu cd publicaffairs-superset || true',
      'sudo -u ubuntu docker compose -f docker-compose-non-dev.yml down || true',
      'sudo -u ubuntu docker system prune -a -f',
      'sudo -u ubuntu docker rm -rf publicaffairs-superset',
      'sudo -u ubuntu git clone $repo',
      'sudo -u ubuntu cd publicaffairs-superset',
      'sudo -u ubuntu git checkout $repo_branch',
      'sudo -u ubuntu \
        DATABASE_PASSWORD=$DATABASE_PASSWORD \
        POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
        SUPERSET_SECRET_KEY=$SUPERSET_SECRET_KEY \
        docker compose -f docker-compose-non-dev.yml up --build',
    ]" \
    --query 'Command.CommandId' --output text)
    echo "SSM command is running with ID: $COMMAND_ID"

    # wait until command is finished
    until [ $(aws ssm get-command-invocation --instance-id "$instance" --command-id "$COMMAND_ID" --query 'Status' --output text) != "InProgress" ]; do
      echo "SSM command is still running!"
      sleep 1
    done

    # log the output of the command
    echo "SSM command result:"
    aws ssm get-command-invocation --instance-id "$instance" --command-id "$COMMAND_ID" --query 'StandardOutputContent' --no-cli-pager --output text
    aws ssm get-command-invocation --instance-id "$instance" --command-id "$COMMAND_ID" --query 'StandardErrorContent' --no-cli-pager --output text

    # get the exit code of the command
    COMMAND_EXIT_CODE=$(aws ssm get-command-invocation --instance-id "$instance" --command-id "$COMMAND_ID" --query 'ResponseCode' --output text)
    echo "SSM command on $instance exited with exit code ${COMMAND_EXIT_CODE}"
    if [ $COMMAND_EXIT_CODE -ne 0 ]; then
      exit $COMMAND_EXIT_CODE
    fi
    let "i++"
  done
}



# case $env_name in
#   prod)
#     web_url='https://ynsights-hub.com'
#     ;;
#   staging)
#     web_url='https://staging.ynsights-hub.com'
#     ;;
#   *)
#     echo "Invalid environment name: $env_name. Must be 'production' or 'staging'"
#     exit 1
#     ;;
# esac

echo "=> Deploying $docker_image to $instance_name instances"
listInstances
deploy
