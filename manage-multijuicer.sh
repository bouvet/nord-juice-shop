#! /usr/bin/env bash
# shellcheck disable=SC2015
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

### Required variables ###
# Key used to generate the challenge flags. Should be rotated between CTF-events
CTF_KEY="${CTF_KEY:?Missing required environment variable.}"
# Secret for the cookie parser. Rotate to invalidate all active sessions.
COOKIE_SECRET="${COOKIE_SECRET:?Missing required environment variable.}"
# Secret for the CTFd instance
CTFD_SECRET_KEY="${CTFD_SECRET_KEY:?Missing required environment variable.}"

### Default variables ###
## Azure / Cluster
# Hostname, used as <DNS_NAME>.<LOCATION>.cloudapp.azure.com
DNS_NAME="${DNS_NAME:-bvt-juice}"
# Region in which to deploy the services
LOCATION="${LOCATION:-norway-east}"
# Name of the resource group to use/create.
RESOURCE_GROUP="${RESOURCE_GROUP:-MultiJuicer}"
# Name to use for the cluster
CLUSTER_NAME="${CLUSTER_NAME:-juicy-k8s}"
# Name to use for the container registry
REGISTRY_NAME="${REGISTRY_NAME:-bvtmultijuicer}"
# Number of nodes for the cluster
NODE_COUNT="${NODE_COUNT:-2}"
# Number of multi-juicer replicas
BALANCER_REPLICAS="${BALANCER_REPLICAS:-3}"
## MultiJuicer / JuiceShop
# Max. number of JuiceShop instances that can be spawned  
MAX_INSTANCES="${MAX_INSTANCES:-5}"
# Username for the metrics user
METRICS_USER="${METRICS_USER:-prometheus-scraper}"
# Name of the key vault
KEY_VAULT_NAME="${KEY_VAULT_NAME:-juice-shop-kv}"
## Toggles
# Whether to create/delete the resource group. Defaults to false
MANAGE_RG=${MANAGE_RG:-0}
# Whether to create/delete a container registry. Defaults to false unless 'COMMAND' is 'new' or 'wipe'
MANAGE_ACR=${MANAGE_ACR:-0}
# Whether to create/delete the cluster itself. Defaults to false, unless COMMAND is 'new' or 'wipe'
MANAGE_CLUSTER=${MANAGE_CLUSTER:-0}
# Whether to configure the monitoring solution. Defaults to true
MANAGE_MONITORING=${MANAGE_MONITORING:-0}
# Whether to configure the CTFd deployment. Defaults to true
MANAGE_CTFD=${MANAGE_CTFD:-1}

# Change locale to make "</dev/urandom tr -dc" work on Mac
OS=`uname`
if [ "$OS" = 'Darwin' ]; then
    export LC_CTYPE=C
fi

# Whether to delete PVCs (Persistent Volume Claims) when running 'down'
# If no MYSQL/Redis password is supplied, it will be random-generated, and as such will result in failure when running 'up',
# as a new password will be generated which does not match the persisted database password.
DESTROY_PVC=${DESTROY_PVC:=0}
if [ -z "${CTFD_MYSQL_ROOT_PASS:-}" ] || [ -z "${CTFD_MYSQL_PASS:-}" ] || [ -z "${CTFD_REDIS_PASS:-}" ]; then
    DESTROY_PVC=1
fi

function usage() {
    echo -e "Usage: ./$SCRIPT_NAME COMMAND

    Commands:
        new\tDeploy a brand new cluster
        down\tStop all running containers
        up\tSpin it back up
        wipe\tWipe it, deleting all services including the cluster
    "
    exit 0
}

function setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    # shellcheck disable=SC2034
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

setup_colors

info() {
  echo >&2 -e "${CYAN}$1${NOFORMAT}"
}

success() {
  echo >&2 -e "${GREEN}    SUCCESS${NOFORMAT}"
}

failure() {
  echo >&2 -e "${RED}${1:-\tERROR}${NOFORMAT}"
}

function randstr() {
    </dev/urandom tr -dc 'A-Za-z0-9' | head -c 24; echo
}

