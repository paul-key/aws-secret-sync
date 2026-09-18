# Cross-account Secrets Manager sync

One-way copy of AWS Secrets Manager **values** from a source account to a destination account. Only names starting with a configurable prefix are considered.

A source-account Lambda is invoked by EventBridge on CloudTrail Secrets Manager API calls (`CreateSecret`, `PutSecretValue`, `UpdateSecret`, `RestoreSecret`, `DeleteSecret`). It reads `AWSCURRENT` locally and writes the **same name** in the destination:

- **Missing dest secret** → `CreateSecret` (default dest KMS key `aws/secretsmanager`, copies description when present).
- **Existing dest secret** → `PutSecretValue` only when the value differs (no extra versions). Dest KMS, tags, and resource policies stay as they are.
- **Source `DeleteSecret`** → dest `DeleteSecret` with the same recovery window or force-delete flag. Missing dest is a no-op.
- **Source `RestoreSecret`** → dest `RestoreSecret` if the dest secret is scheduled for deletion, then the value is synced.

## Architecture

```
Source Secrets Manager
        |
        v
CloudTrail (management events)
        |
        v
EventBridge rule  -->  Lambda (source)
                           |
                           |  sts:AssumeRole + ExternalId
                           v
                     Dest IAM role
                           |
                           v
              Dest Secrets Manager (CreateSecret / PutSecretValue / DeleteSecret / RestoreSecret)
```

## Prerequisites

- Docker **or** Terraform >= 1.5 on the host.
- AWS credentials for **each** account (named profiles under `~/.aws`, or access keys in the environment).
- Same region in both accounts unless you set `dest_region` on the source stack.
- A CloudTrail trail that records **management events** in the source account/region. EventBridge `AWS API Call via CloudTrail` does not fire without it. Set `create_cloudtrail = true` on the source stack if you do not already have a trail.

## Apply order

1. Choose a long random `external_id` and use the **same value** in both stacks.
2. Copy tfvars (on the host, either way you run Terraform):

```bash
cp terraform/dest/terraform.tfvars.example terraform/dest/terraform.tfvars
cp terraform/source/terraform.tfvars.example terraform/source/terraform.tfvars
# dest: source_account_id, external_id, region, secret_prefix
# source: dest_role_arn (after dest apply), external_id, region, secret_prefix
# source: create_cloudtrail = true only if you need a new trail
```

3. Apply **destination** first (trust uses the predicted source Lambda role ARN `arn:aws:iam::<source_account_id>:role/secret-sync-lambda` by default).
4. Copy `writer_role_arn` from dest outputs into `terraform/source/terraform.tfvars`, then apply **source**.

If dest was applied with a custom `source_lambda_role_name` / `source_lambda_role_arn`, the source `lambda_role_name` must match that principal.

### Local Terraform / OpenTofu

If `registry.terraform.io` is reachable:

```bash
cd terraform/dest
terraform init
AWS_PROFILE=dest terraform apply

cd ../source
terraform init
AWS_PROFILE=source terraform apply
```

