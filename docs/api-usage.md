# API Usage

DriftHound provides a RESTful API for submitting drift check results. A check is either a Terraform-style plan result (`source: terraform`, the default) or an inventory of unmanaged resources from another source such as Azure.

## Authentication

All API requests require authentication using a Bearer token in the `Authorization` header:

```bash
Authorization: Bearer YOUR_API_TOKEN
```

See [API Token Management](#api-token-management) for details on generating tokens.

## Endpoints

### Submit a Drift Check

Submit the results of a Terraform drift check for a specific project and environment.

**Endpoint:** `POST /api/v1/projects/:project_key/environments/:environment_key/checks`

**Example Request:**

```bash
curl -X POST \
  http://localhost:3000/api/v1/projects/my-project/environments/my-env/checks \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "drift",
    "add_count": 2,
    "change_count": 1,
    "destroy_count": 0,
    "duration": 8.2,
    "raw_output": "Plan: 2 to add, 1 to change, 0 to destroy.",
    "directory": "infra/terraform/production",
    "repository": "https://github.com/myorg/infrastructure",
    "branch": "master"
  }'
```

### Request Parameters

#### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `project_key` | string | Yes | Unique identifier for the project (alphanumeric, dashes, underscores) |
| `environment_key` | string | Yes | Unique identifier for the environment (alphanumeric, dashes, underscores) |

#### Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `status` | string | Yes for `terraform` | One of: `ok`, `drift`, `error`, `unknown`. Required when `source` is `terraform`; defaults to `ok` for other sources. A value that is not one of these is rejected with `422` before anything is created. See [Status rules](#status-rules). |
| `source` | string | No | Where the check came from: `terraform` (default), `azure` or `argocd`. Any other value is rejected with `422` and nothing is created. |
| `unmanaged_resources` | array | No | Resources that exist but are not managed. JSON body only; see [Unmanaged Resources](#unmanaged-resources). |
| `add_count` | integer | No | Number of resources to add |
| `change_count` | integer | No | Number of resources to change |
| `destroy_count` | integer | No | Number of resources to destroy |
| `duration` | float | No | Execution duration in seconds |
| `raw_output` | text | No | Full Terraform plan output |
| `environment_name` | string | No | Display name for the environment. Defaults to the titleized `environment_key` when the environment is created. When provided, it is applied on every call, so it also renames an existing environment. When omitted, the current name is kept. Must be a string; surrounding whitespace is removed. At most 255 characters; a longer or non-string value is rejected with `422 Unprocessable Entity` and nothing is created or renamed. The last name sent wins, so if several pipelines report the same environment, send the same name from all of them. |
| `directory` | string | No | Directory where Terraform is executed. Only set on first call; subsequent calls won't overwrite. Update via GUI. |
| `repository` | string | No | Repository URL (e.g., `https://github.com/org/repo`). Only set on first call; subsequent calls won't overwrite. Update via GUI. |
| `branch` | string | No | Branch the check ran against. Stored on each check and shown in the environment's check history; the environment page links the repository at the latest check's branch. The first value that differs from `main` also becomes the project branch, which is used when a check has no branch. Must be a string of at most 255 characters. Names git rejects (for example ones containing `..`, spaces, `~`, `^`, `:`, `?`, `*`, `[`, `\` or `@{`, starting with `-`, `/` or `.`, or ending with `/`, `.` or `.lock`) are rejected with `422 Unprocessable Entity` and nothing is created. |
| `notification_channel` | object | No | Optional notification channel configuration (see [Advanced Features](#advanced-features)) |

### Response

**Success Response (201 Created):**

```json
{
  "id": 123,
  "project_key": "my-project",
  "environment_key": "my-env",
  "status": "drift",
  "source": "terraform",
  "unmanaged_count": null,
  "unmanaged_ignored_count": null,
  "branch": "master",
  "created_at": "2025-11-27T10:30:00Z"
}
```

`unmanaged_count` and `unmanaged_ignored_count` are `null` when the check sent no `unmanaged_resources`.

**Error Responses:**

- `401 Unauthorized` - Missing or invalid API token
- `422 Unprocessable Entity` - Invalid status value or validation error

### Status Values

| Status | Description |
|--------|-------------|
| `ok` | No drift detected - infrastructure matches state |
| `drift` | Drift detected - changes pending |
| `error` | Error running drift check |
| `unknown` | Initial state or unable to determine |

### Unmanaged Resources

A check can carry the list of resources that exist in a platform but are not managed by your infrastructure code. The `azure` source uses this to report Azure resources that are missing from Terraform state (see [Azure Unmanaged Resources](azure-unmanaged-resources.md)). Send it as a JSON array under `unmanaged_resources`:

```json
{
  "source": "azure",
  "status": "ok",
  "unmanaged_resources": [
    {
      "identifier": "/subscriptions/0000/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1",
      "resource_type": "microsoft.storage/storageaccounts",
      "name": "sa1",
      "scope": "rg1",
      "location": "westeurope",
      "metadata": { "subscription_id": "0000", "managed_by": null, "tags": { "owner": "x" } }
    }
  ]
}
```

| Field | Required | Limit |
|-------|----------|-------|
| `identifier` | Yes | Non-blank string, at most 1024 characters |
| `resource_type` | No | At most 255 characters |
| `name` | No | At most 255 characters |
| `scope` | No | At most 255 characters (resource group or namespace) |
| `location` | No | At most 128 characters |
| `metadata` | No | Object, at most 2048 bytes as JSON |

- At most **5000** items per check. More is rejected with `422`.
- Strings and metadata must not contain NUL (`\u0000`) characters.
- Duplicate identifiers (compared without case) are stored once; the first one wins.
- Sending the key, even as `[]`, marks the check as one that reported an inventory: `unmanaged_count` and `unmanaged_ignored_count` are set (0 or more). Leaving the key out leaves both `null`.
- Every valid row is stored. Rows that match an [ignore rule](#ignore-rules) are stored with `ignored: true` and an `ignore_reason`, and are not counted in `unmanaged_count`.
- Any validation failure returns `422` with `{"error": "..."}` and nothing is created, not even the project or environment.
- The parameter is left out of server logs.

#### Status rules

The server decides the final status before the check is stored, so the environment status and any notification follow it:

1. `error` from the client always stays `error`.
2. Otherwise the check is `drift` when the client reported `drift` or `unmanaged_count` is above 0.
3. In all other cases the status you sent is kept.

Ignore rules apply only to checks received after the rule was added. Stored checks are never re-evaluated.

Use **one environment key per source** (for example `prod` for Terraform and `prod-azure` for Azure). An environment takes its status from its newest check, so mixing sources under one key would make the status flip on every run and notify each time. Ignore rules are per environment, which fits this model.

### Ignore Rules

Ignore rules hide known, harmless unmanaged resources. A rule belongs to one environment. Matching is `exact` (case-insensitive equality) or `glob` (case-insensitive; `*` also matches `/`, `?` and `[...]` work, braces are literal). There is no regex support.

| Endpoint | Token | Description |
|----------|-------|-------------|
| `GET /api/v1/projects/:project_key/environments/:environment_key/ignore_rules` | any | The environment's rules and the built-in rules |
| `POST /api/v1/projects/:project_key/environments/:environment_key/ignore_rules` | `write` | Create a rule |
| `DELETE /api/v1/projects/:project_key/environments/:environment_key/ignore_rules/:id` | `write` | Delete a rule (`204`) |

`POST` body: `pattern` (required, at most 512 printable characters), `field` (`identifier` by default, or `resource_type`, `name`, `scope`, `location`), `match_type` (`glob` by default, or `exact`), `source` (omit for all sources) and `note` (at most 255 characters). Every value must be a string. An environment can have at most 200 rules, and the same rule cannot be added twice. An invalid rule returns `422`; an unknown project, environment or rule returns `404` (nothing is auto-created).

```json
{
  "ignore_rules": [
    { "id": 1, "field": "identifier", "match_type": "glob", "pattern": "*/resourceGroups/tmp-*", "source": null, "note": "scratch groups", "created_at": "2026-11-27T10:30:00Z" }
  ],
  "builtin_rules": {
    "azure": [
      { "key": "aks-node-rg", "field": "identifier", "match_type": "glob", "pattern": "/subscriptions/*/resourceGroups/MC_*", "note": "AKS node resource group" }
    ]
  }
}
```

### List Drift Check History

Read past drift checks, for example to chart drift trends in an external dashboard. Results are ordered newest first.

**Endpoints:**

- `GET /api/v1/projects/:project_key/environments/:environment_key/checks` - checks for one environment
- `GET /api/v1/checks` - checks across all projects

**Query Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `since` | ISO 8601 date or timestamp | No | Only checks created at or after this time (a date or a timestamp without an offset is read as UTC) |
| `until` | ISO 8601 date or timestamp | No | Only checks created before this time (a date or a timestamp without an offset is read as UTC) |
| `limit` | integer | No | Page size, 1 to 500 (default: 50) |
| `cursor` | string | No | The `next_cursor` value from the previous page |
| `project` | string | No | `GET /api/v1/checks` only: filter by project key |
| `environment` | string | No | `GET /api/v1/checks` only: filter by environment key |
| `source` | string | No | Only checks from one source: `terraform`, `azure` or `argocd` |

**Example Request:**

```bash
curl -H "Authorization: Bearer YOUR_API_TOKEN" \
  "http://localhost:3000/api/v1/projects/my-project/environments/my-env/checks?since=2025-11-01&limit=100"
```

**Response (200 OK):**

```json
{
  "checks": [
    {
      "id": 123,
      "project_key": "my-project",
      "environment_key": "my-env",
      "status": "drift",
      "add_count": 2,
      "change_count": 1,
      "destroy_count": 0,
      "duration": 8,
      "execution_number": 42,
      "branch": "main",
      "source": "terraform",
      "unmanaged_count": null,
      "unmanaged_ignored_count": null,
      "created_at": "2025-11-27T10:30:00Z",
      "change_summary": "2 to add, 1 to change"
    }
  ],
  "pagination": {
    "limit": 100,
    "has_more": true,
    "next_cursor": "MjAyNS0xMS0yN1QxMDozMDowMC4wMDAwMDBaLDEyMw"
  }
}
```

To fetch the next page, repeat the request with the same filters and `cursor` set to `next_cursor`. When `has_more` is `false`, `next_cursor` is `null`. The cursor points at a position in the list, so checks submitted while you page through do not cause duplicates or gaps.

History responses do not include `raw_output` or the unmanaged resource list. Use `GET /api/v1/projects/:project_key/environments/:key/drift` to read the full plan output and the unmanaged resources of the latest check.

For a check that reported an inventory, `GET .../environments/:key/drift` also returns `"unmanaged_resources"`: the rows described under [Unmanaged Resources](#unmanaged-resources), ignored rows included (`ignored`, `ignore_reason`), ordered by id. The list can reveal subscription IDs, resource names and tags, so it follows the plan output rule below: a `read` token gets `"unmanaged_resources_restricted": true` instead. The summary fields `source`, `unmanaged_count` and `unmanaged_ignored_count` are returned to every token, in the history and in the environment responses.

**Error Responses:**

- `400 Bad Request` - Invalid `since`, `until`, `limit` or `cursor`, a `project` or `environment` that is not a single key, or a `source` that is not one valid value
- `401 Unauthorized` - Missing or invalid API token
- `404 Not Found` - Unknown project or environment

### Update an Environment

Exclude an environment from the dashboard charts and stability score, or include it again. Needs a `write` token.

**Note:** any `write` token can set this flag through the API. The web UI only lets admins change it, so it is not admin-only over the API. Write tokens can already change the charts by submitting checks.

**Endpoint:** `PATCH /api/v1/projects/:project_key/environments/:key`

```bash
curl -X PATCH \
  http://localhost:3000/api/v1/projects/my-project/environments/staging \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"exclude_from_metrics": true}'
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `exclude_from_metrics` | boolean | Yes | `true` leaves the environment out of the dashboard charts and stability score; `false` includes it again. It stays in every list either way. |

The response is the environment, as returned by `GET /api/v1/projects/:project_key/environments/:key`. Environment objects in the read API include `exclude_from_metrics`.

**Error Responses:**

- `401 Unauthorized` - Missing or invalid API token
- `403 Forbidden` - The token is read-only
- `404 Not Found` - Unknown project or environment
- `422 Unprocessable Entity` - `exclude_from_metrics` is missing or not a boolean

## Advanced Features

### Notification Channel Configuration

You can optionally configure Slack notification channels per environment via the API:

```bash
curl -X POST \
  http://localhost:3000/api/v1/projects/my-project/environments/production/checks \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "drift",
    "add_count": 2,
    "change_count": 1,
    "destroy_count": 0,
    "notification_channel": {
      "channel_type": "slack",
      "enabled": true,
      "config": {
        "channel": "#custom-alerts"
      }
    }
  }'
```

**Notification Channel Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `channel_type` | string | Yes | Currently only `"slack"` is supported |
| `enabled` | boolean | No | Enable or disable notifications for this environment |
| `config.channel` | string | No | Slack channel name (e.g., `"#alerts"`). Falls back to global default if not provided |

**Notes:**
- The Slack token is always taken from the global configuration (`SLACK_BOT_TOKEN` or `config/notifications.yml`)
- This allows you to override the notification channel per environment without exposing tokens in API requests
- See [Slack Notifications documentation](slack-notifications.md) for more details on notification setup

## API Token Management

DriftHound provides a web-based interface for managing API tokens. Only admin users can create and manage tokens.

### Using the Web UI (Recommended)

1. Log in as an admin user
2. Click **API Tokens** in the navigation bar
3. Enter a name for your token (e.g., "CI/CD Pipeline"), choose its access level, and click **Create Token**
4. **Important:** Copy the token immediately - it will only be shown once!

The API Tokens page also displays:
- A list of all existing tokens with partial token previews
- The access level of each token
- Creation dates for each token
- Delete buttons to revoke tokens
- Usage examples showing how to authenticate API requests

### Token Access Levels

Each token has an access level:

| Access | Allowed requests | Use for |
|--------|------------------|---------|
| `write` (default) | All API endpoints, including submitting drift checks | CI/CD pipelines and the CLI |
| `read_plans` | `GET` and `HEAD` requests only, including plan output | Tools that need to show or analyse plans |
| `read` | `GET` and `HEAD` requests only, without plan output | Dashboards and reporting tools that only read drift status |

A `read` or `read_plans` token that sends any other request (for example `POST .../checks`) receives `403 Forbidden`:

```json
{ "error": "Forbidden: this API token is read-only" }
```

Plan output and unmanaged resource lists can contain sensitive values, so only `read_plans` and `write` tokens receive them. For a `read` token, `GET .../environments/:key/drift` still returns the check summary, without `raw_output` and with `"raw_output_restricted": true`.

Tokens created before access levels were introduced keep `write` access.

### Using the Rake Tasks

```bash
bin/rails "api_tokens:generate[CI Pipeline]"
bin/rails "api_tokens:generate[Reporting Dashboard,read]"
bin/rails "api_tokens:generate[Plan Viewer,read_plans]"
bin/rails api_tokens:list
bin/rails "api_tokens:revoke[42]"
```

### Token Security

- Tokens are only displayed once at creation time
- Store tokens securely (e.g., in CI/CD secrets, environment variables)
- Use descriptive names to identify token purposes
- Give tools that only read data a `read` token
- Revoke tokens that are no longer needed

## Health Check Endpoint

DriftHound provides a health check endpoint for load balancers and monitoring systems:

**Endpoint:** `GET /up`

**Response:**
- `200 OK` - Application is healthy
- `500 Internal Server Error` - Application failed to boot

**Note:** Health check requests are not logged in production to prevent log clutter.

## Best Practices

1. **Use descriptive project and environment keys** - Use kebab-case names like `infrastructure-prod` rather than cryptic codes
2. **Always include raw_output** - Helps with debugging and provides detailed context in the dashboard
3. **Set appropriate durations** - Helps track performance over time
4. **Use environment variables for tokens** - Never hardcode tokens in scripts
5. **Configure notifications per environment** - Use different Slack channels for production vs. staging alerts

## Example Integration

### GitHub Actions

```yaml
- name: Check Terraform Drift
  run: |
    drifthound --tool=terraform \
      --project=my-infrastructure \
      --environment=production \
      --token=${{ secrets.DRIFTHOUND_TOKEN }} \
      --api-url=${{ secrets.DRIFTHOUND_URL }} \
      --dir=./terraform
```

### GitLab CI

```yaml
drift_check:
  script:
    - drifthound --tool=terraform
        --project=my-infrastructure
        --environment=production
        --token=$DRIFTHOUND_TOKEN
        --api-url=$DRIFTHOUND_URL
        --dir=./terraform
```

## See Also

- [CLI Usage Guide](cli-usage.md) - For automated drift checking in CI/CD
- [Slack Notifications](slack-notifications.md) - Configure Slack alerts
