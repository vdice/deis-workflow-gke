#!/bin/bash
set -eo pipefail

install() {
  # get k8s cluster name
  cluster

  # get lastest macOS helmc cli version
  install_helmc "$(which helmc)"

  # get lastest macOS workflow cli version
  install_deis "$(which deis)"

  # add Deis Chart repo
  echo "Adding Deis Chart repository ... "
  helmc repo add deis https://github.com/deis/charts || true
  # get the latest version of all Charts from all repos
  echo " "
  echo "Get the latest version of all Charts from all repos ... "
  helmc up

  # get latest Workflow version
  echo " "
  echo "Getting latest Deis Workflow version ..."
  WORKFLOW_RELEASE="${DESIRED_WORKFLOW_RELEASE:-$(ls ~/.helmc/cache/deis | grep workflow-v2. | grep -v -e2e | sort -rn | head -1 | cut -d'-' -f2)}"
  echo "Got Deis Workflow ${WORKFLOW_RELEASE} ..."

  # delete the old folder if such exists
  rm -rf ~/.helmc/workspace/charts/workflow-${WORKFLOW_RELEASE}-${K8S_NAME} > /dev/null 2>&1

  # fetch Deis Workflow Chart to your helmc's working directory
  echo " "
  echo "Fetching Deis Workflow Chart to your helmc's working directory ..."
  helmc fetch deis/workflow-${WORKFLOW_RELEASE} workflow-${WORKFLOW_RELEASE}-${K8S_NAME}

  set_database
  set_object_storage
  set_registry

  # generate manifests
  echo " "
  echo "Generating Workflow ${WORKFLOW_RELEASE}-${K8S_NAME} manifests ..."
  helmc generate -x manifests -f workflow-${WORKFLOW_RELEASE}-${K8S_NAME}

  # install Workflow
  echo " "
  chart_to_install="workflow-${WORKFLOW_RELEASE}-${K8S_NAME}"
  echo "Installing Workflow chart '${chart_to_install}'..."
  helmc install "${chart_to_install}"

  # Waiting for Deis Workflow to be ready
  wait_for_workflow "${MAX_TIMEOUT_SECS}"

  # get router's external IP
  echo " "
  echo "Fetching Router's LB external IP:"
  LB_IP=$(kubectl --namespace=deis get svc | grep [d]eis-router | awk '{ print $3 }')
  echo "$LB_IP"

  echo " "
  echo "Workflow install ${WORKFLOW_RELEASE} is done ..."
  echo "Workflow chart installed: ${chart_to_install}"
  echo " "
}

