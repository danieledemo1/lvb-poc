# Lovable components GitOps scaffold

This repository contains two main components:

- `argocd/`: root app-of-apps Application template and resource-group-aware bootstrap script.
- `lovable-components/`: Helm chart rendering the child Argo CD Applications listed in `values.yaml`. Workload charts live under `workloads/`.

The root tracks `main` in this repository. Argo CD renders the parent chart into child Applications, then renders each child's workload chart and values into Kubernetes resources.

## Prerequisites

- Argo CD installed in the `argocd` namespace, including its Application CRD.
- PowerShell with the `Az.ContainerRegistry` and `Az.Aks` modules, signed in to the intended subscription when running bootstrap locally.
- Permission to read container registries in the AKS resource group, invoke/read AKS Run Command results, and access Kubernetes resources on the intended cluster. On this Azure-RBAC-enabled cluster, bootstrap uses **Azure Kubernetes Service RBAC Cluster Admin** at the AKS resource scope.
- Argo CD configured with Git repository credentials if this repository is private.
- A private container image and a registry pull secret provisioned separately.

The root uses the `default` Argo CD project. App-of-apps repositories are an admin-level trust boundary; restrict write access and review changes before syncing.

## AKS Argo CD extension

`infra/deployment.json` installs the `Microsoft.ArgoCD` GitOps cluster extension in the `argocd` namespace after the AKS cluster is created. Register the `Microsoft.KubernetesConfiguration` resource provider before deployment and ensure the deployment principal has permission to create Kubernetes extensions.

The extension has no managed identity or workload identity configuration and no Entra SSO integration. The AKS cluster's existing managed identity and workload identity support remain unchanged. The chart's built-in ingress is disabled and its server uses a `ClusterIP` service. The shared Istio ingress component exposes the console at `http://<ingress-public-ip>/`.

The extension sets `server.insecure=true`, `server.rootpath=""`, and `server.basehref=/` through `configs.params` (literal dots in these parameter names are escaped in the ARM JSON keys). This enables HTTP on service port `80` without an HTTPS redirect and serves Argo CD at the root path. The explicit empty root path clears the previous `/argocd` context on existing installations. Authentication remains enabled, but public HTTP does not encrypt credentials or session traffic; use only in a trusted test environment and use HTTPS for production.

