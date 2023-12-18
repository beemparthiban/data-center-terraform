#!/usr/bin/env bash
# This script manages to deploy the infrastructure for the Atlassian Data Center products
#
# Usage:  install.sh [-c <config_file>] [-f] [-h]
# -c <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided.
# -f : Auto-approve
# -h : provides help to how executing this script.
set -e
set -o pipefail
ROOT_PATH=$(cd $(dirname "${0}"); pwd)
SCRIPT_PATH="${ROOT_PATH}/scripts"
LOG_FILE="${ROOT_PATH}/logs/terraform-dc-install_$(date '+%Y-%m-%d_%H-%M-%S').log"
LOG_TAGGING="${ROOT_PATH}/logs/terraform-dc-asg-tagging_$(date '+%Y-%m-%d_%H-%M-%S').log"

ENVIRONMENT_NAME=
OVERRIDE_CONFIG_FILE=
DIFFERENT_ENVIRONMENT=1

source "${SCRIPT_PATH}/common.sh"

show_help(){
  if [ -n "${HELP_FLAG}" ]; then
cat << EOF
This script provisions the infrastructure for Atlassian Data Center products in AWS environment.
The infrastructure will be generated by terraform and state of the resources will be kept in a S3 bucket which will be provision by this script if is not existed.

Before installing the infrastructure make sure you have completed the configuration process and did all perquisites.
For more information visit https://github.com/atlassian-labs/data-center-terraform.
EOF

  fi
  echo
  echo "Usage:  ./install.sh [-c <config_file>] [-h]"
  echo "   -c <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided."
  echo "   -d : run cleanup.sh script at the beginning."
  echo "   -p : skip run pre-flight checks to test compatibility of EBS and RDS snapshots if any."
  echo "   -f : auto-approve terraform apply."
  echo "   -l : skip product license check."
  echo "   -h : provides help to how executing this script."
  echo
  exit 2
}

# Extract arguments
  CONFIG_FILE=
  HELP_FLAG=
  FORCE_FLAG=
  CLEAN_UP_FLAG=
  SKIP_PRE_FLIGHT_FLAG=
  SKIP_LICENSE_TEST_FLAG=
  while getopts hfdpl?c: name ; do
      case $name in
      h)    HELP_FLAG=1; show_help;;  # Help
      c)    CONFIG_FILE="${OPTARG}";; # Config file name to install - this overrides the default, 'config.tfvars'
      f)    FORCE_FLAG="-f";;         # Auto-approve
      d)    CLEAN_UP_FLAG="-d";;      # Run cleanup script before install
      p)    SKIP_PRE_FLIGHT_FLAG="-p";;    # Skip pre-flight checks to test compatibility of EBS and RDS snapshots if any
      l)    SKIP_LICENSE_TEST_FLAG="-l";;  # Skip license checks
      ?)    log "Invalid arguments." "ERROR" ; show_help
      esac
  done

  shift $((${OPTIND} - 1))
  UNKNOWN_ARGS="$*"

# Clean up before installation
if [ ! -z "${CLEAN_UP_FLAG}" ]; then
  bash "${SCRIPT_PATH}/cleanup.sh" -s -t -x -r .
fi

# Check for prerequisite tooling
# https://atlassian-labs.github.io/data-center-terraform/userguide/PREREQUISITES/
check_for_prerequisites() {
  declare -a tools=("aws" "helm" "terraform")
  for tool in "${tools[@]}"
  do :
    if ! command -v "${tool}" &>/dev/null; then
      log "The required dependency [${tool}] could not be found. Please make sure that it is installed before continuing." "ERROR"
      exit 1
    fi
  done
}

# Validate the arguments.
process_arguments() {
  # set the default value for config file if is not provided
  if [ -z "${CONFIG_FILE}" ]; then
    CONFIG_FILE="${ROOT_PATH}/config.tfvars"
  else
    if [[ ! -f "${CONFIG_FILE}" ]]; then
      log "Terraform configuration file '${CONFIG_FILE}' not found!" "ERROR"
      show_help
    fi
  fi
  CONFIG_ABS_PATH="$(cd "$(dirname "${CONFIG_FILE}")"; pwd)/$(basename "${CONFIG_FILE}")"
  OVERRIDE_CONFIG_FILE="-var-file=${CONFIG_ABS_PATH}"

  log "Terraform will use '${CONFIG_ABS_PATH}' to install the infrastructure."

  if [ -n "${UNKNOWN_ARGS}" ]; then
    log "Unknown arguments:  ${UNKNOWN_ARGS}" "ERROR"
    show_help
  fi
}

