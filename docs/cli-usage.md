# CLI Usage

DriftHound provides a Ruby CLI to automate drift checks and report results to the server. This is ideal for CI/CD pipelines.

## Installation

### Quick Install

You can install the CLI directly without cloning the repo:

```sh
sudo curl -L https://raw.githubusercontent.com/drifthoundhq/drifthound/main/bin/drifthound-cli -o /usr/local/bin/drifthound && sudo chmod +x /usr/local/bin/drifthound
```

This will make the `drifthound` command available globally.

### Docker

You can also run the CLI directly from the published Docker image, without installing Ruby or dependencies locally:

```sh
docker run --rm \
  -v "$(pwd)":/infra \
  -w /infra \
  ghcr.io/drifthoundhq/drifthound:<tag> \
  bin/drifthound-cli --tool=terraform|terragrunt|opentofu|azure \
    --project=PROJECT_KEY \
    --environment=ENV_KEY \
    --token=API_TOKEN \
    --api-url=http://your-drifthound-server \
    --dir=.
```

Replace `<tag>` with the desired image version (e.g., `v0.1.0`).

This mounts your current directory into the container and runs the CLI as if it were installed locally.

## Basic Usage

```sh
drifthound --tool=terraform|terragrunt|opentofu|azure \
  --project=PROJECT_KEY \
  --environment=ENV_KEY \
  --token=API_TOKEN \
  --api-url=http://localhost:3000 \
  --dir=PATH_TO_INFRA_DIR
```

### Example

```sh
drifthound --tool=terragrunt --project=shipping --environment=production \
  --token=YOUR_API_TOKEN --api-url=http://localhost:3000 --dir=.
```

### Docker Example

```sh
docker run --rm -v "$(pwd)":/infra -w /infra ghcr.io/drifthoundhq/drifthound:v0.1.0 \
  bin/drifthound-cli --tool=terragrunt --project=shipping --environment=production \
  --token=YOUR_API_TOKEN --api-url=http://localhost:3000 --dir=.
```

## Command Line Options

