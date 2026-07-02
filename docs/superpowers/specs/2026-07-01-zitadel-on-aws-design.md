# Zitadel on AWS (Off-EC2) — Design

**Date:** 2026-07-01
**Status:** Approved design, pending implementation plan

## Purpose

Deploy [Zitadel](https://zitadel.com/) on AWS as a cheap dev/demo identity
provider, off EC2 and off instance management. Inspired by the RES demo
CloudFormation template (`aws-hpc-recipes/.../keycloak.yaml`), which ran
Keycloak's dev server with an embedded H2 database on a single EC2 instance.
This project replaces that with a managed, container-based deployment while
keeping state persistent across restarts.

Zitadel was chosen over Keycloak (the original candidate) and Authentik: it is a
lightweight Go binary (single container, fast cold start, cheapest Fargate
footprint), it is OIDC-native, and it ships an official Terraform provider.
Because Cognito supports OIDC identity providers, the federation is done over
**OIDC** rather than SAML — which removes Zitadel's only relative weakness
(its SAML IdP support is newer/less proven than Keycloak's).

**Scope:** dev/demo only. Not production-hardened (single task, single-AZ DB,
dev-friendly teardown settings).

## Why not truly "serverless"

Zitadel is a stateful, long-running application — there is no Lambda-style
version. The practical "off-EC2" answer is **ECS Fargate** running the official
Zitadel container. This removes all instance management (no patching, no SSH, no
self-healing scripts) while remaining a supported way to run Zitadel.

## Scope Decisions

- **RES-specific machinery dropped:** no user-sync or password-rotation cron
  jobs. Users are created directly in Zitadel (or via optional LDAP federation).
- **Cognito OIDC federation:** Zitadel acts as an OIDC provider for an *external*
  Cognito User Pool. This project manages the Zitadel side (project + OIDC
  application) only; the Cognito side is configured manually (documented in the
  README).
- **AD/LDAP:** not managed by Terraform. Zitadel supports an LDAP identity
  provider (inbound federation against AD/LDAP). README documents how to add it
  manually in the console as an optional follow-on.
- **Networking is provided, not created:** the project consumes an existing VPC
  and subnets via variables. It does not create a VPC, subnets, NAT, or IGW.

## Architecture

```
Internet
   │
   ▼
Route53 A (alias) → [Application Load Balancer]  (public subnets)
                        │  HTTPS:443 (ACM cert, DNS-validated)
                        │  HTTP:80 → redirect to 443
                        ▼
                    [ECS Fargate service]  (private subnets, no public IP)
                        │  official ghcr.io/zitadel/zitadel container, port 8080
                        ▼
                    [RDS PostgreSQL db.t4g.micro]  (private subnets, persistent)

Secrets Manager: Zitadel masterkey + first-instance admin creds + DB password
Terraform Zitadel provider → project + OIDC application (stage-2 apply)
```

### Networking (consumed, not created)

Inputs: `vpc_id`, `public_subnet_ids` (ALB), `private_subnet_ids` (Fargate + RDS).

Prerequisites (documented, not validated):
- Private subnets must have outbound internet access (NAT gateway or VPC
  endpoints) so Fargate can pull the container image and reach Secrets Manager.
- Public subnets must be internet-facing for the ALB.

### Security Groups

- **ALB SG:** ingress 443 from `allowed_cidrs`; ingress 80 (redirect only). Egress
  to Fargate SG.
- **Fargate SG:** ingress on container port 8080 from ALB SG only. Egress all
  (image pull, Secrets Manager, DB).
- **RDS SG:** ingress 5432 from Fargate SG only. No public access.

### Load Balancer & TLS

- Internet-facing ALB in `public_subnet_ids`.
- HTTPS listener (443) using the ACM cert → Zitadel target group.
- HTTP listener (80) → redirect to 443.
- Target group health check against Zitadel's health endpoint (`/debug/healthz`)
  on the single container port 8080.
- **ACM certificate:** `aws_acm_certificate` for `domain_name`, **DNS-validated**
  via `aws_route53_record` + `aws_acm_certificate_validation` in
  `route53_zone_id`. Publicly trusted, auto-renewing.
- **Route53:** alias A record for `domain_name` → ALB.
- **gRPC note:** Zitadel serves HTTP and gRPC on the same port 8080. The ALB uses
  a standard HTTP target group; Zitadel's clients use gRPC-web/connect over HTTP,
  which works through an HTTP ALB. No special gRPC target-group protocol is
  required for the console and OIDC endpoints used here.

### Compute (ECS Fargate)

- One Fargate cluster (no EC2 capacity providers).
- Task definition: `ghcr.io/zitadel/zitadel:<pinned-tag>`, 0.25 vCPU / 0.5 GB
  (lighter than Keycloak). Container port 8080. Command:
  `start-from-init --masterkey <from-secret> --tlsMode external`.
  (`start-from-init` initializes the DB + first instance on first run and starts
  normally on subsequent runs.)
- Key config (env vars):
  - `ZITADEL_DATABASE_POSTGRES_HOST`, `_PORT`, `_DATABASE`, `_USER_USERNAME`,
    `_USER_PASSWORD` (password from Secrets Manager), `_USER_SSL_MODE=require`,
    and matching admin user for init — or a single
    `ZITADEL_DATABASE_POSTGRES_DSN`. Exact env-var names confirmed against the
    pinned image during implementation.
  - `ZITADEL_EXTERNALDOMAIN=<domain_name>`, `ZITADEL_EXTERNALPORT=443`,
    `ZITADEL_EXTERNALSECURE=true` (TLS terminates at the ALB; `--tlsMode external`).
  - First-instance admin (`ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME` /
    `_PASSWORD` / `_EMAIL_ADDRESS`) from Secrets Manager, so the initial admin is
    known and reproducible.
- Service: desired count = 1 (dev/demo, no autoscaling). Runs in private subnets,
  registered to the ALB target group. Brief downtime on deploys is acceptable.
- Logging: CloudWatch Logs group, `awslogs` driver, ~7-day retention.
- IAM: execution role (pull image, read the three secrets, write logs); task role
  minimal/empty (Zitadel needs no AWS API access).
- Zitadel creates its schema in the RDS database on first init.

### Database (RDS PostgreSQL)

- `db.t4g.micro`, single-AZ, PostgreSQL (recent major version, pinned), ~20 GB
  gp3, `storage_encrypted = true`, not publicly accessible.
- DB subnet group across `private_subnet_ids`; RDS SG (5432 from Fargate only).
- Dev-only settings (flagged in README/comments): `skip_final_snapshot = true`,
  `deletion_protection = false`, backup retention ~1 day — so `terraform destroy`
  is clean.
- Purpose: persists Zitadel instances, orgs, projects, the Cognito OIDC app,
  users, and sessions across container restarts.

### Secrets Manager (three secrets)

- **DB master password.**
- **Zitadel masterkey** — exactly 32 characters, used by Zitadel to encrypt
  secrets at rest in the DB. Generated via `random_password` (length 32).
- **First-instance admin credentials** (username + password).
- Passwords generated via `random_password`, stored in the secrets, injected into
  the container as secret references. Nothing sensitive in plaintext Terraform.

### Zitadel project + Cognito OIDC application (Zitadel Terraform provider)

- Provider (`zitadel/zitadel`) authenticates to `https://<domain_name>` using a
  service-account key or PAT (auth method confirmed against the provider docs
  during implementation).
- Creates: one **project**, and one **OIDC application** representing Cognito,
  configured with Cognito's callback (redirect) URI (`cognito_callback_url`,
  placeholder allowed until Cognito exists).
- Outputs the app's **client ID** and **client secret**, plus Zitadel's **issuer
  URL** (`https://<domain_name>`) — these three values are what you enter into
  Cognito to define the OIDC identity provider.
- **Two-stage apply** (the one rough edge): the Zitadel provider can only run
  after the Fargate service is healthy, and Terraform cannot natively wait for
  ALB health. Zitadel-provider resources live in their own file (`zitadel.tf`) so
  stage 1 (infra) and stage 2 (Zitadel config) are cleanly separable via
  `-target` or a documented two-step. Documented in README.

## Variables (inputs)

- `vpc_id`, `public_subnet_ids`, `private_subnet_ids`
- `domain_name` (FQDN for Zitadel, e.g. `id.example.com`)
- `route53_zone_id` (hosted zone for cert validation + alias record)
- `allowed_cidrs` (who can reach the ALB)
- `zitadel_image_tag`, `db_instance_class` (default `db.t4g.micro`),
  `db_allocated_storage`, `db_engine_version`
- `project_name` (default `demo`), `cognito_callback_url` (placeholder allowed)
- `log_retention_days`, `aws_region`, `name_prefix`, `tags`

## Outputs

- Zitadel URL / issuer URL (`https://<domain_name>`)
- Console URL (`https://<domain_name>/ui/console`)
- First-instance admin credentials secret ARN
- Cognito OIDC application client ID (and a reference to the client-secret secret)
- ALB DNS name
- RDS endpoint

## File Layout (flat root configuration)

Single root Terraform configuration (no module wrapper — YAGNI for a single
domain-bound demo):

- `providers.tf` — AWS + Zitadel + random providers
- `variables.tf`
- `locals.tf`
- `secrets.tf` — masterkey, admin creds, DB password (+ random passwords)
- `network.tf` — security groups only (VPC/subnets are inputs)
- `rds.tf` — RDS instance + subnet group
- `alb.tf` — ALB, listeners, target group, ACM cert + validation, Route53 records
- `iam.tf` — task execution / task roles
- `ecs.tf` — cluster, task definition, service, CloudWatch log group
- `zitadel.tf` — provider-managed project + OIDC application (isolated for stage-2)
- `outputs.tf`
- `README.md`

## README Contents

- Prerequisites (VPC/subnet egress requirements, existing hosted zone/domain).
- Two-stage apply instructions.
- Cognito OIDC setup: create User Pool OIDC IdP from the issuer URL + client
  ID/secret, attribute mapping, callback URL.
- Optional AD/LDAP federation: how to add an LDAP identity provider in the Zitadel
  console (not Terraform-managed).
- Cost note and dev-only caveats.

## Verification

- `terraform validate` + `terraform plan` clean.
- Stage 1 apply → ALB healthy, console loads over HTTPS at `domain_name`, login
  with generated first-instance admin creds.
- Stage 2 apply → project + OIDC application exist; discovery endpoint
  (`https://<domain_name>/.well-known/openid-configuration`) resolves.
- `terraform destroy` cleanly tears everything down.

## Non-Goals

- Production hardening (HA/multi-AZ, autoscaling, WAF, session replication).
- Creating networking (VPC/subnets/NAT).
- Managing the Cognito User Pool or AD/LDAP directory.
- Zitadel acting as an LDAP *server* (it federates against LDAP inbound only).
- A reusable Terraform module.
