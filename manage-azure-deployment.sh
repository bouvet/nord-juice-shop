#! /usr/bin/env bash
# shellcheck disable=SC2015
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

### Required variables ###
# Name of the resource group to use. Will be created if 'MANAGE_RG=1'
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Missing required environment variable.}"
# DNS name of the NGINX controller, used as <AZURE_DNS_NAME>.<AZURE_LOCATION>.cloudapp.azure.com
AZURE_DNS_NAME="${AZURE_DNS_NAME:?Missing required environment variable.}"

### Default variables ###
## Azure / Cluster
# Region in which to deploy the services
AZURE_LOCATION="${AZURE_LOCATION:-norwayeast}"
# Name to use for the cluster
CLUSTER_NAME="${CLUSTER_NAME:-juicy-k8s}"
# Number of nodes for the cluster
NODE_COUNT="${NODE_COUNT:-2}"
# Name of the key vault
KEY_VAULT_NAME="${KEY_VAULT_NAME:-juice-shop-kv}"
## Toggles
# Whether to create the resource group. Defaults to false
MANAGE_RG=${MANAGE_RG:-0}
# Whether to purge the resource group. Defaults to false.
PURGE_RG=${PURGE_RG:-0}
# Whether to create/delete the cluster itself. Defaults to false, unless COMMAND is 'new' or 'wipe'
MANAGE_CLUSTER=${MANAGE_CLUSTER:-0}
# Whether to create/delete the key vault. Defaults to false
MANAGE_KEYVAULT=${MANAGE_KEYVAULT:-0}
# Whether to purge the key vault. Requires MANAGE_KEYVAULT=1. Defaults to false
PURGE_KEYVAULT=${PURGE_KEYVAULT:-0}

__REQUIRED_BINARIES=(
    "az"
    "kubectl"
)
# Check that all required binaries are present
for __REQ_PKG in "${__REQUIRED_BINARIES[@]}"; do
    if ! which "$__REQ_PKG" &> /dev/null ; then
        echo "ERROR: Missing required package '$__REQ_PKG'"
        exit 1
    fi
done

