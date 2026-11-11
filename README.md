# Lovable components GitOps scaffold

This repository contains two main components:

- `argocd/`: root app-of-apps Application template and resource-group-aware bootstrap script.
- `lovable-components/`: Helm chart rendering the child Argo CD Applications listed in `values.yaml`. Workload charts live under `workloads/`.

The root tracks `main` in this repository. Argo CD renders the parent chart into child Applications, then renders each child's workload chart and values into Kubernetes resources.

## Prerequisites

- Argo CD installed in the `argocd` namespace, including its Application CRD.
- `kubectl` configured for the intended cluster and PowerShell available locally.
- Azure CLI installed and signed in to the intended subscription, with permission to list container registries in the AKS resource group.
- Argo CD configured with Git repository credentials if this repository is private.
- A private container image and a registry pull secret provisioned separately.

The root uses the `default` Argo CD project. App-of-apps repositories are an admin-level trust boundary; restrict write access and review changes before syncing.

## AKS Argo CD extension

`infra/deployment.json` installs the `Microsoft.ArgoCD` GitOps cluster extension in the `argocd` namespace after the AKS cluster is created. Register the `Microsoft.KubernetesConfiguration` resource provider before deployment and ensure the deployment principal has permission to create Kubernetes extensions.

The extension has no managed identity or workload identity configuration and no Entra SSO integration. The AKS cluster's existing managed identity and workload identity support remain unchanged. Argo CD ingress is disabled and its server uses a `ClusterIP` service; the cluster's separate Istio ingress configuration is unchanged.

Redis HA is disabled to fit the initial three-node pool (the extension's default HA installation requires four nodes). Global tolerations allow the Argo CD components to run on the existing `CriticalAddonsOnly`-tainted system pool.

Access the UI locally using port forwarding from a machine that can reach the Kubernetes API:

```powershell
kubectl --namespace argocd port-forward service/argocd-server 8080:443
```

Open `https://localhost:8080` and authenticate using Argo CD's local admin credentials, retrieved through your approved secret-access process. The initial server certificate is self-signed. The extension installs Argo CD only; run the bootstrap script below separately to create this repository's root Application.

See the [Azure Argo CD extension documentation](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd) for prerequisites and supported configuration.

## Configure the first component

Edit `lovable-components/workloads/first-component/values.yaml`:

- Set `image.repository` and `image.tag` to your actual private image.
- Set `imagePullSecrets` to an existing Kubernetes registry secret.
- Adjust `service.targetPort` to match the port your image listens on (default: `8080`).

Provision the `private-registry` secret in the `lovable` namespace using your secret-management process before the workload starts. The secret must have type `kubernetes.io/dockerconfigjson` and credentials for the registry hostname. Create the namespace first if needed. No registry credentials belong in this repository.

Push these files to `main` before bootstrapping; Argo CD reads Git, not your local working tree.

## Bootstrap using the resource group's container registry

```powershell
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group' -RenderOnly
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group'
```

Pass the resource group containing the AKS cluster and its ACR (not the AKS-managed node resource group). The script uses `az acr list` in the active Azure CLI subscription and requires exactly one registry in that group. It populates `$registryUrl` from that registry's `loginServer` and replaces only `${REGISTRY_URL}` in the root Application before applying it to the current kubectl context. Zero or multiple registries, Azure CLI errors, or an invalid login server stop the script. `-RenderOnly` still queries Azure but does not apply anything to Kubernetes. Do not apply the unrendered template directly.

Argo CD does **not** substitute arbitrary environment variables in Git-hosted Helm values. Instead, the script persists the discovered registry hostname as a Helm parameter on the root Application. The parent chart passes it to each child as `image.registry`; the workload renders an image such as `myregistry.azurecr.io/lovable/first-component:0.1.0`. Registry authentication is handled independently by the workload's `imagePullSecrets`.

`REGISTRY_URL` no longer needs to be set in the local environment. Rerun the bootstrap script to refresh the root Application if the registry changes. Ensure the current kubectl context points to the AKS cluster in the supplied resource group. No Argo CD plugin or repo-server environment changes are required.

Both root and child Applications enable automatic sync and self-healing. Automatic pruning and cascading-deletion finalizers are deliberately omitted: removing an app definition does not automatically delete its Application or workloads. Review and remove obsolete resources explicitly.

## Add a component

1. Add a workload Helm chart beneath `lovable-components/workloads/`, with its own manifests and values.
2. Add an entry to `lovable-components/values.yaml` under `applications`, specifying a unique `name`, destination `namespace`, and repository-relative chart `path`.
3. Use the `image.registry` value in the new workload chart so it receives the bootstrap registry hostname.
4. Provision its registry pull secret in its destination namespace, then commit and push.

The parent renders all listed app definitions. `workloads/` is intentionally not named `charts/`, so Helm does not render workload charts as parent-chart dependencies.

## Local Helm validation

```powershell
helm lint .\lovable-components --set-string registry.url=registry.example.com
helm template lovable-components .\lovable-components --namespace argocd --set-string registry.url=registry.example.com
helm lint .\lovable-components\workloads\first-component --set-string image.registry=registry.example.com
helm template first-component .\lovable-components\workloads\first-component --namespace lovable --set-string image.registry=registry.example.com
```

The registry values intentionally have no default: rendering without an explicit registry fails rather than falling back to a public registry.