upgrade() {
  # make temp directory for storing/fetching secrets
  tmp_dir="$(mktemp -d)"

  # get k8s cluster name
  cluster

  # get lastest macOS helmc cli version
  install_helmc "$(which helmc)"

  # get lastest macOS workflow cli version
  install_deis "$(which deis)"

  # get the latest version of all Charts from all repos
  echo " "
  echo "Get the latest version of all Charts from all repos ... "
  helmc up
  echo " "

  # Fetch the current database credentials
  echo " "
  echo "Fetching the current database credentials ..."
  kubectl --namespace=deis get secret database-creds -o yaml > "${tmp_dir}"/active-deis-database-secret-creds.yaml

  # Fetch the builder component ssh keys
  echo " "
  echo "Fetching the builder component ssh keys ..."
  kubectl --namespace=deis get secret builder-ssh-private-keys -o yaml > "${tmp_dir}"/active-deis-builder-secret-ssh-private-keys.yaml

  # export environment variables for the previous and latest Workflow versions
  export PREVIOUS_WORKFLOW_RELEASE="${PREVIOUS_WORKFLOW_RELEASE:-$(cat "${tmp_dir}"/active-deis-builder-secret-ssh-private-keys.yaml | grep chart.helm.sh/version: | awk '{ print $2 }')}"
  echo "PREVIOUS_WORKFLOW_RELEASE set to '${PREVIOUS_WORKFLOW_RELEASE}'"

  export DESIRED_WORKFLOW_RELEASE="${DESIRED_WORKFLOW_RELEASE:-$(ls ~/.helmc/cache/deis | grep workflow-v2. | grep -v -e2e | sort -rn | head -1 | cut -d'-' -f2)}"
  echo "DESIRED_WORKFLOW_RELEASE set to '${DESIRED_WORKFLOW_RELEASE}'"

  # delete the old chart folder if such exists
  rm -rf ~/.helmc/workspace/charts/workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME} > /dev/null 2>&1

  # Fetching the old chart copy from the chart cache into the helmc workspace for customization
  echo " "
  echo "Fetching deis/workflow-${PREVIOUS_WORKFLOW_RELEASE} chart to your helmc's working directory as workflow-${PREVIOUS_WORKFLOW_RELEASE}-${K8S_NAME}..."
  helmc fetch deis/workflow-${PREVIOUS_WORKFLOW_RELEASE} workflow-${PREVIOUS_WORKFLOW_RELEASE}-${K8S_NAME}

  # Fetching the new chart copy from the chart cache into the helmc workspace for customization
  echo " "
  echo "Fetching deis/workflow-${DESIRED_WORKFLOW_RELEASE} chart to your helmc's working directory as workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}..."
  helmc fetch deis/workflow-${DESIRED_WORKFLOW_RELEASE} workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}

  set_database
  set_object_storage
  set_registry

  # Generate templates for old chart
  echo " "
  echo "Fetching Deis Workflow Chart to your helmc's working directory ..."
  helmc generate -x manifests -f workflow-${PREVIOUS_WORKFLOW_RELEASE}-${K8S_NAME}

  # Generate templates for the new release
  echo " "
  echo "Generating Workflow ${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME} manifests ..."
  helmc generate -x manifests -f workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}

  # Copy your active database secrets into the helmc workspace for the desired version
  cp -f "${tmp_dir}"/active-deis-database-secret-creds.yaml \
    $(helmc home)/workspace/charts/workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}/manifests/deis-database-secret-creds.yaml

  # Copy your active builder ssh keys into the helmc workspace for the desired version
  cp -f "${tmp_dir}"/active-deis-builder-secret-ssh-private-keys.yaml \
    $(helmc home)/workspace/charts/workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}/manifests/deis-builder-secret-ssh-private-keys.yaml

  # Uninstall Workflow
  echo " "
  echo "Uninstalling Workflow ${PREVIOUS_WORKFLOW_RELEASE} ... "
  helmc uninstall workflow-${PREVIOUS_WORKFLOW_RELEASE}-${K8S_NAME} -n deis

  sleep 3

  # Install of latest Workflow release
  echo " "
  chart_to_install="workflow-${DESIRED_WORKFLOW_RELEASE}-${K8S_NAME}"
  echo "Installing Workflow chart '${chart_to_install}'..."
  helmc install "${chart_to_install}"

  # Waiting for Deis Workflow to be ready
  wait_for_workflow "${MAX_TIMEOUT_SECS}"

  echo " "
  echo "Workflow upgrade to ${DESIRED_WORKFLOW_RELEASE} is done ..."
  echo "Workflow chart installed: ${chart_to_install}"
  echo " "
}

set_database() {
  DATABASE_LOCATION="${DATABASE_LOCATION:-on-cluster}"

  if [ "${DATABASE_LOCATION}" == 'off-cluster' ]; then
    echo " "
    echo "PostgreSQL database will be set to off-cluster ..."
    local status=0
    for env_var in DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USERNAME DATABASE_PASSWORD; do
      if [ -z "${!env_var}" ]; then
        echo "Please provide ${env_var}"
        ((status+=1))
      fi
    done
    # export values as environment variables
    export DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USERNAME DATABASE_PASSWORD
    return $status
  fi

  export DATABASE_LOCATION
}

set_object_storage() {
  STORAGE_TYPE="${STORAGE_TYPE:-minio}"

  if [ "${STORAGE_TYPE}" == 'gcs' ]; then
    echo "Object Storage will use GCS ..."
    if [ -z "${SERVICE_ACCOUNT_KEY}" ]; then
      echo "Please provide the path to your gcs service account key as SERVICE_ACCOUNT_KEY"
      exit 1
    fi

    GCS_KEY_JSON=$(cat "${SERVICE_ACCOUNT_KEY}")
    GCS_REGISTRY_BUCKET="${GCS_REGISTRY_BUCKET:-${K8S_NAME}-deis-registry}"
    GCS_DATABASE_BUCKET="${GCS_DATABASE_BUCKET:-${K8S_NAME}-deis-database}"
    GCS_BUILDER_BUCKET="${GCS_BUILDER_BUCKET:-${K8S_NAME}-deis-builder}"

    export GCS_KEY_JSON GCS_REGISTRY_BUCKET GCS_DATABASE_BUCKET GCS_BUILDER_BUCKET

    if [[ "$1" == "eu" ]]; then
      # create GCS buckets in EU region
      echo " "
      echo "Creating GCS buckets in EU region..."
      gsutil mb -l eu gs://${GCS_REGISTRY_BUCKET}
      gsutil mb -l eu gs://${GCS_DATABASE_BUCKET}
      gsutil mb -l eu gs://${GCS_BUILDER_BUCKET}
    fi
  elif [ "${STORAGE_TYPE}" == 's3' ]; then
    echo "Object Storage will use S3 ..."
    local status=0
    for env_var in AWS_ACCESS_KEY AWS_SECRET_KEY S3_REGION; do
      if [ -z "${!env_var}" ]; then
        echo "Please provide ${env_var}"
        ((status+=1))
      fi
    done

    # (No underscores allowed in s3 bucket name)
    AWS_REGISTRY_BUCKET="${AWS_REGISTRY_BUCKET:-${K8S_NAME//_/-}-deis-registry}"
    AWS_DATABASE_BUCKET="${AWS_DATABASE_BUCKET:-${K8S_NAME//_/-}-deis-database}"
    AWS_BUILDER_BUCKET="${AWS_BUILDER_BUCKET:-${K8S_NAME//_/-}-deis-builder}"
    export AWS_REGISTRY_BUCKET AWS_DATABASE_BUCKET AWS_BUILDER_BUCKET
    return $status
  fi

  export STORAGE_TYPE
}