If that registry is blocked in your country, use [OpenTofu](https://opentofu.org/) the same way (`tofu init` / `tofu apply`). [`scripts/tf.sh`](scripts/tf.sh) does this in Docker by default.

### Docker

Use official images so you do not need Terraform or the AWS CLI installed locally.

**1. Authorise AWS** with [`scripts/aws.sh`](scripts/aws.sh) (writes SSO tokens or keys into `~/.aws`). Repeat for each account profile.

```bash
chmod +x scripts/aws.sh scripts/tf.sh   # once, if the bits are not already set

./scripts/aws.sh configure sso --use-device-code
```

**2. Apply** with [`scripts/tf.sh`](scripts/tf.sh). By default this runs **OpenTofu** (not HashiCorp Terraform) so providers come from `registry.opentofu.org`. It mounts `~/.aws` read-only and runs as your user so `.terraform/` is not owned by root. The source stack needs the full repo so it can zip `src/sync_secrets.py`. First `init` needs outbound HTTPS.

```bash
# Destination
./scripts/tf.sh dest YOUR_DEST_PROFILE init
./scripts/tf.sh dest YOUR_DEST_PROFILE apply
./scripts/tf.sh dest YOUR_DEST_PROFILE output writer_role_arn

# Source (put writer_role_arn into terraform/source/terraform.tfvars first)
./scripts/tf.sh source YOUR_SOURCE_PROFILE init
./scripts/tf.sh source YOUR_SOURCE_PROFILE apply
```

`AWS_PROFILE` can replace the profile argument:

```bash
AWS_PROFILE=dest ./scripts/tf.sh dest apply
```

Access keys in the environment are passed through (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`). Override images with `AWS_CLI_IMAGE` (default `amazon/aws-cli:latest`) and `TF_IMAGE`.

**Provider registry:** HashiCorp’s `registry.terraform.io` is blocked in some countries (that is the usual cause of `does not offer a Terraform provider registry`). [`scripts/tf.sh`](scripts/tf.sh) defaults to **OpenTofu** (`ghcr.io/opentofu/opentofu:1.9`), which installs providers from [registry.opentofu.org](https://registry.opentofu.org). HCL is the same as Terraform.

```bash
./scripts/tf.sh dest YOUR_DEST_PROFILE init
```

If you can reach HashiCorp’s registry:

```bash
TF_IMAGE=hashicorp/terraform:1.9 ./scripts/tf.sh dest YOUR_DEST_PROFILE init
```

## Variables

### Destination (`terraform/dest`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `region` | `us-east-1` | Dest IAM / secret ARN region |
| `secret_prefix` | `prefix/` | IAM resource prefix |
| `role_name` | `secret-sync-writer` | Dest role name |
| `source_account_id` | (required) | Source account |
| `source_lambda_role_name` | `secret-sync-lambda` | Trusted role name if ARN unset |
| `source_lambda_role_arn` | `""` | Explicit trusted principal |
| `external_id` | (required) | STS ExternalId |

Dest IAM allows `CreateSecret`, `DeleteSecret`, `RestoreSecret`, `DescribeSecret`, `GetSecretValue`, and `PutSecretValue` on `secret:<prefix>*`.

### Source (`terraform/source`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `region` | `us-east-1` | Lambda and EventBridge |
| `dest_region` | same as `region` | Dest Secrets Manager region |
| `secret_prefix` | `prefix/` | Lambda filter + IAM |
| `lambda_function_name` | `secret-sync` | Function name |
| `lambda_role_name` | `secret-sync-lambda` | Execution role name |
| `dest_role_arn` | (required) | Dest writer role |
| `external_id` | (required) | Must match dest |
| `create_cloudtrail` | `false` | Create a management-event trail + S3 bucket |
| `cloudtrail_name` | `secret-sync-trail` | Trail name if created |
| `cloudtrail_bucket_name` | generated | S3 bucket if trail is created |

## Lambda behavior

1. Ignore failed CloudTrail events and likely replica events.
2. Resolve `secretId` / `name` / ARN to a secret name. Skip if it does not start with `SECRET_PREFIX`.
3. `DescribeSecret` + `GetSecretValue` in source (`AWSCURRENT`), except for `DeleteSecret` (source value is not read).
4. Assume dest role with ExternalId.
5. `DeleteSecret`: dest `DeleteSecret` using `forceDeleteWithoutRecovery` or `recoveryWindowInDays` from the CloudTrail event (AWS 30-day default if neither is set). Missing dest or already-scheduled delete is logged and skipped.
6. `RestoreSecret` (and value sync when dest has `DeletedDate`): dest `RestoreSecret`, then continue.
7. Dest `DescribeSecret` / `GetSecretValue`:
   - `ResourceNotFoundException` → `CreateSecret` with the same name and value (and description if set). Concurrent create races fall back to `PutSecretValue`.
   - Same value → no-op (no extra version).
   - Different value → `PutSecretValue`.
8. Logs include secret **names** only, never values.

Failures show in `/aws/lambda/secret-sync`. There is no DLQ in this stack.

## Test plan

1. Create `prefix/test-sync` in **source only**. After CloudTrail + EventBridge (usually seconds to a couple of minutes), dest should have a new secret with the same name and value.
2. Update the source secret. Dest `AWSCURRENT` should match; dest should not be recreated.
3. Update a dest secret that already matches source; Lambda should no-op (no new version).
4. Create or update a secret **without** the prefix. Dest must not change; logs should show a prefix skip.
5. Confirm CloudWatch logs never print secret values.
6. Delete `prefix/test-sync` in source (scheduled or force). Dest should be deleted the same way. Restore in source; dest should be restored and the value should match.

## Optional follow-ups

- One-shot backfill for existing prefix secrets (this stack only reacts to later API calls).
- Destination customer-managed KMS on create (today new dest secrets use the account default key).
- Sync on tag changes.
- Multiple destination accounts.