pre_flight_checks() {
  set +e
  PRODUCTS=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep "products" | sed 's/ //g')
  PRODUCTS="${PRODUCTS#*=}"
  PRODUCTS_ARRAY=($(echo $PRODUCTS | sed 's/\[//g' | sed 's/\]//g' | sed 's/,/ /g' | sed 's/"//g'))
  REGION=$(get_variable 'region' "${CONFIG_ABS_PATH}")

  if [ "${SKIP_LICENSE_TEST_FLAG}" == "" ]; then
    for PRODUCT in ${PRODUCTS_ARRAY[@]}; do
      log "Checking ${PRODUCT} license"
      LICENSE_ENV_VAR=${PRODUCT}'_license'
      LICENSE_TEXT=$(get_variable ${LICENSE_ENV_VAR} "${CONFIG_ABS_PATH}")
      if [ -z "$LICENSE_TEXT" ]; then
        log "License is undefined or malformed. Please check '${LICENSE_ENV_VAR}' value in '${CONFIG_ABS_PATH}'" "ERROR"
        log "It is possible that '${LICENSE_ENV_VAR}' is defined but it is a multi line string" "ERROR"
        log "If that's the case remove all new lines to convert it to a one-liner" "ERROR"
        exit 1
      fi
      if [ "${LICENSE_TEXT}" == ${PRODUCT}-license ]; then
        log "License placeholder is unchanged. Please check '${LICENSE_ENV_VAR}' value in '${CONFIG_ABS_PATH}'" "ERROR"
        log "Current license key: '${LICENSE_TEXT}'" "ERROR"
        log "Generate a new license at https://my.atlassian.com/" "ERROR"
        exit 1
      fi
    done
  fi

  for PRODUCT in ${PRODUCTS_ARRAY[@]}; do
    log "Starting pre-flight checks for ${PRODUCT}"
    SHARED_HOME_SNAPSHOT_VAR=$PRODUCT'_shared_home_snapshot_id'
    RDS_SNAPSHOT_VAR=$PRODUCT'_db_snapshot_id'
    PRODUCT_VERSION_VAR=$PRODUCT'_version_tag'
    PRODUCT_VERSION=$(get_variable ${PRODUCT_VERSION_VAR} "${CONFIG_ABS_PATH}")
    MAJOR_MINOR_VERSION=$(echo "$PRODUCT_VERSION" | cut -d '.' -f1-2)
    EBS_SNAPSHOT_ID=$(get_variable ${SHARED_HOME_SNAPSHOT_VAR} "${CONFIG_ABS_PATH}")
    DATASET_SIZE=$(get_variable ${PRODUCT}_dataset_size "${CONFIG_ABS_PATH}")
    if [ -z "$DATASET_SIZE" ]; then
      DATASET_SIZE="large"
    fi
    log "Dataset size is ${DATASET_SIZE}"
    SNAPSHOTS_JSON_FILE_PATH=$(get_variable 'snapshots_json_file_path' "${CONFIG_ABS_PATH}")
    if [ "${SNAPSHOTS_JSON_FILE_PATH}" ]; then
      EBS_SNAPSHOT_ID=$(cat ${SNAPSHOTS_JSON_FILE_PATH} | jq ".${PRODUCT}.versions[] | select(.version == \"${PRODUCT_VERSION}\") | .data[] | select(.size == \"${DATASET_SIZE}\" and .type == \"ebs\") | .snapshots[] | .[\"${REGION}\"]" | sed 's/"//g')
    fi
    if [ ! -z ${EBS_SNAPSHOT_ID} ]; then
      log "Checking EBS snapshot ${EBS_SNAPSHOT_ID} compatibility with ${PRODUCT} version ${PRODUCT_VERSION}"
      EBS_SNAPSHOT_DESCRIPTION=$(aws ec2 describe-snapshots --snapshot-ids=${EBS_SNAPSHOT_ID} --region ${REGION} --query 'Snapshots[0].Description')
      if [ -z ${EBS_SNAPSHOT_DESCRIPTION} ]; then
        log "****************FAILED TO GET EBS SNAPSHOT******************" "ERROR"
        log "Failed to describe EBS snapshot defined by $SHARED_HOME_SNAPSHOT_VAR" "ERROR"
        log "Please check if correct '${SHARED_HOME_SNAPSHOT_VAR}' variable is defined in tfvars config file" "ERROR"
        log "****************FAILED TO GET EBS SNAPSHOT******************" "ERROR"
        exit 1
      fi
      if [[ ! $EBS_SNAPSHOT_DESCRIPTION == *"dcapt"* ]]; then
        log "****************FAILED TO VALIDATE EBS DESCRIPTION**********" "ERROR"
        log "Failed to identify EBS snapshot defined in ${SHARED_HOME_SNAPSHOT_VAR} as the one created for 'DCAPT'" "ERROR"
        log "Please check if '${SHARED_HOME_SNAPSHOT_VAR}' variable has the correct value in tfvars config file" "ERROR"
        log "****************FAILED TO VALIDATE EBS DESCRIPTION**********" "ERROR"
        log "EBS snapshot '${EBS_SNAPSHOT_ID}' defined by ${SHARED_HOME_SNAPSHOT_VAR} has the following description:" "ERROR"
        aws ec2 describe-snapshots --snapshot-ids=${EBS_SNAPSHOT_ID} --region ${REGION} --query 'Snapshots[0].Description'
        exit 1
      fi
      EBS_SNAPSHOT_VERSION=$(echo ${EBS_SNAPSHOT_DESCRIPTION} | sed 's/-/./g' | sed 's/"//g' | cut -d '.' -f3-)
      if [[ "$EBS_SNAPSHOT_VERSION" == *"$MAJOR_MINOR_VERSION"* ]]; then
        log "EBS snapshot ${EBS_SNAPSHOT_ID} version ${EBS_SNAPSHOT_VERSION} is compatible with ${PRODUCT} version ${PRODUCT_VERSION}"
      else
        log "***************INCOMPATIBLE EBS SNAPSHOT USED***************" "ERROR"
        log "EBS snapshot ${EBS_SNAPSHOT_ID} version ${EBS_SNAPSHOT_VERSION} defined by '${SHARED_HOME_SNAPSHOT_VAR}' is not compatible with ${PRODUCT} version ${PRODUCT_VERSION}" "ERROR"
        log "Make sure you set $SHARED_HOME_SNAPSHOT_VAR variable to a snapshot ID compatible with ${PRODUCT} version ${PRODUCT_VERSION}" "ERROR"
        log "***************INCOMPATIBLE EBS SNAPSHOT USED***************" "ERROR"
        log "EBS snapshot that is currently defined:" "ERROR"
        aws ec2 describe-snapshots --snapshot-ids=${EBS_SNAPSHOT_ID} --region ${REGION}
        exit 1
      fi
    fi
    RDS_SNAPSHOT_ID=$(get_variable ${RDS_SNAPSHOT_VAR} "${CONFIG_ABS_PATH}")
    if [ "${SNAPSHOTS_JSON_FILE_PATH}" ]; then
      RDS_SNAPSHOT_ID=$(cat ${SNAPSHOTS_JSON_FILE_PATH} | jq ".${PRODUCT}.versions[] | select(.version == \"${PRODUCT_VERSION}\") | .data[] | select(.size == \"${DATASET_SIZE}\" and .type == \"rds\") | .snapshots[] | .[\"${REGION}\"]" | sed 's/"//g')
    fi
    if [ ! -z ${RDS_SNAPSHOT_ID} ]; then
      log "Checking RDS snapshot ${RDS_SNAPSHOT_ID} compatibility with ${PRODUCT} version ${PRODUCT_VERSION}"
      RDS_SNAPSHOT_VERSION=$(echo "${RDS_SNAPSHOT_ID}" | sed 's/.*dcapt-\(.*\)/\1/' | sed 's/-/./g' | cut -d '.' -f 2-)
      if [[ "$RDS_SNAPSHOT_VERSION" == *"$MAJOR_MINOR_VERSION"* ]]; then
        log "RDS snapshot '${RDS_SNAPSHOT_ID}' is compatible with ${PRODUCT} version ${PRODUCT_VERSION}"
      else
        log "***************INCOMPATIBLE RDS SNAPSHOT USED***************" "ERROR"
        log "RDS snapshot '${RDS_SNAPSHOT_ID}' defined by '${RDS_SNAPSHOT_VAR}' variable is created for ${PRODUCT} version ${RDS_SNAPSHOT_VERSION} while the requested ${PRODUCT} version is: ${PRODUCT_VERSION}" "ERROR"
        log "***************INCOMPATIBLE RDS SNAPSHOT USED***************" "ERROR"
        exit 1
      fi
    fi
  done
  set -e
}

