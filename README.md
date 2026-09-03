# 🔐 Zitadel on AWS (Off-EC2)

Deploy [Zitadel](https://zitadel.com/) as a dev/demo identity provider on AWS
using ECS Fargate + RDS PostgreSQL behind an Application Load Balancer — no EC2
instances to manage. Terraform also provisions a project and an OIDC application
for federating with Amazon Cognito.

> **Dev/demo only.** Single Fargate task, single-AZ RDS, and friction-free
> teardown settings. Not production-hardened.

## 🧱 Layout

Two independent root modules, each with its own S3 state — because the Zitadel
API provider can only be configured once the service is actually running:

| Module | What it manages | When to apply |
|--------|-----------------|---------------|
| `./` (root) | AWS infra: ALB, Fargate, RDS, ACM cert, DNS, secrets | First |
| `./sso/` | Zitadel project + Cognito OIDC application (via the `zitadel` provider) | After the service is healthy |

Each module has an `envs/sample/` you copy to your own environment name.

## 📋 Prerequisites

- Terraform `~> 1.15` and AWS credentials with permissions for ECS, RDS, ELBv2,
  ACM, Route53, IAM, Secrets Manager, and CloudWatch Logs.
- An **existing VPC** with:
  - At least 2 **public** subnets (internet-facing) for the ALB.
  - At least 2 **private** subnets with **outbound internet** (NAT gateway or VPC
    endpoints) for Fargate (image pull + Secrets Manager) and RDS.
- A **Route53 hosted zone** for the domain you'll use (e.g. `example.com`), and a
  chosen FQDN (e.g. `id.example.com`).

This project does **not** create networking — you supply `vpc_id`,
`public_subnet_ids`, `private_subnet_ids`.

## 🚀 Quick start

Each module keeps per-environment config under `envs/<env>/` — a `backend.config`
(S3 remote state) and a `terraform.tfvars` you create from the example. A
`sample` environment is provided; copy it to your own name (e.g. `dev`, `prod`).
The examples below use `dev`.

### Stage 1 — AWS infrastructure (root module)

```bash
# 1. Create your environment from the sample
cp -r envs/sample envs/dev

# 2. Point the backend at your own S3 bucket, then fill in your values
$EDITOR envs/dev/backend.config                          # bucket/key/region
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars
$EDITOR envs/dev/terraform.tfvars

# 3. Init + apply
terraform init -backend-config=envs/dev/backend.config
terraform apply -var-file=envs/dev/terraform.tfvars
```

State is stored in S3 with native locking (`use_lockfile = true`, no DynamoDB
table needed). The bucket referenced in `backend.config` must already exist.

Retrieve the admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw admin_credentials_secret_arn)" \
  --query SecretString --output text | jq .
```

Open the console at the `console_url` output and log in as `zitadel-admin`.

### Between stages — create a service user

The `sso/` module talks to Zitadel over its API, so it can only run **after**
the Fargate service is up and reachable at `https://<domain_name>`.

1. **Wait** for the ECS service to reach a healthy target in the ALB target group
   (`aws elbv2 describe-target-health`). First boot also initializes the DB.
2. **Create a service user:** log into the console as `zitadel-admin`, create a
   Service User with Org Owner (or Instance) manager role, generate a **JSON
   key**, and save it as `zitadel-admin-sa.json` inside the `sso/` directory
   (the default `jwt_profile_file` path). This file is gitignored.

### Stage 2 — Zitadel project + Cognito app (`sso/` module)

```bash
cd sso
cp -r envs/sample envs/dev
$EDITOR envs/dev/backend.config                          # bucket/key/region
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars
$EDITOR envs/dev/terraform.tfvars                        # set domain_name

terraform init -backend-config=envs/dev/backend.config
terraform apply -var-file=envs/dev/terraform.tfvars
```

## 🔗 Configure Amazon Cognito (OIDC federation)

Zitadel is the OIDC **provider**; Cognito is the **relying party**. After stage 2:

1. Collect the values Cognito needs:
   - Issuer (root module): `terraform output -raw issuer_url`
   - Client ID (`sso/`): `terraform -chdir=sso output -raw cognito_oidc_client_id`
   - Client secret (`sso/`): `terraform -chdir=sso output -raw cognito_oidc_client_secret`
2. In the Cognito User Pool → **Sign-in experience → Federated identity provider
   sign-in → Add identity provider → OpenID Connect (OIDC)**.
3. Enter the issuer URL, client ID, and client secret from step 1. Cognito reads
   the discovery document at `<issuer>/.well-known/openid-configuration`.
4. Set authorized scopes to `openid profile email`.
5. Note Cognito's callback URL
   (`https://<domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse`), set
   `cognito_callback_url` in `sso/envs/dev/terraform.tfvars` to it, and
   re-apply the `sso/` module so the app's redirect URI matches.
6. Map OIDC claims (email, name) to Cognito user-pool attributes.
7. Create test users in the Zitadel console and log in through the Cognito hosted
   UI to verify.

## 🗂️ Optional: AD/LDAP identity provider

Not managed by Terraform. Zitadel can authenticate users against an existing
Active Directory / LDAP directory (inbound federation):

1. Console → your org → **Identity Providers → LDAP**.
2. Set the server URL (`ldaps://...`), bind DN + password, base DN, and the user
   filters / attribute mappings for your directory.
3. Configure creation/linking options, then save.
4. Users authenticate against LDAP; Zitadel brokers them to Cognito via the same
   OIDC app.

Note: Zitadel federates against LDAP inbound — it is not itself an LDAP server.

## 💲 Cost notes

Baseline runs even when idle: RDS `db.t4g.micro` (~$12–15/mo), one Fargate task
(0.25 vCPU/0.5 GB, ~$9/mo), and the ALB (~$16/mo + LCU). To tear down, destroy
the `sso/` module first, then the root (dev settings skip the final RDS
snapshot):

```bash
terraform -chdir=sso destroy -var-file=envs/dev/terraform.tfvars
terraform destroy -var-file=envs/dev/terraform.tfvars
```

## 🧪 Testing

```bash
terraform fmt -check -recursive
terraform validate            # run in each module (./ and ./zitadel)
terraform test                # root: variable validation (mock providers, offline)
```

## 📄 License

See `LICENSE`.