Redis HA is disabled to fit the initial three-node pool (the extension's default HA installation requires four nodes). The system pool's `CriticalAddonsOnly` taint is explicitly removed so that AKS Run Command pods can schedule. This also allows ordinary application pods onto the system pool; use a separate user pool if system-workload isolation is required.

Access the UI locally using port forwarding from a machine that can reach the Kubernetes API:

```powershell
kubectl --namespace argocd port-forward service/argocd-server 8080:80
```

Open `http://localhost:8080/` and authenticate using Argo CD's local admin credentials, retrieved through your approved secret-access process. Port forwarding still requires `kubectl` and network access to the private API; automated bootstrap does not.

See the [Azure Argo CD extension documentation](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd) for prerequisites and supported configuration.

## AKS App Configuration extension

The template also installs the `Microsoft.AppConfiguration` Kubernetes Provider extension in `azappconfig-system`, with automatic minor-version upgrades and workload identity support.

Installing the extension alone does not connect a store. The post-deployment bootstrap applies `argocd/appconfiguration.yaml`, which creates the `lovable` namespace, an `appconfig-provider` service account, and a `lovable-appconfig` `AzureAppConfigurationProvider` resource. The template supplies the actual endpoint of its App Configuration store and the client/tenant IDs of a dedicated managed identity.

That identity has **App Configuration Data Reader** only on the store created by this template. Its federated credential trusts this cluster's OIDC issuer and exactly `system:serviceaccount:lovable:appconfig-provider`. No connection string or client secret is needed; the Argo CD extension and bootstrap identity permissions are unchanged.

The provider copies the existing unlabeled `lovableVersion` key into the `lovable-config` ConfigMap in the `lovable` namespace, checking for updates every minute. Workloads can consume that ConfigMap; this scaffold does not automatically mount it or inject it into application pods. Edit the provider's selectors to expose additional keys. Key Vault secret resolution is not enabled.

Bootstrap waits for the provider CRD and initial synchronization to complete, then verifies that the target ConfigMap exists. A connection/authentication failure causes bootstrap to fail rather than reporting a successful connection. Azure role assignments may take several minutes to propagate; the synchronization wait is bounded to ten minutes.

The extension namespace must be allowed to use service account tokens. If restrictive Azure Policies apply, review the [App Configuration extension requirements](https://learn.microsoft.com/azure/aks/azure-app-configuration).

## Automatic post-deployment bootstrap

The ARM template includes an `AzurePowerShell` deployment script that downloads and runs `argocd/bootstrap.ps1`, with `argocd/application.yaml` and `argocd/appconfiguration.yaml` downloaded alongside it. Its dependencies wait for both Kubernetes extensions, identity credentials and role assignments, and all other template resources to finish before executing.

The deployment script service signs in with a separate user-assigned managed identity. This is not an identity for the Argo CD extension. The bootstrap identity receives:

- Resource-group **Reader**, to discover the only ACR's login server.
- A custom role assigned only to this AKS cluster, allowing cluster read, `runcommand/action`, and `commandResults/read`. These management-plane permissions authorize command invocation, not the Kubernetes operations inside it.
- **Azure Kubernetes Service RBAC Cluster Admin** (`b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b`), assigned only to this AKS cluster. This supplies Kubernetes data-plane access for cluster-scoped CRD reads/watches, namespace creation/update, service-account and custom-resource creation/update, and synchronization checks. It grants full control of Kubernetes resources in all namespaces; restrict access to this identity and the bootstrap artifacts. It does not allow updating or deleting the Azure AKS resource. This is not the similarly named **Azure Kubernetes Service Cluster Admin Role**, which only grants admin credential retrieval and is unsuitable when local accounts are disabled.

The script explicitly depends on the data-plane role assignment. Role-assignment completion does not mean authorization has propagated: bootstrap polls CRD-read authorization for up to five minutes before accessing either CRD, then fails with an explicit RBAC diagnostic if access is still denied. See [AKS Kubernetes authorization](https://learn.microsoft.com/azure/aks/manage-azure-rbac) for the distinction between management-plane and Kubernetes permissions.

The template's deployment principal must be able to create custom roles and role assignments, assign the managed identity (Managed Identity Operator or equivalent), and create deployment scripts plus their supporting storage account and container instance. Register `Microsoft.ManagedIdentity`, `Microsoft.Authorization`, `Microsoft.Resources`, `Microsoft.Storage`, and `Microsoft.ContainerInstance`, in addition to the AKS/extension providers, where required.

Parameters:

- `bootstrap_artifacts_base_uri`: defaults to `https://raw.githubusercontent.com/danieledemo1/lvb-poc/main/argocd`. All three files must be published before deploying. For reproducible deployments, replace `main` with a commit SHA. A private Git repository cannot be downloaded anonymously: publish these non-secret artifacts at an accessible HTTPS location and override this parameter.
- `bootstrap_force_update_tag`: defaults to the current UTC timestamp, rerunning bootstrap on every deployment. Supply an unchanged value to avoid rerunning an otherwise unchanged script.

The script uses `Get-AzContainerRegistry` and `Invoke-AzAksRunCommand`, so it needs neither Azure CLI nor local Kubernetes credentials. The rendered manifests are uploaded as a ZIP attachment. The in-cluster command waits for the CRDs, applies the App Configuration resources and root Application, and checks their results; both failed operations and nonzero remote exit codes fail the deployment script. Temporary attachment files are removed even on failure. This verifies creation of the root Application and initial App Configuration synchronization, not successful synchronization of every child workload.

Run Command requires schedulable cluster capacity and is subject to AKS command-pod scheduling/time limits. The deployment script uses public Azure management endpoints rather than connecting directly to the private API. Supporting execution resources are cleaned up on success and retained temporarily on failure for diagnostics.

### Deployment failure checklist

- `Forbidden` on a CRD with "User does not have access to the resource in Azure" indicates missing Kubernetes data-plane authorization, not a private-network connectivity failure. Verify the denied object ID matches the bootstrap managed identity's **principal ID** and that its RBAC Cluster Admin assignment is at the AKS resource scope. Keep both that assignment and the Run Command custom role.
- Publish the updated bootstrap script and both YAML manifests at `bootstrap_artifacts_base_uri`, then redeploy the updated ARM template. The default `bootstrap_force_update_tag` reruns the script; change it explicitly if you previously pinned it. An old downloaded script will not include the authorization wait.
- Both extension installations must succeed and establish their CRDs. The bootstrap still waits for CRD establishment after authorization is available.
- App Configuration additionally needs the existing OIDC/workload-identity settings, exact federated service-account subject, store-scoped Data Reader assignment, and outbound HTTPS/DNS access to Microsoft Entra and the store. Its separate synchronization wait covers initial authentication/reconciliation; cluster-admin access does not grant store data access.
- The Run Command pod needs schedulable CPU/memory, no blocking taint or admission policy, and working cluster networking. Deployment-script execution needs access to Azure management endpoints and the HTTPS bootstrap artifacts. Microsoft [documents Run Command as not intended for programmatic access](https://learn.microsoft.com/azure/aks/access-private-cluster#limitations-and-considerations); this template retains the requested mechanism, but sustained automation should use a runner with private API connectivity.
- Private Git credentials, the actual workload image, and its configured pull secret remain separate prerequisites. Bootstrap verifies the root Application and App Configuration synchronization, not child-Application health.

## Configure the first component

Edit `lovable-components/workloads/first-component/values.yaml`:

- The default image is `<registry>/lovable/cyber-hello:latest`; override `image.repository` and `image.tag` if needed.
- Set `imagePullSecrets` to an existing Kubernetes registry secret.
- Adjust `service.targetPort` to match the port your image listens on (default: `8080`).
- Istio ingress is enabled by default: the component's VirtualService redirects `/app` to `/app/` and routes `/app/` and its descendants to its ClusterIP service through the shared Gateway referenced by `ingress.gateway` (default: `lovable/istio-ingress`). It strips the `/app` prefix: `/app/assets/main.js` reaches the backend as `/assets/main.js`. Other paths go to Argo CD.
- The application must generate URLs relative to `/app/` (or use `/app/` as its public base) and configure its client-side router accordingly. Istio only rewrites incoming request paths, not HTML, asset URLs, cookies, or response redirects; absolute URLs such as `/assets/main.js` would reach Argo CD instead. Application source is not included in this repository.
- `ingress.hosts` defaults to `["*"]`, allowing access by public IP or any hostname. Set it to your DNS hostname(s) to restrict host routing, and point those names at the gateway's public IP. This is plain HTTP without TLS or ingress authentication.
- Set `ingress.enabled: false` to omit the component's VirtualService, or override `ingress.gateway` when using a different shared Gateway (`namespace/name`).

Provision the `private-registry` secret in the `lovable` namespace using your secret-management process before the workload starts. The secret must have type `kubernetes.io/dockerconfigjson` and credentials for the registry hostname. Create the namespace first if needed. No registry credentials belong in this repository.

### Shared Istio ingress component

The parent chart also deploys the `istio-ingress` Argo CD Application from `lovable-components/workloads/istio-ingress` into `lovable`. This configuration-only chart owns the shared Istio Gateway listening on HTTP port `80`; it does not install an Istio control plane, gateway proxy pods, or a LoadBalancer Service. Those remain managed by the AKS Istio add-on. No application image or registry pull secret is needed for this component.

Configure its `gateway.selector` and `gateway.hosts` in `lovable-components/workloads/istio-ingress/values.yaml`. The default selector is `istio: aks-istio-ingressgateway-external`, and the default hosts allow any hostname. When restricting hosts, ensure each workload's `ingress.hosts` is also allowed by the shared Gateway. Additional workloads should create their own VirtualService referencing `lovable/istio-ingress`, with nonconflicting host/path routes.

The same chart creates an Argo CD VirtualService by default (`argocd.enabled: true`). It forwards requests unchanged to `argocd-server.argocd.svc.cluster.local:80` using a route without a `match` field. Istio places this catch-all last when merging gateway-bound VirtualServices, leaving the first component's `/app` redirect and `/app/` route ahead of it. Thus `/` and Argo CD's API and asset paths reach Argo CD, while `/application` does not accidentally match the app route. It uses the shared Gateway's hosts, so the public IP works without DNS with the default wildcard. Do not add a competing `prefix: /` rule or another catch-all for the same hosts and gateway.

Following the [Argo CD Istio ingress documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#istio), keep `argocd.service.port: 80` for the HTTP backend with `server.insecure=true`; routing to port `443` does not configure Istio to originate TLS. The documentation's HTTPS listener requires a TLS certificate; this scaffold intentionally retains its existing HTTP-only test gateway.

For an existing cluster, apply the updated infrastructure template first to clear Argo CD's old `/argocd` root path and set its base href to `/`, and wait for `argocd-server` to roll out before syncing `istio-ingress` and `first-component`. If the extension updates its ConfigMap without restarting the server, run `kubectl --namespace argocd rollout restart deployment/argocd-server`, then `kubectl --namespace argocd rollout status deployment/argocd-server`. These server parameters are read at startup. Changing the Istio rule alone will not reset Argo CD's base path or disable HTTPS redirects.

The Istio add-on, its Gateway/VirtualService CRDs, and the external ingress gateway must be installed before syncing these components. `infra/deployment.json` defaults `cluster_ingress_public_access` to `true`; apply the infrastructure template with this parameter enabled for an existing internal-only cluster. An explicit `false` still selects the internal gateway instead, requiring a matching shared `gateway.selector`. The private Kubernetes API setting is unchanged.

For an existing installation, sync `istio-ingress`, then sync `first-component`. The parent list does not enforce child synchronization order. Because automatic pruning is disabled, explicitly remove the old workload-owned Gateway after both syncs:

```powershell
kubectl --namespace lovable delete gateway.networking.istio.io first-component
```

Do not delete the AKS-managed gateway Deployment or Service.

After infrastructure deployment and Argo CD synchronization, retrieve the gateway address and test HTTP access from outside the cluster:

```powershell
kubectl --namespace aks-istio-ingress get service aks-istio-ingressgateway-external
$ingressIp = kubectl --namespace aks-istio-ingress get service aks-istio-ingressgateway-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
curl.exe --fail "http://${ingressIp}:80/"
curl.exe --fail "http://${ingressIp}:80/api/version"
curl.exe --fail --location "http://${ingressIp}:80/app"
```

Use the gateway Service's assigned IP; the separately created public IP is not automatically bound to that Service. If using a restricted `ingress.hosts` value before DNS is configured, supply the matching `Host` header when testing.

Push these files to `main` before deploying or bootstrapping; Argo CD reads Git, not your local working tree.

## Bootstrap using the resource group's container registry

```powershell
Connect-AzAccount
Set-AzContext -Subscription 'my-subscription'
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group' -RenderOnly
.\argocd\bootstrap.ps1 -ResourceGroupName 'my-aks-resource-group' -ClusterName 'my-aks-cluster'
```

Pass the resource group containing the AKS cluster and its ACR (not the AKS-managed node resource group). The script uses `Get-AzContainerRegistry` in the active Azure PowerShell subscription and requires exactly one registry in that group. It populates `$registryUrl` from that registry's `LoginServer` and replaces only `${REGISTRY_URL}` in the root Application before applying it through AKS Run Command to `-ClusterName`. Zero or multiple registries, Azure errors, or an invalid login server stop the script. `-RenderOnly` still queries Azure but does not require a cluster name or apply anything to Kubernetes. Do not apply the unrendered template directly.

The ARM deployment additionally supplies `-AppConfigurationEndpoint`, `-AppConfigurationClientId`, and `-AppConfigurationTenantId`. Supply all three together when manually bootstrapping the App Configuration connection; omitting all three preserves root-Application-only bootstrap. These values must correspond to the store and federated identity provisioned by this template.

Argo CD does **not** substitute arbitrary environment variables in Git-hosted Helm values. Instead, the script persists the discovered registry hostname as a Helm parameter on the root Application. The parent chart passes it to each child as `image.registry`; the workload renders an image such as `myregistry.azurecr.io/lovable/cyber-hello:latest`. Registry authentication is handled independently by the workload's `imagePullSecrets`.

`REGISTRY_URL` does not need to be set in the local environment. Rerun the bootstrap script to refresh the root Application if the registry changes. No local kubectl context, direct private API access, Argo CD plugin, or repo-server environment changes are required.

Both root and child Applications enable automatic sync and self-healing. Automatic pruning and cascading-deletion finalizers are deliberately omitted: removing an app definition does not automatically delete its Application or workloads. Review and remove obsolete resources explicitly.

## Add a component

1. Add a workload Helm chart beneath `lovable-components/workloads/`, with its own manifests and values.
2. Add an entry to `lovable-components/values.yaml` under `applications`, specifying a unique `name`, destination `namespace`, and repository-relative chart `path`.
3. For image-based workloads, use the `image.registry` value in the new workload chart so it receives the bootstrap registry hostname.
4. Provision its registry pull secret in its destination namespace if needed, then commit and push.

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
helm lint .\lovable-components\workloads\istio-ingress
helm template istio-ingress .\lovable-components\workloads\istio-ingress --namespace lovable
```

The registry values intentionally have no default: rendering without an explicit registry fails rather than falling back to a public registry.
