# Lovable components GitOps scaffold

This repository contains two main components:

- `argocd/`: root app-of-apps Application template and resource-group-aware bootstrap script.
- `lovable-components/`: Helm chart rendering the child Argo CD Applications listed in `values.yaml`. Workload charts live under `workloads/`.

The root tracks `main` in this repository. Argo CD renders the parent chart into child Applications, then renders each child's workload chart and values into Kubernetes resources.

## Prerequisites

- Argo CD installed in the `argocd` namespace, including its Application CRD.
- PowerShell with the `Az.ContainerRegistry` and `Az.Aks` modules, signed in to the intended subscription when running bootstrap locally.
- Permission to read container registries in the AKS resource group and invoke/read AKS Run Command results on the intended cluster.
- Argo CD configured with Git repository credentials if this repository is private.
- A private container image and a registry pull secret provisioned separately.

The root uses the `default` Argo CD project. App-of-apps repositories are an admin-level trust boundary; restrict write access and review changes before syncing.

## AKS Argo CD extension

`infra/deployment.json` installs the `Microsoft.ArgoCD` GitOps cluster extension in the `argocd` namespace after the AKS cluster is created. Register the `Microsoft.KubernetesConfiguration` resource provider before deployment and ensure the deployment principal has permission to create Kubernetes extensions.

The extension has no managed identity or workload identity configuration and no Entra SSO integration. The AKS cluster's existing managed identity and workload identity support remain unchanged. Argo CD ingress is disabled and its server uses a `ClusterIP` service; the cluster's separate Istio ingress configuration is unchanged.