ARGS=("$@")
[[ ${#ARGS[@]} -eq 0 ]] && usage

# Command to execute
COMMAND="${ARGS[0]}"

# Generate passwords if not provided
METRICS_PASS="${METRICS_PASS:-$(randstr)}"
GRAFANA_PASS="${GRAFANA_PASS:-$(randstr)}"
CTFD_REDIS_PASS="${CTFD_REDIS_PASS:-$(randstr)}"
CTFD_MYSQL_ROOT_PASS="${CTFD_MYSQL_ROOT_PASS:-$(randstr)}"
CTFD_MYSQL_PASS="${CTFD_MYSQL_PASS:-$(randstr)}"
CTFD_MYSQL_REPL_PASS="${CTFD_MYSQL_REPL_PASS:-$(randstr)}"

ACR_URL="$REGISTRY_NAME.azurecr.io"
__MONITORING_NAMESPACE="monitoring"
__MONITORING_ENABLED="true"
if [ "$MANAGE_MONITORING" -eq 0 ]; then
    __MONITORING_ENABLED="false"
fi

# Container Registry vars
SOURCE_REGISTRY="registry.k8s.io"
CONTROLLER_IMAGE="ingress-nginx/controller"
CONTROLLER_TAG="v1.0.4"
PATCH_IMAGE="ingress-nginx/kube-webhook-certgen"
PATCH_TAG="v1.1.1"
DEFAULTBACKEND_IMAGE="defaultbackend-amd64"
DEFAULTBACKEND_TAG="1.5"
CERT_MANAGER_REGISTRY="quay.io"
CERT_MANAGER_TAG="v1.5.4"
CERT_MANAGER_IMAGE_CONTROLLER="jetstack/cert-manager-controller"
CERT_MANAGER_IMAGE_WEBHOOK="jetstack/cert-manager-webhook"
CERT_MANAGER_IMAGE_CAINJECTOR="jetstack/cert-manager-cainjector"

function create_resource_group() {
    info "Creating Resource Group '$RESOURCE_GROUP' in '$LOCATION'"
    # Create a new resource group
    az group create --location "$LOCATION" --name "$RESOURCE_GROUP"
}

function destroy_resource_group() {
    info "Deleting Resource Group '$RESOURCE_GROUP'" 
    # Delete the resource group
    az group delete --yes --name "$RESOURCE_GROUP"
}

function create_cluster() {
    info "Creating AKS cluster '$CLUSTER_NAME'"
    # Create the AKS cluster
    az aks create --yes --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --node-count "$NODE_COUNT" --no-ssh-key
}

function destroy_cluster() {
    info "Deleting AKS cluster '$CLUSTER_NAME'"
    # Delete the AKS cluster
    az aks delete --yes --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME"
}

function start_vm_scale_set() {
    info "Starting the VM scale set"
    # Get the name of the node resource group
    NODE_RESOURCE_GROUP=$(az aks list --query "[].nodeResourceGroup" --output tsv)
    # Get the name of the VM scale set
    SCALE_SET_NAME=$(az vmss list --resource-group "$NODE_RESOURCE_GROUP" --query "[].name" --output tsv)
    # Start the VM scale set
    az vmss start --resource-group "$NODE_RESOURCE_GROUP" --name "$SCALE_SET_NAME"
}

function deallocate_vm_scale_set() {
    info "Deallocating the VM scale set"
    # Get the name of the node resource group
    NODE_RESOURCE_GROUP=$(az aks list --query "[].nodeResourceGroup" --output tsv)
    # Get the name of the VM scale set
    SCALE_SET_NAME=$(az vmss list --resource-group "$NODE_RESOURCE_GROUP" --query "[].name" --output tsv)
    # Start the VM scale set
    az vmss deallocate --resource-group "$NODE_RESOURCE_GROUP" --name "$SCALE_SET_NAME"
}

function deploy_multi_juicer() {
    info "Deploying multi-juicer"
    # Add the helm repo for multi-juicer
    
    # Enable OCI support
    export HELM_EXPERIMENTAL_OCI=1

    # Use helm to deploy the multi-juicer chart, overriding the values (see juicer.yaml)
    helm upgrade --install multi-juicer \
        oci://ghcr.io/juice-shop/multi-juicer/helm/multi-juicer \
        --values juicer.yaml \
        --set balancer.cookie.cookieParserSecret="$COOKIE_SECRET" \
        --set balancer.replicas="$BALANCER_REPLICAS" \
        --set juiceShop.maxInstances="$MAX_INSTANCES" \
        --set juiceShop.ctfKey="$CTF_KEY" \
        --set balancer.metrics.enabled="$__MONITORING_ENABLED" \
        --set balancer.metrics.dashboards.enabled="$__MONITORING_ENABLED" \
        --set balancer.metrics.serviceMonitor.enabled="$__MONITORING_ENABLED" \
        --set balancer.metrics.basicAuth.username="$METRICS_USER" \
        --set balancer.metrics.basicAuth.password="$METRICS_PASS"
    
    # Get the multi-juicer admin password
    MULTI_JUICER_PASS=$(kubectl get secrets juice-balancer-secret -o=jsonpath='{.data.adminPassword}' | base64 --decode)
    # Push the password to the key vault
    az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "multijuicer-admin-password" --value "$MULTI_JUICER_PASS"
}

function destroy_multi_juicer() {
    info "Deleting multi-juicer"
    # Delete the multi-juicer deployment
    helm delete multi-juicer
}

function create_container_registry() {
    info "Creating container registry '$REGISTRY_NAME'"
    # Create an Azure Container Registry
    az acr create --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --sku Basic
}

function destroy_container_registry() {
    info "Deleting container registry '$REGISTRY_NAME'"
    # Delete the ACR
    az acr delete --yes --name "$REGISTRY_NAME"
}

function attach_container_registry() {
    info "Attaching the ACR '$REGISTRY_NAME' to the cluster"
    # Attach the ACR to the cluster
    # NB: Requires subscription-level Owner permissions
    az aks update --yes --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --attach-acr "$REGISTRY_NAME"
}

function import_container_images() {
    info "Importing container images to the registry"
    # Import the container images to the ACR
    az acr import --name "$REGISTRY_NAME" --source "$SOURCE_REGISTRY/$CONTROLLER_IMAGE:$CONTROLLER_TAG" --image "$CONTROLLER_IMAGE:$CONTROLLER_TAG"
    az acr import --name "$REGISTRY_NAME" --source "$SOURCE_REGISTRY/$PATCH_IMAGE:$PATCH_TAG" --image "$PATCH_IMAGE:$PATCH_TAG"
    az acr import --name "$REGISTRY_NAME" --source "$SOURCE_REGISTRY/$DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG" --image "$DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG"
    az acr import --name "$REGISTRY_NAME" --source "$CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG" --image "$CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG"
    az acr import --name "$REGISTRY_NAME" --source "$CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG" --image "$CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG"
    az acr import --name "$REGISTRY_NAME" --source "$CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG" --image "$CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG"
}

function deploy_ingress() {
    info "Deploying ingress-nginx"
    # Add the helm repo for ingress-nginx
    helm repo add --force-update ingress-nginx https://kubernetes.github.io/ingress-nginx

    # Use helm to deploy the NGINX ingress controller
    helm install nginx-ingress ingress-nginx/ingress-nginx \
        --version 4.0.13 \
        --namespace default --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.image.registry="$ACR_URL" \
        --set controller.image.image="$CONTROLLER_IMAGE" \
        --set controller.image.tag="$CONTROLLER_TAG" \
        --set controller.image.digest="" \
        --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
        --set controller.admissionWebhooks.patch.image.registry="$ACR_URL" \
        --set controller.admissionWebhooks.patch.image.image="$PATCH_IMAGE" \
        --set controller.admissionWebhooks.patch.image.tag="$PATCH_TAG" \
        --set controller.admissionWebhooks.patch.image.digest="" \
        --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
        --set defaultBackend.image.registry="$ACR_URL" \
        --set defaultBackend.image.image="$DEFAULTBACKEND_IMAGE" \
        --set defaultBackend.image.tag="$DEFAULTBACKEND_TAG" \
        --set defaultBackend.image.digest=""
}

function destroy_ingress() {
    info "Deleting ingress-nginx"
    # Delete the ingress deployment
    helm delete nginx-ingress
}

function configure_dns_record() {
    info "Configuring the DNS record"
    # Get the public IP of the NGINX ingress controller
    PUBLIC_IP=$(kubectl --namespace default get services -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' nginx-ingress-ingress-nginx-controller)

    # Get the resource ID of the Public IP resource
    PUBLIC_IP_ID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$PUBLIC_IP')].[id]" --output tsv)

    # Add the hostname <DNS_NAME> to the Public IP resource
    az network public-ip update --ids "$PUBLIC_IP_ID" --dns-name "$DNS_NAME" 2>/dev/null || true
}

function destroy_dns_record() {
    info "Deleting the DNS record"
     # Get the public IP of the NGINX ingress controller
    PUBLIC_IP=$(kubectl --namespace default get services -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' nginx-ingress-ingress-nginx-controller)

    # Get the resource ID of the Public IP resource
    PUBLIC_IP_ID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$PUBLIC_IP')].[id]" --output tsv)

    # Delete the public IP record
    az network public-ip delete --ids "$PUBLIC_IP_ID"
}

function deploy_cert_manager() {
    info "Deploying cert-manager"
    # Add a label to the default namespace, to disable resource validation
    kubectl label --overwrite namespace default cert-manager.io/disable-validation=true

    # Add the helm repository for Jetstack
    helm repo add --force-update jetstack https://charts.jetstack.io

    # Update the local helm chart repository cache
    helm repo update

    # Use helm to deploy the cert-manager service
    helm install cert-manager jetstack/cert-manager \
        --namespace default \
        --version "$CERT_MANAGER_TAG" \
        --set installCRDs=true \
        --set nodeSelector."kubernetes\.io/os"=linux \
        --set image.repository="$ACR_URL/$CERT_MANAGER_IMAGE_CONTROLLER" \
        --set image.tag="$CERT_MANAGER_TAG" \
        --set webhook.image.repository="$ACR_URL/$CERT_MANAGER_IMAGE_WEBHOOK" \
        --set webhook.image.tag="$CERT_MANAGER_TAG" \
        --set cainjector.image.repository="$ACR_URL/$CERT_MANAGER_IMAGE_CAINJECTOR" \
        --set cainjector.image.tag="$CERT_MANAGER_TAG"
}

function destroy_cert_manager() {
    info "Deleting cert-manager"
    # Delete the cert-manager deployment
    helm delete cert-manager
}

function apply_cluster_issuer() {
    info "Configuring cluster-issuer"
    # Create a cluster issuer
    kubectl apply -f cluster-issuer.yaml
}

function apply_ingress() {
    info "Configuring ingress"
    kubectl apply -f ingress.yaml --namespace default
}

function deploy_monitoring() {
    info "Deploying monitoring services"
    # Add the helm repository for prometheus
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    # Add the helm repository for grafana
    helm repo add grafana https://grafana.github.io/helm-charts
    
    # Update the local helm chart repository cache
    helm repo update

    # Create a new namespace for the monitoring services
    kubectl get namespace "$__MONITORING_NAMESPACE" &> /dev/null && true || kubectl create namespace "$__MONITORING_NAMESPACE"

    # Use helm to deploy the prometheus-stack chart, overriding the values (see monitoring.yaml)
    helm --namespace "$__MONITORING_NAMESPACE" \
        upgrade --install monitoring \
        prometheus-community/kube-prometheus-stack \
        --version 45.21.0 \
        --values monitoring.yaml \
        --set grafana.adminPassword="$GRAFANA_PASS"
    
    # Use helm to deploy the loki chart
    helm --namespace "$__MONITORING_NAMESPACE" \
        upgrade --install loki \
        grafana/loki \
        --version 5.2.0 \
        --set serviceMonitor.enabled="true"

    # Use helm to deploy the promtail chart
    helm --namespace "$__MONITORING_NAMESPACE" \
        upgrade --install promtail \
        grafana/promtail \
        --version 6.11.0 \
        --set config.lokiAddress="http://loki:3100/loki/api/v1/push" \
        --set serviceMonitor.enabled="true"
}

function destroy_monitoring() {
    info "Deleting monitoring services"

    # Delete the monitoring deployment
    helm --namespace "$__MONITORING_NAMESPACE" delete promtail
    helm --namespace "$__MONITORING_NAMESPACE" delete loki
    helm --namespace "$__MONITORING_NAMESPACE" delete monitoring
    # https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#uninstall-helm-chart
    kubectl delete crd alertmanagerconfigs.monitoring.coreos.com
    kubectl delete crd alertmanagers.monitoring.coreos.com
    kubectl delete crd podmonitors.monitoring.coreos.com
    kubectl delete crd probes.monitoring.coreos.com
    kubectl delete crd prometheuses.monitoring.coreos.com
    kubectl delete crd prometheusrules.monitoring.coreos.com
    kubectl delete crd servicemonitors.monitoring.coreos.com
    kubectl delete crd thanosrulers.monitoring.coreos.com
    
    # Delete the namespace for the monitoring services
    kubectl delete namespace "$__MONITORING_NAMESPACE" --force
}

function deploy_ctfd() {
    info "Deploying CTFd"

    # Enable OCI support
    export HELM_EXPERIMENTAL_OCI=1

    # Use helm to deploy the CTFd chart, overriding the values (see ctfd.yaml)
    helm upgrade --install ctfd \
        oci://ghcr.io/bman46/ctfd/ctfd \
        --values ctfd.yaml \
        --set redis.auth.password="$CTFD_REDIS_PASS" \
        --set mariadb.auth.rootPassword="$CTFD_MYSQL_ROOT_PASS" \
        --set mariadb.auth.password="$CTFD_MYSQL_PASS" \
        --set mariadb.auth.replicationPassword="$CTFD_MYSQL_REPL_PASS" \
        --set env.open.SECRET_KEY="$CTFD_SECRET_KEY"
}

function destroy_ctfd() {
    info "Deleting CTFd"
    # Delete the ctfd deployment
    helm uninstall ctfd
    if [ "$DESTROY_PVC" -eq 1 ]; then
        kubectl delete pvc -l "app.kubernetes.io/instance=ctfd"
    fi
}

function get_credentials() {
    # Retrieve the credentials for the cluster
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
}

function wait_for_propagation() {
    # Wait for changes to propagate
    info "Waiting for changes to propagate..."
    sleep 30
}

function up() {
    # Manage the resource group
    if [ "$MANAGE_RG" -eq 1 ]; then
        create_resource_group && success
    fi
    # Manage the container registry
    if [ "$MANAGE_ACR" -eq 1 ]; then
        create_container_registry && success
        import_container_images && success
    fi
    # Manage the cluster itself
    if [ "$MANAGE_CLUSTER" -eq 1 ]; then
        create_cluster && success
    fi
    if [ "$MANAGE_CLUSTER" -eq 1 ] && [ "$MANAGE_ACR" -eq 1 ]; then
        attach_container_registry && success
    fi
    if [ "$MANAGE_CLUSTER" -eq 0 ]; then
        start_vm_scale_set && success
    fi
    get_credentials
    # Manage the monitoring services (prometheus/grafana/loki)
    if [ "$MANAGE_MONITORING" -eq 1 ]; then
        deploy_monitoring && success
    fi
    deploy_multi_juicer && success
    if [ "$MANAGE_CTFD" -eq 1 ]; then
        deploy_ctfd && success
    fi
    deploy_ingress && success
    wait_for_propagation
    configure_dns_record && success
    deploy_cert_manager && success
    apply_cluster_issuer && success
    apply_ingress && success
    info "DONE"
}

function down() {
    # Manage the resource group
    if [ "$MANAGE_RG" -eq 1 ]; then
        destroy_resource_group && success || failure
    fi
    # Manage the container registry
    if [ "$MANAGE_ACR" -eq 1 ]; then
        destroy_container_registry && success || failure
    fi
    get_credentials 2> /dev/null || true
    destroy_cert_manager && success || failure
    destroy_ingress && success || failure
    if [ "$MANAGE_CTFD" -eq 1 ]; then
        destroy_ctfd && success || failure
    fi
    destroy_multi_juicer && success || failure
    # Manage the monitoring services (prometheus/grafana/loki)
    if [ "$MANAGE_MONITORING" -eq 1 ]; then
        destroy_monitoring && success || failure
    fi
    # Manage the cluster itself
    if [ "$MANAGE_CLUSTER" -eq 1 ]; then
        destroy_cluster && success || failure
    fi
    if [ "$MANAGE_CLUSTER" -eq 0 ]; then
        deallocate_vm_scale_set && success || failure
    fi

    info "DONE"
}

case "$COMMAND" in
    "-h" | "--help")
        usage
        ;;
    "new")
        MANAGE_ACR=1
        MANAGE_CLUSTER=1
        up
        ;;
    "up")
        MANAGE_ACR=0
        MANAGE_CLUSTER=0
        up
        ;;
    "down")
        MANAGE_ACR=0
        MANAGE_CLUSTER=0
        down
        ;;
    "wipe")
        MANAGE_ACR=1
        MANAGE_CLUSTER=1
        down
        ;;
    *)
        failure "Invalid argument '$COMMAND'\n"
        usage
        ;;
esac