set_registry() {
  REGISTRY_LOCATION="${REGISTRY_LOCATION:-on-cluster}"

  if [ "${REGISTRY_LOCATION}" == 'gcr' ]; then
    echo "Registry location set to GCR ..."
    if [ -z "${SERVICE_ACCOUNT_KEY}" ]; then
      echo "Please provide the path to your gcs service account key as SERVICE_ACCOUNT_KEY"
      exit 1
    fi

    GCR_KEY_JSON=$(cat "${SERVICE_ACCOUNT_KEY}")
    if [[ "$1" == "eu" ]]
    then
      GCR_HOSTNAME="eu.gcr.io"
    else
      GCR_HOSTNAME=""
    fi

    export GCR_KEY_JSON GCR_HOSTNAME
  fi

  export REGISTRY_LOCATION
}

cluster() {
  # get k8s cluster name
  echo " "
  echo "Fetching GKE cluster name ..."
  K8S_NAME=$(kubectl config current-context)
  echo "GKE cluster name is ${K8S_NAME} ..."
  echo " "
}

install_deis() {
  install_dir="${1}"

  # get latest macOS deis cli version
  echo "Downloading latest version of Workflow deis cli ..."
  curl -o "${install_dir}" https://storage.googleapis.com/workflow-cli-master/deis-latest-darwin-amd64
  chmod +x "${install_dir}"
  echo " "
  echo "Installed deis cli to ${install_dir} ..."
  echo " "
}

install_helmc() {
  install_dir="${1}"

  # get latest macOS helmc cli version
  echo "Downloading latest version of helmc cli ..."
  curl -o "${install_dir}" https://storage.googleapis.com/helm-classic/helmc-latest-darwin-amd64
  chmod +x "${install_dir}"
  echo " "
  echo "Installed helmc cli to ${install_dir} ..."
  echo " "
}

wait_for_workflow() {
  set +eo pipefail
  max_timeout_secs="${1:-300}"

  echo " "
  echo "Waiting for Deis Workflow to be ready... but first, coffee!"
  local increment_secs=1
  local waited_time=0
  local command_outputs
  while [ ${waited_time} -lt ${max_timeout_secs} ]; do
    apps="deis-builder, deis-controller, deis-database, deis-logger, deis-monitor, deis-nsqd, deis-registry, deis-registry-proxy, deis-router, deis-workflow-manager"
    kubectl get pods --namespace=deis -l 'app in ('"${apps}"')' -o json | (jq -r '.items[].status.conditions[] | select(.type=="Ready")' 2>/dev/null || true) | grep -q "False"
    if [ $? -gt 0 ]; then
      echo && echo "All pods are running!" 1>&2
      return 0
    fi

    sleep ${increment_secs}
    (( waited_time += increment_secs ))

    if [ ${waited_time} -ge ${max_timeout_secs} ]; then
      echo "Not all pods started!" 1>&2
      kubectl get pods --namespace=deis
      exit 1
    fi

    echo -n . 1>&2
  done
  echo " "
  set -eo pipefail
}

usage() {
  echo "Usage: install_workflow_2_gke.sh install [eu] | upgrade [eu] | deis | helmc | cluster"
}

case "$1" in
        install)
                install $2
                ;;
        upgrade)
                upgrade $2
                ;;
        deis)
                install_deis "$(which deis)"
                ;;
        helmc)
                install_helmc "$(which helmc)"
                ;;
        cluster)
                cluster
                ;;
        *)
                usage
                ;;
esac
