# 🔐 Zitadel on AWS (Off-EC2)

Deploy [Zitadel](https://zitadel.com/) as a dev/demo identity provider on AWS
using ECS Fargate + RDS PostgreSQL behind an Application Load Balancer — no EC2
instances to manage. Terraform also provisions a project and an OIDC application
for federating with Amazon Cognito.

> **Dev/demo only.** Single Fargate task, single-AZ RDS, and friction-free
> teardown settings. Not production-hardened.

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

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit values
terraform init

# Stage 1 — infrastructure (ALB, Fargate, RDS, cert, DNS)
terraform apply

# Wait until the service is healthy (see "Two-stage apply"), then stage 2 below.
```

Retrieve the admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw admin_credentials_secret_arn)" \
  --query SecretString --output text | jq .
```

Open the console at the `console_url` output and log in as `zitadel-admin`.

## 🔁 Two-stage apply (why)

The Zitadel Terraform provider configures Zitadel over its API, so it can only
run **after** the Fargate service is up and reachable at `https://<domain_name>`.
Terraform cannot natively wait for ALB health, so:

1. **Stage 1:** `terraform apply` creates all infrastructure. The
   `zitadel_project`/`zitadel_application_oidc` resources will error if applied
   now — exclude them with `-target` on the ALB/ECS resources, or apply and let
   only those two fail, then continue.
2. **Wait** for the ECS service to reach a healthy target in the ALB target group
   (`aws elbv2 describe-target-health`). First boot also initializes the DB.
3. **Create a service user for the provider:** log into the console as
   `zitadel-admin`, create a Service User with Org Owner (or Instance) manager
   role, generate a **JSON key**, and save it as `zitadel-admin-sa.json` in the
   project directory (the path referenced by the `zitadel` provider block). This
   file is gitignored.
4. **Stage 2:** `terraform apply -target=zitadel_project.this -target=zitadel_application_oidc.cognito`.
   Subsequent `terraform apply` (no `-target`) will then work cleanly.

## 🔗 Configure Amazon Cognito (OIDC federation)

Zitadel is the OIDC **provider**; Cognito is the **relying party**. After stage 2:

1. Collect the values Cognito needs:
   - Issuer: `terraform output -raw issuer_url`
   - Client ID: `terraform output -raw cognito_oidc_client_id`
   - Client secret: `terraform output -raw cognito_oidc_client_secret`
2. In the Cognito User Pool → **Sign-in experience → Federated identity provider
   sign-in → Add identity provider → OpenID Connect (OIDC)**.
3. Enter the issuer URL, client ID, and client secret from step 1. Cognito reads
   the discovery document at `<issuer>/.well-known/openid-configuration`.
4. Set authorized scopes to `openid profile email`.
5. Note Cognito's callback URL
   (`https://<domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse`), set
   `cognito_callback_url` in `terraform.tfvars` to it, and re-run stage 2 so the
   Zitadel app's redirect URI matches.
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
(0.25 vCPU/0.5 GB, ~$9/mo), and the ALB (~$16/mo + LCU). `terraform destroy`
removes everything (dev settings skip the final RDS snapshot).

## 🧪 Testing

```bash
terraform fmt -check
terraform validate
terraform test        # variable validation (mock providers, offline)
```

## 📄 License

See `LICENSE`.
