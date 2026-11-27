# Azure Unmanaged Resources

DriftHound can report Azure resources that exist in your subscriptions but are not managed by Terraform. These are resources someone created by hand, or that were removed from code without being deleted. The report appears next to your plan drift: an environment that has unmanaged resources shows `DRIFT`.

## How it works

1. The CLI reads the resource IDs out of your Terraform state.
2. It lists everything in the subscriptions with Azure Resource Graph (`az graph query`).
3. It reports the resources that are in Azure but not in state, and sends only those to DriftHound.
4. The server applies the ignore rules and sets the final status.

Collection and comparison both happen on the machine that runs the CLI. The DriftHound server never holds Azure credentials or Terraform state, which can contain secrets, and it never receives the full inventory.

## What counts as managed

- A resource is managed when its ID is the `id` attribute of a **managed** resource in state. Data sources do not count.
- IDs are compared without case and without a trailing slash, because Azure IDs are case-insensitive.
- Only `id` attributes that start with `/subscriptions/` are used. IDs are not split (for example on `|`) and other `*_id` attributes are not scanned, because that would wrongly mark other resources as managed.
- Both `terraform show -json` output and raw state (as printed by `terraform state pull`) are read. Terraform state version 3 is not supported.
- Resource groups are checked too, so a resource group that Terraform does not manage is reported.

### The `managedBy` rule

Some resources are created and owned by another Azure service, for example the node resource group of an AKS cluster. By default the CLI skips:

- a resource whose `managedBy` property is set, and
- every resource inside a resource group whose `managedBy` is set.

Both checks are needed: the contents of an AKS `MC_*` resource group do not carry `managedBy` themselves, only the group does. Pass `--include-managed-by` to report them anyway. The CLI prints how many resources it skipped.

## Built-in ignore list

The server ignores these names by default. They are read-only, apply to the `azure` source, and match without case. They are shown on the environment page and returned by the ignore rules API.

| Pattern | What it covers |
|---------|----------------|
| `/subscriptions/*/resourceGroups/NetworkWatcherRG` | Network Watcher resource group |
| `/subscriptions/*/resourceGroups/NetworkWatcherRG/*` | Contents of NetworkWatcherRG |
| `*/providers/Microsoft.Network/networkWatchers/NetworkWatcher_*` | Regional Network Watchers |
| `/subscriptions/*/resourceGroups/MC_*` | AKS node resource group and its contents |
| `/subscriptions/*/resourceGroups/DefaultResourceGroup-*` | Azure Monitor / Defender default resource group |
| `*/providers/Microsoft.OperationalInsights/workspaces/DefaultWorkspace-*` | Default Log Analytics workspaces |
| `/subscriptions/*/resourceGroups/AzureBackupRG_*` | Azure Backup restore point collections |
| `/subscriptions/*/resourceGroups/cloud-shell-storage-*` | Cloud Shell storage |
| `*/providers/Microsoft.Sql/servers/*/databases/master` | SQL `master` database |
| `*/providers/microsoft.alertsmanagement/smartDetectorAlertRules/Failure Anomalies - *` | Application Insights smart detector rules |
| `*/providers/microsoft.insights/actiongroups/Application Insights Smart Detection` | Smart Detection action group |

There is deliberately no blanket rule for managed identities: it would hide real unmanaged identities. The AKS managed identities live in the `MC_*` group and are covered by that rule. A resource group that you named `MC_something` yourself is also hidden by the `MC_*` rule.

## Your own ignore rules

Add rules for resources you know about. A rule belongs to one environment and has a field (`identifier` by default, or `resource_type`, `name`, `scope`, `location`), a match type, a pattern and an optional note.

- `exact` compares the whole value without case.
- `glob` supports `*` (matches any characters, including `/`), `?` and `[abc]`. Braces are literal. There is no regex.

Examples:

| Pattern | Match | Effect |
|---------|-------|--------|
| `*/resourceGroups/tmp-*` | `glob` on `identifier` | Everything in resource groups named `tmp-...` |
| `*/providers/Microsoft.Insights/components/*` | `glob` on `identifier` | All Application Insights components |
| `scratch-*` | `glob` on `name` | Anything named `scratch-...` |