# Make sure the infrastructure config file is existed and contains the valid data
verify_configuration_file() {
  log "Verifying the config file."

  HAS_VALIDATION_ERR=
  # Make sure the config values are defined
  set +e
  INVALID_CONTENT=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep '<\|>')
  set -e
  ENVIRONMENT_NAME=$(get_variable 'environment_name' "${CONFIG_ABS_PATH}")
  REGION=$(get_variable 'region' "${CONFIG_ABS_PATH}")

  if [ "${#ENVIRONMENT_NAME}" -gt 24 ]; then
    log "The environment name '${ENVIRONMENT_NAME}' is too long(${#ENVIRONMENT_NAME} characters)." "ERROR"
    log "Please make sure your environment name is less than 24 characters."
    HAS_VALIDATION_ERR=1
  fi

  SNAPSHOTS_JSON_FILE_PATH=$(get_variable 'snapshots_json_file_path' "${CONFIG_ABS_PATH}")
  if [ "${SNAPSHOTS_JSON_FILE_PATH}" ]; then
    if [ ! -e "${SNAPSHOTS_JSON_FILE_PATH}" ]; then
      log "Snapshots json file not found at ${SNAPSHOTS_JSON_FILE_PATH}"
      log "Please make sure 'snapshots_json_file_path' in ${CONFIG_ABS_PATH} points to an existing valid json file"
      HAS_VALIDATION_ERR=1
    fi
  fi

  if [ -n "${INVALID_CONTENT}" ]; then
    log "Configuration file '${CONFIG_ABS_PATH##*/}' is not valid." "ERROR"
    log "Terraform uses this file to generate customised infrastructure for '${ENVIRONMENT_NAME}' on your AWS account."
    log "Please modify '${CONFIG_ABS_PATH##*/}' using a text editor and complete the configuration. "
    log "Then re-run the install.sh to deploy the infrastructure."
    log "${INVALID_CONTENT}"
    HAS_VALIDATION_ERR=1
  fi
  INSTALL_BAMBOO=$(get_product "bamboo" "${CONFIG_ABS_PATH}")
  if [ -n "${INSTALL_BAMBOO}" ]; then
    # check license and admin password
    export POPULATED_LICENSE=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_license')
    export POPULATED_ADMIN_PWD=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_admin_password')

    if [ -z "${POPULATED_LICENSE}" ] && [ -z "${TF_VAR_bamboo_license}" ]; then
      log "License is missing. Please provide Bamboo license in config file, or export it to the environment variable 'TF_VAR_bamboo_license'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
    if [ -z "${POPULATED_ADMIN_PWD}" ] && [ -z "${TF_VAR_bamboo_admin_password}" ]; then
      log "Admin password is missing. Please provide Bamboo admin password in config file, or export it to the environment variable 'TF_VAR_bamboo_admin_password'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
  fi

  if [ -n "${HAS_VALIDATION_ERR}" ]; then
    log "There was a problem with the configuration file. Execution is aborted." "ERROR"
    exit 1
  fi
}