Redis HA is disabled to fit the initial three-node pool (the extension's default HA installation requires four nodes). The system pool's `CriticalAddonsOnly` taint is explicitly removed so that AKS Run Command pods can schedule. This also allows ordinary application pods onto the system pool; use a separate user pool if system-workload isolation is required.

Access the UI locally using port forwarding from a machine that can reach the Kubernetes API:

```powershell
kubectl --namespace argocd port-forward service/argocd-server 8080:443
```

Open `https://localhost:8080` and authenticate using Argo CD's local admin credentials, retrieved through your approved secret-access process. The initial server certificate is self-signed. Port forwarding still requires `kubectl` and network access to the private API; automated bootstrap does not.

See the [Azure Argo CD extension documentation](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd) for prerequisites and supported configuration.

## Automatic post-deployment bootstrap

The ARM template includes an `AzurePowerShell` deployment script that downloads and runs `argocd/bootstrap.ps1`, with `argocd/application.yaml` downloaded alongside it. Its dependencies wait for the Argo CD extension, bootstrap role assignments, and all other template resources to finish before executing.

The deployment script service signs in with a separate user-assigned managed identity. This is not an identity for the Argo CD extension. The bootstrap identity receives:

- Resource-group **Reader**, to discover the only ACR's login server.
- A custom role assigned only to this AKS cluster, allowing cluster read, `runcommand/action`, and `commandResults/read`. It cannot update or delete the Azure AKS resource. Run Command itself executes privileged Kubernetes operations, so treat access to this identity as cluster-admin-equivalent.

The template's deployment principal must be able to create custom roles and role assignments, assign the managed identity (Managed Identity Operator or equivalent), and create deployment scripts plus their supporting storage account and container instance. Register `Microsoft.ManagedIdentity`, `Microsoft.Authorization`, `Microsoft.Resources`, `Microsoft.Storage`, and `Microsoft.ContainerInstance`, in addition to the AKS/extension providers, where required.

Parameters:

- `bootstrap_artifacts_base_uri`: defaults to `https://raw.githubusercontent.com/danieledemo1/lvb-poc/main/argocd`. Both files must be published before deploying. For reproducible deployments, replace `main` with a commit SHA. A private Git repository cannot be downloaded anonymously: publish these two non-secret artifacts at an accessible HTTPS location and override this parameter.
- `bootstrap_force_update_tag`: defaults to the current UTC timestamp, rerunning bootstrap on every deployment. Supply an unchanged value to avoid rerunning an otherwise unchanged script.

The script uses `Get-AzContainerRegistry` and `Invoke-AzAksRunCommand`, so it needs neither Azure CLI nor local Kubernetes credentials. The rendered manifest is uploaded as a ZIP attachment. The in-cluster command waits for the Application CRD, applies the root Application, and reads it back; both failed operations and nonzero remote exit codes fail the deployment script. Temporary attachment files are removed even on failure. This verifies creation of the root Application, not successful synchronization of every child workload.

Run Command requires schedulable cluster capacity and is subject to AKS command-pod scheduling/time limits. The deployment script uses public Azure management endpoints rather than connecting directly to the private API. Supporting execution resources are cleaned up on success and retained temporarily on failure for diagnostics.

## Configure the first component

Edit `lovable-components/workloads/first-component/values.yaml`:

- Set `image.repository` and `image.tag` to your actual private image.
- Set `imagePullSecrets` to an existing Kubernetes registry secret.
- Adjust `service.targetPort` to match the port your image listens on (default: `8080`).

Provision the `private-registry` secret in the `lovable` namespace using your secret-management process before the workload starts. The secret must have type `kubernetes.io/dockerconfigjson` and credentials for the registry hostname. Create the namespace first if needed. No registry credentials belong in this repository.

Push these files to `main` before deploying or bootstrapping; Argo CD reads Git, not your local working tree.

## Bootstrap using the resource group's container registry

```powershell
Connect-AzAccount
Set-AzContext -Subscription 'my-subscription'
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group' -RenderOnly
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group' -ClusterName 'my-aks-cluster'
```

Pass the resource group containing the AKS cluster and its ACR (not the AKS-managed node resource group). The script uses `Get-AzContainerRegistry` in the active Azure PowerShell subscription and requires exactly one registry in that group. It populates `$registryUrl` from that registry's `LoginServer` and replaces only `${REGISTRY_URL}` in the root Application before applying it through AKS Run Command to `-ClusterName`. Zero or multiple registries, Azure errors, or an invalid login server stop the script. `-RenderOnly` still queries Azure but does not require a cluster name or apply anything to Kubernetes. Do not apply the unrendered template directly.

Argo CD does **not** substitute arbitrary environment variables in Git-hosted Helm values. Instead, the script persists the discovered registry hostname as a Helm parameter on the root Application. The parent chart passes it to each child as `image.registry`; the workload renders an image such as `myregistry.azurecr.io/lovable/first-component:0.1.0`. Registry authentication is handled independently by the workload's `imagePullSecrets`.

`REGISTRY_URL` does not need to be set in the local environment. Rerun the bootstrap script to refresh the root Application if the registry changes. No local kubectl context, direct private API access, Argo CD plugin, or repo-server environment changes are required.

Both root and child Applications enable automatic sync and self-healing. Automatic pruning and cascading-deletion finalizers are deliberately omitted: removing an app definition does not automatically delete its Application or workloads. Review and remove obsolete resources explicitly.

## Add a component

1. Add a workload Helm chart beneath `lovable-components/workloads/`, with its own manifests and values.
2. Add an entry to `lovable-components/values.yaml` under `applications`, specifying a unique `name`, destination `namespace`, and repository-relative chart `path`.
3. Use the `image.registry` value in the new workload chart so it receives the bootstrap registry hostname.
4. Provision its registry pull secret in its destination namespace, then commit and push.

The parent renders all listed app definitions. `workloads/` is intentionally not named `charts/`, so Helm does not render workload charts as parent-chart dependencies.

## Local validation

Run the bootstrap tests without Azure credentials or cluster access; Azure operations are mocked:

```powershell
.\argocd\tests\bootstrap.Tests.ps1
```

Validate the parent and workload Helm charts:

```powershell
helm lint .\lovable-components --set-string registry.url=registry.example.com
helm template lovable-components .\lovable-components --namespace argocd --set-string registry.url=registry.example.com
helm lint .\lovable-components\workloads\first-component --set-string image.registry=registry.example.com
helm template first-component .\lovable-components\workloads\first-component --namespace lovable --set-string image.registry=registry.example.com
```

The registry values intentionally have no default: rendering without an explicit registry fails rather than falling back to a public registry.
