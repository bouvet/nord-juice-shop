# Nord Juice Shop

- https://ctfd.io/
- https://github.com/CTFd/CTFd
- https://owasp.org/www-project-juice-shop/
- https://github.com/iteratec/multi-juicer
- https://jmatch.medium.com/multijuicer-a-brilliant-way-to-deliver-remote-cyber-security-workshops-ctf-events-c70942bc2f9b
- https://github.com/equinor/juiceshop-ctfd

## Deployment
### Prerequisites
- [Helm](https://helm.sh/docs/intro/install/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)

### Azure Kubernetes Services [AKS]
> Make sure that you've installed [Azure CLI](https://learn.microsoft.com/en-us/dotnet/azure/install-azure-cli) first

These steps are based on [this guide](https://github.com/iteratec/multi-juicer/blob/main/guides/azure/azure.md)

1. Authenticate against Azure
    ```bash
    # Log in to Azure CLI with your Bouvet account
    # A new tab will open in your browser, asking you to authenticate
    az login

    # Set the subscription in which you wish to deploy Multi-Juicer
    az account set -s <subscription_id | subscription_name>
    ```

2. Create the Kubernetes cluster
    ```bash
    # Determine the resource group in which the resources should be deployed.
    # If you wish to create a new resource group, run
    az group create --location norway-east --name MultiJuicer

    # Create an AKS cluster in the resource group determined above
    az aks create --resource-group MultiJuicer --name juicy-k8s --node-count 2

    # Retrieve the credentials for the new cluster
    az aks get-credentials --resource-group MultiJuicer --name juicy-k8s

    # Verify that you've authenticated against the new cluster - should display 'juicy-k8s'
    kubectl config current-context
    ```

3. Set up multi-juicer
    ```bash
    # Add the helm repository for multi-juicer
    helm repo add multi-juicer https://iteratec.github.io/multi-juicer/

    # Use helm to deploy the multi-juicer chart, overriding the values (see values.yml)
    helm upgrade --install multi-juicer multi-juicer/multi-juicer --values juicer.yaml

    # Kubernetes will now spin up the pods
    # Verify that everything is starting
    kubectl get pods
    # Wait until both pods are ready

    # Retrieve the password for the admin UI
    kubectl get secrets juice-balancer-secret -o=jsonpath='{.data.adminPassword}' | base64 --decode
    # To log in to the admin dashboard, visit /balancer and log in as the team 'admin'
    ```

- [Optional] Verify that the application is running correctly
    - See [Verify the app is running correctly](https://github.com/iteratec/multi-juicer/blob/main/guides/azure/azure.md#step-3-verify-the-app-is-running-correctly)

4. Configure Ingress and TLS
    1. Create a Container Registry for the NGINX and cert-manager images
        ```bash
        # Create the Container Registry
        az acr create --name bvtmultijuicer --resource-group MultiJuicer --sku Basic

        # Attach the Container Registry to the Kubernetes cluster
        # NB: Requires Owner permissions on the Azure subscription
        az aks update --name juicy-k8s --resource-group MultiJuicer --attach-acr bvtmultijuicer
        ```

    2. Import the NGINX and cert-manager images
        ```bash
        REGISTRY_NAME=bvtmultijuicer
        SOURCE_REGISTRY=registry.k8s.io
        CONTROLLER_IMAGE=ingress-nginx/controller
        CONTROLLER_TAG=v1.0.4
        PATCH_IMAGE=ingress-nginx/kube-webhook-certgen
        PATCH_TAG=v1.1.1
        DEFAULTBACKEND_IMAGE=defaultbackend-amd64
        DEFAULTBACKEND_TAG=1.5
        CERT_MANAGER_REGISTRY=quay.io
        CERT_MANAGER_TAG=v1.5.4
        CERT_MANAGER_IMAGE_CONTROLLER=jetstack/cert-manager-controller
        CERT_MANAGER_IMAGE_WEBHOOK=jetstack/cert-manager-webhook
        CERT_MANAGER_IMAGE_CAINJECTOR=jetstack/cert-manager-cainjector

        az acr import --name $REGISTRY_NAME --source $SOURCE_REGISTRY/$CONTROLLER_IMAGE:$CONTROLLER_TAG --image $CONTROLLER_IMAGE:$CONTROLLER_TAG
        az acr import --name $REGISTRY_NAME --source $SOURCE_REGISTRY/$PATCH_IMAGE:$PATCH_TAG --image $PATCH_IMAGE:$PATCH_TAG
        az acr import --name $REGISTRY_NAME --source $SOURCE_REGISTRY/$DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG --image $DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG
        az acr import --name $REGISTRY_NAME --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG --image $CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG
        az acr import --name $REGISTRY_NAME --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG --image $CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG
        az acr import --name $REGISTRY_NAME --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG --image $CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG
        ```

    3. Set up an NGINX Ingress controller
        ```bash
        # Add the helm repository for ingress-nginx
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

        # Set the URL of the ACR we created in step 4.1
        ACR_URL=bvtmultijuicer.azurecr.io

        # Use helm to deploy the NGINX ingress controller
        helm install nginx-ingress ingress-nginx/ingress-nginx \
            --version 4.0.13 \
            --namespace default --create-namespace \
            --set controller.replicaCount=2 \
            --set controller.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.image.registry=$ACR_URL \
            --set controller.image.image=$CONTROLLER_IMAGE \
            --set controller.image.tag=$CONTROLLER_TAG \
            --set controller.image.digest="" \
            --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
            --set controller.admissionWebhooks.patch.image.registry=$ACR_URL \
            --set controller.admissionWebhooks.patch.image.image=$PATCH_IMAGE \
            --set controller.admissionWebhooks.patch.image.tag=$PATCH_TAG \
            --set controller.admissionWebhooks.patch.image.digest="" \
            --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
            --set defaultBackend.image.registry=$ACR_URL \
            --set defaultBackend.image.image=$DEFAULTBACKEND_IMAGE \
            --set defaultBackend.image.tag=$DEFAULTBACKEND_TAG \
            --set defaultBackend.image.digest=""
        ```

    4. Configure a domain name (FQDN)
        ```bash
        # Get the public IP of the NGINX ingress controller
        PUBLIC_IP=$(kubectl --namespace default get services -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' nginx-ingress-ingress-nginx-controller)

        # Define a hostname
        DNS_NAME="bvt-juice"

        # Get the resource ID of the Public IP resource
        PUBLIC_IP_ID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$PUBLIC_IP')].[id]" --output tsv)

        # Add the hostname <DNS_NAME> to the Public IP resource 
        az network public-ip update --ids $PUBLIC_IP_ID --dns-name $DNS_NAME
        ```

    5. Set up cert-manager
        ```bash
        # Add a label to the default namespace, to disable resource validation
        kubectl label namespace default cert-manager.io/disable-validation=true

        # Add the helm repository for Jetstack
        helm repo add jetstack https://charts.jetstack.io

        # Update the local helm chart repository cache
        helm repo update

        # Use helm to deploy the cert-manager service
        helm install cert-manager jetstack/cert-manager \
            --namespace default \
            --version $CERT_MANAGER_TAG \
            --set installCRDs=true \
            --set nodeSelector."kubernetes\.io/os"=linux \
            --set image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_CONTROLLER \
            --set image.tag=$CERT_MANAGER_TAG \
            --set webhook.image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_WEBHOOK \
            --set webhook.image.tag=$CERT_MANAGER_TAG \
            --set cainjector.image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_CAINJECTOR \
            --set cainjector.image.tag=$CERT_MANAGER_TAG
        ```

    6. Create a cluster issuer
        ```bash
        kubectl apply -f cluster-issuer.yaml
        ```

    7. Create an ingress route
        ```bash
        kubectl apply -f ingress.yaml --namespace default
        ```

    8. All done! To get the domain name of your instance, execute the following:
        ```bash
        az network public-ip show --ids $PUBLIC_IP_ID --query "[dnsSettings.fqdn]" --output tsv
        ```