# Generates ./terraform-backend.tf and ./modules/tfstate/tfstate-local.tf using the content of local.tf and current aws account
generate_terraform_backend_variables() {
  log "'${ENVIRONMENT_NAME}' infrastructure deployment is started using '${CONFIG_ABS_PATH##*/}'."

  log "Terraform state backend/variable files are to be created."

  bash "${SCRIPT_PATH}/generate-variables.sh" -c "${CONFIG_ABS_PATH}" "${FORCE_FLAG}"
  S3_BUCKET=$(get_variable 'bucket' "${ROOT_PATH}/terraform-backend.tf")
}

# Create S3 bucket, bucket key, and dynamodb table to keep state and manage lock if they are not created yet
create_tfstate_resources() {
  # Check if the S3 bucket is existed otherwise create the bucket to keep the terraform state
  log "Checking the terraform state."
  if ! test -d "${ROOT_PATH}/logs" ; then
    mkdir "${ROOT_PATH}/logs"
  fi

  touch "${LOG_FILE}"
  local STATE_FOLDER="${ROOT_PATH}/modules/tfstate"
  set +e
  aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null
  S3_BUCKET_EXISTS=$?
  set -e
  if [ ${S3_BUCKET_EXISTS} -eq 0 ]
  then
    log "S3 bucket '${S3_BUCKET}' already exists."
  else
    # Check if the logging bucket exists otherwise stop the installation
    LOGGING_BUCKET=$(get_variable 'logging_bucket' "${CONFIG_ABS_PATH}")
    if [ -n "${LOGGING_BUCKET}" ]; then
      set +e
      aws s3api head-bucket --bucket "${LOGGING_BUCKET}" 2>/dev/null
      LOGGING_BUCKET_EXISTS=$?
      set -e
      if [ "${LOGGING_BUCKET_EXISTS}" -ne 0 ]; then
        log "The logging bucket '${LOGGING_BUCKET}' is not existed. Please create the bucket first." "ERROR"
        exit 1
      fi
    fi
    # create s3 bucket to be used for keep state of the terraform project
    log "Creating '${S3_BUCKET}' bucket for storing the terraform state..."
    if ! test -d "${STATE_FOLDER}/.terraform" ; then
      terraform -chdir="${STATE_FOLDER}" init -no-color | tee -a "${LOG_FILE}"
    fi
    terraform -chdir="${STATE_FOLDER}" apply -auto-approve "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
    sleep 5
  fi
}