function usage() {
    echo -e "Usage: ./$SCRIPT_NAME COMMAND

    Commands:
        new\tDeploy a brand new cluster
        up\tSpin the cluster back up, scaling up the resources
        down\tScale down the cluster to save resources (keeps the AKS resource itself intact)
        wipe\tRemoves the cluster
        wipe-all\tRemoves the cluster, resource group, and key vault.
        write-secrets\tWrite the secrest to Azure Key Vault.
        password\tRetrieve the admin password for the multi-juicer instance
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

ARGS=("$@")
[[ ${#ARGS[@]} -eq 0 ]] && usage

# Command to execute
COMMAND="${ARGS[0]}"

function __check_resource_group() {
    # Returns non-zero status if the group does not exist
    az group show --name "$AZURE_RESOURCE_GROUP" &> /dev/null
}

function create_resource_group() {
    info "Creating Resource Group '$AZURE_RESOURCE_GROUP' in '$AZURE_LOCATION'"
    # Create a new resource group
    az group create --location "$AZURE_LOCATION" --name "$AZURE_RESOURCE_GROUP"
}

function destroy_resource_group() {
    info "Deleting Resource Group '$AZURE_RESOURCE_GROUP'" 
    # Delete the resource group
    az group delete --yes --name "$AZURE_RESOURCE_GROUP"
}

function create_cluster() {
    info "Creating AKS cluster '$CLUSTER_NAME'"
    # Create the AKS cluster
    az aks create --yes --resource-group "$AZURE_RESOURCE_GROUP" --name "$CLUSTER_NAME" --node-count "$NODE_COUNT" --no-ssh-key
}

function destroy_cluster() {
    info "Deleting AKS cluster '$CLUSTER_NAME'"
    # Delete the AKS cluster
    az aks delete --yes --resource-group "$AZURE_RESOURCE_GROUP" --name "$CLUSTER_NAME"
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
    # Stop the VM scale set
    az vmss deallocate --resource-group "$NODE_RESOURCE_GROUP" --name "$SCALE_SET_NAME"
}

function create_keyvault() {
    info "Creating the Azure Key Vault '$KEY_VAULT_NAME'"
    az keyvault create --location "$AZURE_LOCATION" --name "$KEY_VAULT_NAME" --resource-group "$AZURE_RESOURCE_GROUP"
    if [ -n "$AZURE_SERVICE_PRINCIPAL_NAME" ]; then
        # Grant access to the KeyVault to the Service Principal, if defined
        az keyvault set-policy --name "$KEY_VAULT_NAME" --spn "$AZURE_SERVICE_PRINCIPAL_NAME" --secret-permissions set get list
    fi
}

function delete_keyvault() {
    info "Deleting the Azure Key Vault '$KEY_VAULT_NAME'"
    az keyvault delete --name "$KEY_VAULT_NAME" --resource-group "$AZURE_RESOURCE_GROUP"
}

function get_cluster_credentials() {
    # Retrieve the credentials for the cluster
    az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
}

function __kv_exists() {
    # Helper function to check if the Azure Key Vault '$KEY_VAULT_NAME' exists
    az keyvault show --resource-group "$AZURE_RESOURCE_GROUP" --name "$KEY_VAULT_NAME" &> /dev/null
}

function write_secrets_to_keyvault() {
    # Activate the namespace in which multi-juicer resources are deployed
    ./manage-multijuicer.sh set-namespace
    info "Writing secrets to the Azure Key Vault '$KEY_VAULT_NAME'"
    if __kv_exists; then
        # Push the CTFd DB password to the key vault
        __CTFD_DB_PASS=$(kubectl get secrets ctfd-mariadb -o=jsonpath='{.data.mariadb-password}' | base64 --decode)
        [ -n "$__CTFD_DB_PASS" ] && az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "ctfd-db-password" --value "$__CTFD_DB_PASS" || failure "Failed to retrieve the CTFd DB password"
        # Push the CTFd DB root password to the key vault
        __CTFD_DB_ROOT_PASS=$(kubectl get secrets ctfd-mariadb -o=jsonpath='{.data.mariadb-root-password}' | base64 --decode)
        [ -n "$__CTFD_DB_ROOT_PASS" ] && az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "ctfd-db-root-password" --value "$__CTFD_DB_ROOT_PASS" || failure "Failed to retrieve the CTFd DB root password"
        # Push the multi-juicer admin password to the key vault
        get_multi_juicer_admin_password && az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "multijuicer-admin-password" --value "$MULTI_JUICER_PASS"
    else
        failure "The keyvault '$KEY_VAULT_NAME' does not exist. It can be created automatically by setting 'MANAGE_KEYVAULT=1'"
    fi
}

function get_multi_juicer_admin_password() {
    # Activate the namespace in which multi-juicer resources are deployed
    ./manage-multijuicer.sh set-namespace
    # Get the multi-juicer admin password
    MULTI_JUICER_PASS=$(kubectl get secrets juice-balancer-secret -o=jsonpath='{.data.adminPassword}' | base64 --decode)
    if [ -z "$MULTI_JUICER_PASS" ]; then
        failure "Failed to retrieve the multi-juicer admin password"
        return 1
    fi
}

function up() {
    info "Deploying the Kubernetes cluster"
    # Manage the resource group
    if [ "$MANAGE_RG" -eq 1 ]; then
        create_resource_group && success
    else
        if ! __check_resource_group; then
            failure "The resource group '$AZURE_RESOURCE_GROUP' does not exist. Please create it manually, or re-run the script with 'MANAGE_RG=1'."
            exit 1
        fi
    fi
    # Manage the cluster itself
    if [ "$MANAGE_CLUSTER" -eq 1 ]; then
        create_cluster && success
    fi
    if [ "$MANAGE_CLUSTER" -eq 0 ]; then
        start_vm_scale_set && success
    fi
    if [ "$MANAGE_KEYVAULT" -eq 1 ]; then
        create_keyvault && success || failure "Unable to create Key Vault from this device"
    fi
    get_cluster_credentials
    info "DONE"
}

function down() {
    info "Shutting down the services"
    # Remove the resource group
    if [ "$PURGE_RG" -eq 1 ]; then
        destroy_resource_group && success || failure
    fi
    get_cluster_credentials 2> /dev/null || true
    # Manage the cluster itself
    if [ "$MANAGE_CLUSTER" -eq 1 ]; then
        destroy_cluster && success || failure
    fi
    if [ "$MANAGE_CLUSTER" -eq 0 ]; then
        deallocate_vm_scale_set && success || failure
    fi
    if [ "$MANAGE_KEYVAULT" -eq 1 ]; then
        delete_keyvault && success
        if [ "$PURGE_KEYVAULT" -eq 1 ]; then
            az keyvault purge --name "$KEY_VAULT_NAME" || true
        fi
    fi
    info "DONE"
}

function get_admin_password() {
    info "Retrieving the admin password for the multi-juicer instance"
    get_cluster_credentials
    get_multi_juicer_admin_password
    info "Admin password:\n$MULTI_JUICER_PASS"
    info "DONE"
}

case "$COMMAND" in
    "-h" | "--help")
        usage
        ;;
    "new")
        MANAGE_CLUSTER=1
        up
        ;;
    "up")
        MANAGE_CLUSTER=0
        up
        ;;
    "down")
        MANAGE_CLUSTER=0
        down
        ;;
    "wipe")
        MANAGE_CLUSTER=1
        down
        ;;
    "wipe-all")
        MANAGE_RG=1
        MANAGE_CLUSTER=1
        MANAGE_KEYVAULT=1
        down
        ;;
    "write-secrets")
        write_secrets_to_keyvault && success
        ;;
    "password")
        get_admin_password
        ;;
    *)
        failure "Invalid argument '$COMMAND'\n"
        usage
        ;;
esac