| Option            | Required | Description                                  |
|-------------------|----------|----------------------------------------------|
| `--tool`          | Yes      | `terraform`, `terragrunt`, `opentofu`, `azure` (see [Azure](#azure-unmanaged-resources)) or `argocd` (see [Argo CD](#argo-cd-unowned-resources)) |
| `--project`       | Yes      | Project key                                  |
| `--environment`   | Yes      | Environment key                              |
| `--environment-name` | No    | Environment display name. Defaults to the titleized environment key. When given, it also renames an existing environment. |
| `--token`         | Yes      | API token                                    |
| `--api-url`       | Yes      | DriftHound API base URL                      |
| `--dir`           | No       | Directory to run the tool in (default: `.`). Stored in environment on first call only; update via GUI. |
| `--repository`    | No       | Repository URL. **Auto-detected from git** if not provided. Stored in project on first call only; update via GUI. |
| `--branch`        | No       | Repository branch. **Auto-detected from git** if not provided. Stored on every check, and in the project on first call only. |
| `--slack-channel` | No       | Slack Channel to send notifications to       |

The options below apply to `--tool=azure` only.

| Option            | Required | Description                                  |
|-------------------|----------|----------------------------------------------|
| `--subscription`  | Yes      | Azure subscription ID to scan. Repeat it for several subscriptions. |
| `--state-dir`     | One of the two state options | Directory to run `<state-tool> state pull` in. Repeat it for several stacks. |
| `--state-file`    | One of the two state options | A Terraform state file or `terraform show -json` output. Repeat it for several files. |
| `--state-tool`    | No       | `terraform` (default), `tofu` or `terragrunt`. The command used by `--state-dir`. |
| `--include-managed-by` | No  | Also report resources that another Azure service owns (`managedBy`). |

The options below apply to `--tool=argocd` only.

| Option            | Required | Description                                  |
|-------------------|----------|----------------------------------------------|
| `--context`       | No       | kubectl context of the cluster to scan. Defaults to the current context. |
| `--kubeconfig`    | No       | kubeconfig file. Defaults to kubectl's own lookup (or the in-cluster service account). |
| `--kubectl`       | No       | The kubectl binary (default `kubectl`). |
| `--cluster-name`  | No       | Name stored as each row's location. Defaults to the context. |
| `--argocd-context` | No      | Context of the cluster where Argo CD runs, when that is not the scanned cluster (a hub). Needs `--argocd-destination`. |
| `--argocd-kubeconfig` | No   | kubeconfig used to read the Applications. Defaults to `--kubeconfig`. |
| `--argocd-namespace` | No    | Namespace of an Argo CD control plane (default `argocd`). Repeat it for several. |
| `--argocd-destination` | When `--argocd-context` is set | `spec.destination` server or name that means the scanned cluster. Repeat it for several. Default when Argo CD runs in the scanned cluster: `https://kubernetes.default.svc` and `in-cluster`. |
| `--tracking-method` | No     | `annotation` (default, Argo CD 3 default), `label` or `annotation+label`. Must match Argo CD's `application.resourceTrackingMethod`. |
| `--instance-label-key` | No  | The label Argo CD uses for the application name (default `app.kubernetes.io/instance`). Only used with `--tracking-method=label`. |
| `--argocd-installation-id` | No | Only count objects whose `argocd.argoproj.io/installation-id` matches. |
| `--include-secrets` | No     | Also list Secrets (names and types only, never their data). Off by default. |
| `--include-platform-managed` | No | Also report objects that AKS or Kubernetes manage itself. |
| `--exclude-kind`  | No       | A kubectl resource name to skip, such as `widgets.example.com`. Repeat it for several. |
| `--chunk-size`    | No       | `kubectl get --chunk-size` (default 500). |
| `--request-timeout` | No     | `kubectl --request-timeout` (default `120s`). |
| `--concurrency`   | No       | Parallel `kubectl get` calls (default 4, 1 to 16). Use 1 on memory-tight jobs. |

## How It Works

The CLI will:
1. **Auto-detect repository URL and branch** from git (if running in a git repository)
2. Run the specified tool's plan command (e.g., `terraform plan`, `terragrunt plan`)
3. Parse the output to extract drift information
4. Send a drift report to the DriftHound API

The payload includes:
- Drift status (`ok`, `drift`, `error`, `unknown`)
- Resource counts (add, change, destroy)
- Execution duration
- Full plan output
- Working directory (stored in the environment record)
- Repository URL (auto-detected or provided, stored in the project record)
- Branch (auto-detected or provided, stored in the project record)

### Git Auto-Detection

The CLI automatically detects:
- **Repository URL**: From `git remote get-url origin`. SSH URLs are converted to HTTPS format.
- **Branch**: From the current git branch (`git rev-parse --abbrev-ref HEAD`).

You can override auto-detection by explicitly providing `--repository` or `--branch`.

## Advanced Configuration

### Using Environment Variables

Instead of passing options via command line, you can use environment variables:

```sh
export DRIFTHOUND_TOOL=terraform
export DRIFTHOUND_PROJECT=my-infrastructure
export DRIFTHOUND_ENVIRONMENT=production
export DRIFTHOUND_TOKEN=your-api-token
export DRIFTHOUND_API_URL=https://drifthound.example.com
export DRIFTHOUND_SLACK_CHANNEL=#infra-alerts

drifthound --dir=./terraform
```

### Multiple Environments

You can run checks for multiple environments in sequence:

```sh
for env in dev staging production; do
  drifthound --tool=terraform \
    --project=my-infrastructure \
    --environment=$env \
    --token=$DRIFTHOUND_TOKEN \
    --api-url=$DRIFTHOUND_URL \
    --dir=./terraform/$env
done
```

### Conditional Slack Notifications

Only send Slack notifications for production:

```sh
if [ "$ENVIRONMENT" = "production" ]; then
  SLACK_OPTION="--slack-channel=#infra-alerts"
else
  SLACK_OPTION=""
fi

drifthound --tool=terraform \
  --project=my-infrastructure \
  --environment=$ENVIRONMENT \
  --token=$DRIFTHOUND_TOKEN \
  --api-url=$DRIFTHOUND_URL \
  --dir=./terraform \
  $SLACK_OPTION
```

## Supported Tools

### Terraform

```sh
drifthound --tool=terraform \
  --project=my-project \
  --environment=production \
  --token=$TOKEN \
  --api-url=$URL \
  --dir=./terraform
```

The CLI runs `terraform plan -detailed-exitcode` and parses the output.

### Terragrunt

```sh
drifthound --tool=terragrunt \
  --project=my-project \
  --environment=production \
  --token=$TOKEN \
  --api-url=$URL \
  --dir=./terragrunt
```

The CLI runs `terragrunt plan -detailed-exitcode` and parses the output.

### OpenTofu

```sh
drifthound --tool=opentofu \
  --project=my-project \
  --environment=production \
  --token=$TOKEN \
  --api-url=$URL \
  --dir=./tofu
```

The CLI runs `tofu plan -detailed-exitcode` and parses the output.

### Azure Unmanaged Resources

```sh
drifthound --tool=azure \
  --project=my-project \
  --environment=prod-azure \
  --token=$TOKEN \
  --api-url=$URL \
  --subscription=00000000-0000-0000-0000-000000000000 \
  --state-dir=stacks/network \
  --state-dir=stacks/app
```

The CLI lists every resource and resource group in the subscriptions with Azure Resource Graph, reads the resource IDs from your Terraform state, and reports the resources that are in Azure but not in state. Only the unmanaged items are sent to DriftHound: the server never receives Azure credentials or Terraform state.

**Prerequisites** (on the machine that runs the CLI):

- The Azure CLI (`az`) with the `resource-graph` extension (`az extension add --name resource-graph`). The Docker image does not include `az`, so use the installed CLI.
- A signed-in identity (`az login`, or OIDC with `azure/login` in GitHub Actions) with the Reader role on each subscription.
- Initialised state: run `terraform init` in each `--state-dir` first, or export state to files for `--state-file`.

**Fail closed.** If anything fails (a state source cannot be read, an Azure query fails, a requested subscription is not visible to the identity, or no managed IDs are found in state), the CLI posts a check with status `error` and no list. A partial state set would otherwise make everything look unmanaged and raise a false alarm. The error text is in the check's output.

**One environment per source.** Use a separate environment key for Azure, for example `--environment=prod-azure` next to `prod` for Terraform plans. An environment takes its status from its newest check, so mixing sources under one key would make the status flip on every run.

The CLI sends status `ok` when collection succeeds. The server applies the ignore rules and decides the final status: any unmanaged resource that is not ignored makes the check `drift`. See [Azure Unmanaged Resources](azure-unmanaged-resources.md) for the details, including what counts as managed, the built-in ignore list and CI examples.

### Argo CD Unowned Resources

```sh
drifthound --tool=argocd \
  --project=platform \
  --environment=prod-aks-argocd \
  --token=$TOKEN \
  --api-url=$URL \
  --context=prod-aks
```

The CLI lists the objects in a Kubernetes cluster (such as AKS) with `kubectl`, reads the Argo CD Applications, and reports the objects that no Argo CD Application owns: things created with `kubectl apply` or `helm install`, or left behind by a deleted Application. Only those objects are sent to DriftHound. The CLI projects a fixed set of metadata fields, so it never reads Secret data or the `last-applied-configuration` annotation.

**Prerequisites** (on the machine that runs the CLI):

- `kubectl`, signed in to the cluster with read access (see the RBAC section of [Argo CD Unowned Resources](argocd-unowned-resources.md#rbac)). The Docker image does not include `kubectl`.
- Argo CD installed in the scanned cluster, or `--argocd-context` and `--argocd-destination` when Argo CD runs elsewhere.

**Fail closed.** If anything fails (a kind cannot be listed, access is forbidden, the Argo CD CRDs are missing, no Application deploys to this cluster, or an output line is not understood), the CLI posts a check with status `error` and no list, so a green check never hides a gap. Use `--exclude-kind` to skip a kind on purpose.

**One environment per source and per cluster.** Use a key such as `--environment=prod-aks-argocd`. An environment takes its status from its newest check, so mixing sources or clusters under one key would make the status flip.

The CLI sends status `ok` when collection succeeds. The server applies the ignore rules and decides the final status: any unowned object that is not ignored makes the check `drift`. See [Argo CD Unowned Resources](argocd-unowned-resources.md) for what counts as owned, the built-in ignore list, RBAC and CI examples.

## Best Practices

1. **Run checks on a schedule** - Set up cron jobs or CI/CD schedules to check for drift regularly (e.g., every 6 hours)
2. **Use separate environments** - Create different environment keys for dev, staging, and production
3. **Store tokens securely** - Use CI/CD secrets or environment variables, never hardcode tokens
4. **Configure Slack channels per environment** - Use different channels for production vs. non-production alerts
5. **Run in read-only mode** - The CLI only runs `plan`, never `apply`, ensuring safe drift detection
6. **Review raw output** - Check the DriftHound dashboard for full plan output when investigating drift

## Troubleshooting

### Authentication Errors

If you get `401 Unauthorized`:
- Verify your token is correct
- Check that the token hasn't been revoked
- Generate a new token: `bin/rails api_tokens:generate[new-token]`

### Tool Not Found

If you get `command not found` errors:
- Ensure Terraform/Terragrunt/OpenTofu is installed and in your PATH
- Use the Docker image which includes all tools

### API Connection Errors

If you can't connect to the API:
- Verify the API URL is correct and reachable
- Check network/firewall rules
- Ensure the DriftHound server is running

## See Also

- [API Reference](api-usage.md) - Direct API usage without the CLI
- [Slack Notifications](slack-notifications.md) - Configure Slack alerts