# Deploy the infrastructure if is not created yet otherwise apply the changes to existing infrastructure
create_update_infrastructure() {
  log "Starting to analyze the infrastructure..."
  if [ -n "${DIFFERENT_ENVIRONMENT}" ]; then
    log "Migrating the terraform state to S3 bucket..."
    terraform -chdir="${ROOT_PATH}" init -migrate-state -no-color | tee -a "${LOG_FILE}"
    terraform -chdir="${ROOT_PATH}" init -no-color | tee -a "${LOG_FILE}"
  fi
  terraform -chdir="${ROOT_PATH}" apply -auto-approve -no-color "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
  terraform -chdir="${ROOT_PATH}" output -json > outputs.json
}

set_current_context_k8s() {
  local EKS_PREFIX="atlas-"
  local EKS_SUFFIX="-cluster"
  local EKS_CLUSTER_NAME=${EKS_PREFIX}${ENVIRONMENT_NAME}${EKS_SUFFIX}
  local EKS_CLUSTER="${EKS_CLUSTER_NAME:0:38}"
  CONTEXT_FILE="${ROOT_PATH}/kubeconfig_${EKS_CLUSTER}"

  aws eks update-kubeconfig --name "${EKS_CLUSTER}" --region "${REGION}" --kubeconfig ${CONTEXT_FILE}

  if [[ -f  "${CONTEXT_FILE}" ]]; then
    log "EKS Cluster ${EKS_CLUSTER} in region ${REGION} is ready to use."
    log "Kubernetes config file could be found at '${CONTEXT_FILE}'"
    # No need to update Kubernetes context when run by e2e test
    if [ -z "${FORCE_FLAG}" ]; then
      aws --region "${REGION}" eks update-kubeconfig --name "${EKS_CLUSTER}"
    fi
    # e2e test uses context file to connect to k8s and since aws-iam-authenticator 0.5.5 is using v1beta1 api version
    # for authentication, then we need to switch to v1beta1
    sed 's/client.authentication.k8s.io\/v1alpha1/client.authentication.k8s.io\/v1beta1/g' "${CONTEXT_FILE}" > tmp && mv tmp "${CONTEXT_FILE}"
  else
    log "Kubernetes context file '${CONTEXT_FILE}' could not be found."
  fi
}