**In the web UI**, open the environment page and expand a check with a list of unmanaged resources. Admins see an **Ignore** button on each row, which adds an exact rule for that identifier. Admins can also add and delete rules in the **Unmanaged resource ignore rules** section. **From the API**, `write` tokens can manage rules; see [API Usage](api-usage.md#ignore-rules).

**Rules apply from the next check.** Stored checks, their status and the history are never rewritten. Every received row is stored, including ignored ones, with the reason it was ignored (`Built-in: ...` or `Rule #id: ...`), so you can always see what was hidden and why. Deleting a rule makes those resources show up again from the next check. A rule applies to the source it names, or to all sources when none is set.

## Security

- No Azure credentials and no Terraform state are sent to DriftHound.
- The unmanaged list reveals subscription IDs, resource names and tags. In the web UI it is shown only to users who may see plan output (`PLAN_OUTPUT_MIN_ROLE`, see [Configuration](configuration.md#plan_output_min_role)); in the API only `read_plans` and `write` tokens receive it. Counts are visible to everyone who can see the environment.
- Managing ignore rules in the web UI is admin only.

## Limits and retention

- At most 5,000 unmanaged resources per check. The CLI sends the first 5,000 in identifier order and says in the check output how many it dropped; the server rejects more than 5,000 with `422`.
- Identifiers are limited to 1,024 characters (longer ones are skipped and counted), and metadata to 2,048 bytes. When a resource's tags would exceed the metadata limit, the CLI drops them and sets `tags_truncated`.
- The check output lists the first 200 identifiers. The web UI shows up to 1,000 rows per list; use the API for more.
- Rows are deleted with their check, so they follow `DRIFT_CHECK_RETENTION_DAYS`. See the storage note in [Configuration](configuration.md#data-retention).
- Dashboard charts count checks from all sources. To keep an Azure environment out of the charts, use the existing **Exclude from Metrics** setting.

## Running it in CI

### GitHub Actions

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  azure-unmanaged:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
      - run: az extension add --name resource-graph
      - name: Initialise each stack
        run: |
          for stack in stacks/net stacks/app; do
            terraform -chdir="$stack" init -input=false
          done
      - name: Report unmanaged resources
        run: |
          curl -fsSL https://raw.githubusercontent.com/drifthoundhq/drifthound/main/bin/drifthound-cli -o drifthound
          chmod +x drifthound
          ./drifthound --tool=azure \
            --project=my-project \
            --environment=prod-azure \
            --token=${{ secrets.DRIFTHOUND_TOKEN }} \
            --api-url=${{ vars.DRIFTHOUND_URL }} \
            --subscription=${{ secrets.AZURE_SUBSCRIPTION_ID }} \
            --state-dir=stacks/net \
            --state-dir=stacks/app
```

The identity needs the Reader role on the subscription, plus read access to the Terraform state backend.

### Azure DevOps

```yaml
steps:
  - task: AzureCLI@2
    inputs:
      azureSubscription: my-service-connection
      scriptType: bash
      scriptLocation: inlineScript
      inlineScript: |
        az extension add --name resource-graph
        terraform -chdir=stacks/net init -input=false
        curl -fsSL https://raw.githubusercontent.com/drifthoundhq/drifthound/main/bin/drifthound-cli -o drifthound
        chmod +x drifthound
        ./drifthound --tool=azure \
          --project=my-project \
          --environment=prod-azure \
          --token=$(DRIFTHOUND_TOKEN) \
          --api-url=$(DRIFTHOUND_URL) \
          --subscription=$(AZURE_SUBSCRIPTION_ID) \
          --state-dir=stacks/net
```

## Troubleshooting

**The check is `error`.** Read the check output. Typical causes: `az` is not signed in or lacks the `resource-graph` extension, a state directory is not initialised, or the identity cannot see a requested subscription.

**Everything is reported as unmanaged.** The state is probably empty or from the wrong directory. The CLI fails with an error when it finds no managed IDs at all; if only some stacks are missing from `--state-dir`, their resources are reported. Add every stack that manages resources in the subscription.

**A new resource is reported even though Terraform created it.** Azure Resource Graph is eventually consistent, and a resource can look unmanaged for a short time. Terraform IDs that differ from the Azure ID beyond case (some providers) also show up; add an ignore rule for them.

**A resource is missing from the report.** Resource Graph only returns what the identity can read. Reader access on a resource group instead of the subscription can hide resources, and this cannot be detected.

**The status flips between runs.** Terraform plans and Azure checks share one environment key. Use one key per source.
