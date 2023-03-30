#! /usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Whether to create/delete the resource group. Defaults to false
MANAGE_RG=${MANAGE_RG:=0}
# Whether to create/delete a container registry. Defaults to false unless 'COMMAND' is 'new' or 'wipe'
MANAGE_ACR=${MANAGE_ACR:=0}
# Whether to create/delete the cluster itself. Defaults to false, unless COMMAND is 'new' or 'wipe'
MANAGE_CLUSTER=${MANAGE_CLUSTER:=0}

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

ARGS=("$@")
[[ ${#ARGS[@]} -eq 0 ]] && usage

# Command to execute
COMMAND="${ARGS[0]}"

## Parameters
ACR_URL="$REGISTRY_NAME.azurecr.io"

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
    az aks create --yes --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --node-count "$NODE_COUNT"
}

function destroy_cluster() {
    info "Deleting AKS cluster '$CLUSTER_NAME'"
    # Delete the AKS cluster
    az aks delete --yes --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME"
}

function deploy_multi_juicer() {
    info "Deploying multi-juicer"
    # Add the helm repo for multi-juicer
    helm repo add --force-update multi-juicer https://iteratec.github.io/multi-juicer/

    # Use helm to deploy the multi-juicer chart, overriding the values (see juicer.yaml)
    helm upgrade --install multi-juicer \
        multi-juicer/multi-juicer \
        --values juicer.yaml \
        --set balancer.cookie.cookieParserSecret="$COOKIE_SECRET" \
        --set balancer.replicas="$BALANCER_REPLICAS" \
        --set juiceShop.maxInstances="$MAX_INSTANCES" \
        --set juiceShop.ctfKey="$CTF_KEY"
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
    kubectl label namespace default cert-manager.io/disable-validation=true

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

function get_credentials() {
    # Retrieve the credentials for the cluster
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
}

function wait_for_propagation() {
    # Wait for changes to propagate
    info "Waiting for changes to propagate..."
    sleep 60
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
        attach_container_registry
    fi
    get_credentials
    deploy_multi_juicer && success
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
    destroy_multi_juicer && success || failure
    # Manage the cluster itself
    if [ "$MANAGE_CLUSTER" -eq 1 ]; then
        destroy_cluster && success || failure
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