resume_bamboo_server() {
  # Please note that if you import the dataset, make sure admin credential in config file (config.tfvars)
  # is matched with admin info stored in dataset you import.
  BAMBOO_DATASET=$(get_variable 'dataset_url' "${CONFIG_ABS_PATH}")
  INSTALL_BAMBOO=$(get_product "bamboo" "${CONFIG_ABS_PATH}")
  local SERVER_STATUS=

  # resume the server only if a dataset is imported
  if [ -n "${BAMBOO_DATASET}" ] && [ -n "${INSTALL_BAMBOO}" ]; then
    log "Resuming Bamboo server."

    ADMIN_USERNAME=$(get_variable 'bamboo_admin_username' "${CONFIG_ABS_PATH}")
    ADMIN_PASSWORD=$(get_variable 'bamboo_admin_password' "${CONFIG_ABS_PATH}")
    if [ -z "${ADMIN_USERNAME}" ]; then
      ADMIN_USERNAME="${TF_VAR_bamboo_admin_username}"
    fi
    if [ -z "${ADMIN_PASSWORD}" ]; then
      ADMIN_PASSWORD="${TF_VAR_bamboo_admin_password}"
    fi
    if [ -z "${ADMIN_USERNAME}" ]; then
      read -p "Please enter the bamboo administrator username: " ADMIN_USERNAME
    fi
    if [ -n "${ADMIN_USERNAME}" ]; then
      if [ -z "${ADMIN_PASSWORD}" ]; then
        echo "Please enter password of the Bamboo '${ADMIN_USERNAME}' user: "
        read -s ADMIN_PASSWORD
      fi

      bamboo_url=$(terraform output | grep '"bamboo" =' | sed -nE 's/^.*"(.*)".*$/\1/p')

      status_url="${bamboo_url}/rest/api/latest/status"
      local RESULT=$(curl -s "${status_url}")
      if [[ "x${RESULT}" == *"RUNNING"* ]]; then
        log "Bamboo server is already ${RESULT}, skip resuming."
        return
      fi

      resume_bamboo_url="${bamboo_url}/rest/api/latest/server/resume"
      local RESULT=$(curl -s -u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" -X POST "${resume_bamboo_url}")
      if [[ "x${RESULT}" == *"RUNNING"* ]]; then
        SERVER_STATUS="RUNNING"
        log "Bamboo server was resumed and it is running successfully."
      elif [ "x${RESULT}" == *"AUTHENTICATED_FAILED"* ]; then
        log "The provided admin username and password is not matched with the credential stored in the dataset." "ERROR"
      else
        log "Unexpected state when resuming Bamboo server, state: ${RESULT}" "ERROR"
      fi
    fi
    if [ -z $SERVER_STATUS ]; then
      log "We were not able to login into the Bamboo software to resume the server." "WARN"
      log "Please login into the Bamboo and 'RESUME' the server before start using the product."
    fi
  fi
}

# Update the current load balancer listener on port 7999 to use the TCP protocol
enable_ssh_tcp_protocol_on_lb_listener() {
  readonly SSH_TCP_PORT="7999"
  local install_bitbucket
  local region
  local load_balancer_dns
  local load_balancer_name
  local original_instance_port

  install_bitbucket=$(get_product "bitbucket" "${CONFIG_ABS_PATH}")

  if [ -n "${install_bitbucket}" ]; then
    region=$(get_variable 'region' "${CONFIG_ABS_PATH}")
    load_balancer_dns=$(terraform output | grep '"load_balancer_hostname" =' | sed -nE 's/^.*"(.*)".*$/\1/p')
    load_balancer_name=$(echo "${load_balancer_dns}" | cut -d '-' -f 1)
    original_instance_port=$(aws elb describe-load-balancers --load-balancer-name ${load_balancer_name} --query 'LoadBalancerDescriptions[*].ListenerDescriptions[?Listener.LoadBalancerPort==`'"${SSH_TCP_PORT}"'`].Listener[].InstancePort | [0]' --region "${region}")

    log "Enabling SSH connectivity for Bitbucket. Updating load balancer [${load_balancer_dns}] listener protocol from HTTP to TCP on port ${SSH_TCP_PORT}..."
    describe_lb_listener "${load_balancer_name}" "${region}"

    # delete the current listener for port 7999 and re-create but using the TCP protocol instead
    if delete_lb_listener "${load_balancer_name}" "${region}" && create_lb_listener "${load_balancer_name}" "${original_instance_port}" "${region}"; then
      log "Load balancer listener protocol updated for ${load_balancer_dns}."
      describe_lb_listener "${load_balancer_name}" "${region}"
    else
      log "ERROR! There was an issue updating the load balancer [${load_balancer_dns}] listener protocol from HTTP to TCP on port ${SSH_TCP_PORT}. You may want to do this manually via the AWS Console."
    fi
  fi
}

# Check for prerequisite tooling
check_for_prerequisites

# Process the arguments
process_arguments

# Verify the configuration file
verify_configuration_file

if [ "${SKIP_PRE_FLIGHT_FLAG}" == "" ]; then
  # verify snapshots if any
  pre_flight_checks
fi

# Generates ./terraform-backend.tf and ./modules/tfstate/tfstate-local.tf
generate_terraform_backend_variables

# Create S3 bucket and dynamodb table to keep state
create_tfstate_resources

# Deploy the infrastructure
create_update_infrastructure

# Resume bamboo server if the credential is provided
resume_bamboo_server

# Print information about manually adding the new k8s context
set_current_context_k8s

# To allow SSH connectivity for Bitbucket update the Load Balancer protocol for listener port 7999
enable_ssh_tcp_protocol_on_lb_listener

# Show the list of installed Helm charts
helm list --namespace atlassian
