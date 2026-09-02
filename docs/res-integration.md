# 🔗 Integrating Zitadel with Research and Engineering Studio (RES)

How to use the [Zitadel](https://zitadel.com/) instance deployed by this repo as
the external identity provider (IdP) for [AWS Research and Engineering Studio
(RES)](https://docs.aws.amazon.com/res/latest/ug/overview.html).

RES authenticates portal logins through an **Amazon Cognito user pool that RES
creates and manages itself** (`res-<env>-user-pool`). To use Zitadel, you
register it as a **federated identity provider inside that RES-managed Cognito
pool** — you do *not* point RES at your own Cognito pool, and you do not reuse
the OIDC app in this repo's `sso/` module as-is (that app targets a generic,
self-managed Cognito pool). This document covers wiring Zitadel into RES's pool.

> **Protocol note.** RES officially documents **SAML 2.0 only** for external IdP
> federation. OIDC works because Cognito supports it, but it is **not** a
> documented or supported RES path. Use SAML unless you have a specific reason
> not to. Both are covered below.

## 🧭 How RES identity fits together

RES separates **user data** from **authentication**, and both matter:

| Plane | Source | Purpose |
|-------|--------|---------|
| User & group data | **Active Directory** (AWS Managed Microsoft AD or self-managed), synced hourly via LDAP | Populates the RES Users page, POSIX identity (uid/gid), VDI OS login |
| Portal authentication | **Cognito → external IdP (Zitadel)** | Who the person is at login time |

```
Active Directory ──LDAP hourly sync──▶ RES internal DB
       │                                     ▲
       │ (same users must exist in both)     │ email must match a synced AD user
       ▼                                     │
   Zitadel  ──SAML/OIDC federation──▶  Cognito (res-<env>-user-pool)  ──▶  RES portal
```

**Critical constraint:** the email address Zitadel asserts at login **must match
the email of a user already synced into RES from Active Directory**. RES does not
create users from the IdP assertion — it links the login to an existing
AD-synced record by email. A user who authenticates through Zitadel but has no
matching AD-synced user will not get a valid RES session.

Practical consequence: **Zitadel must serve the same users that exist in your
RES-attached AD, with matching email addresses.** The cleanest way to achieve
this is to have Zitadel federate/broker against that same AD (see
[Sourcing users from AD](#-sourcing-zitadel-users-from-the-same-ad)). RES can
optionally run Cognito as a native user directory without AD, but those users
cannot launch Windows VDIs — this guide assumes the standard AD-backed setup.

## 📋 Prerequisites

- A **deployed, healthy Zitadel** instance from this repo (stage 1 complete;
  reachable at `https://<domain_name>`) and admin console access. See the
  [README](../README.md).
- A **deployed RES environment** with an Active Directory attached and at least
  one AD user synced (visible on the RES **Users** page).
- RES admin access (`admin` / `clusteradmin`) to the RES web portal.
- The users you intend to log in with **exist in both** the RES-attached AD and
  Zitadel, with identical email addresses.

## 🎯 Collect the RES-side values

Sign in to the RES portal and go to **Environment Management → General Settings
→ Identity Provider** (on RES 2025.03+ this is under the **Identity management**
page). Record:

| RES field | Example | You'll need it for |
|-----------|---------|--------------------|
| **User Pool ID** | `us-east-1_AbCdEf123` | Building the SP entity ID / audience |
| **SAML Redirect URL** | `https://<pool-domain>/saml2/idpresponse` | Zitadel SAML app ACS/redirect |
| **Domain URL** | `https://<pool-domain>` | Logout URL |

From those, construct:

- **SP entity ID / audience:** `urn:amazon:cognito:sp:<user-pool-id>`
- **ACS / Cognito assertion endpoint:** `https://<pool-domain>/saml2/idpresponse`
- **Logout URL:** `https://<pool-domain>/saml2/logout`

> `<pool-domain>` is the Cognito hosted-UI domain of the RES-managed pool, shown
> in the RES Identity Provider settings and in the Cognito console under
> `res-<env>-user-pool`.

---

## 🅰️ Path A — SAML 2.0 (RES-supported, recommended)

### A1. Create a SAML application in Zitadel

Zitadel exposes SAML app management in the console (or via the
`zitadel_application_saml` Terraform resource — not added to this repo yet; see
[Terraform notes](#-terraform-notes)).

1. Log in to the Zitadel console (`https://<domain_name>/ui/console`) as an org
   owner.
2. Open (or create) a **Project** → **New Application** → type **SAML**.
3. Provide the SP metadata. RES/Cognito publishes SP metadata; the simplest
   approach is to configure the entity manually in Zitadel with:
   - **Entity ID / Audience:** `urn:amazon:cognito:sp:<user-pool-id>`
   - **ACS URL (HTTP-POST binding):** `https://<pool-domain>/saml2/idpresponse`
4. Ensure the assertion carries the user's **email** as both the **NameID
   (Subject)** and an attribute named **`email`**. In Zitadel's SAML app
   attribute mapping, map the user's email to the `email` assertion attribute
   and set the NameID format to email address.

Zitadel's IdP SAML metadata (which RES needs) is published at:

```
https://<domain_name>/saml/v2/metadata
```

### A2. Configure SSO in RES

In the RES portal: **Identity Provider → Single Sign-On → Edit**:

| RES SSO field | Value |
|---------------|-------|
| Identity Provider | `SAML` |
| Provider Name | A unique name, e.g. `Zitadel` (not `Cognito` / `IdentityCenter`) |
| Metadata Document Source | The Zitadel metadata URL above, **or** upload the metadata XML |
| Provider Email Attribute | `email` |

Choose **Submit**, reload the page, and confirm the SSO status shows
**enabled**.

### A3. What Cognito expects in the assertion

RES/Cognito validates these in the SAML response — Zitadel must produce them:

| Element | Required value |
|---------|----------------|
| `Subject` / NameID | user's email |
| `email` attribute | user's email |
| `AudienceRestriction` → `Audience` | `urn:amazon:cognito:sp:<user-pool-id>` |
| `Response` `Destination` | `https://<pool-domain>/saml2/idpresponse` |
| `SubjectConfirmationData` `Recipient` | `https://<pool-domain>/saml2/idpresponse` |

Email is the only identity claim RES requires. It is also the value matched
against the AD-synced RES user record.

---

## 🅱️ Path B — OIDC (unofficial, advanced)

RES does not document OIDC federation, but Cognito supports OIDC IdPs and this
repo's `sso/` module already produces an OIDC application. To use it you must
configure the OIDC IdP **directly on the RES-managed Cognito pool** (the RES SSO
form only offers SAML), then point RES's login at it. This is unsupported by RES
and may break across RES upgrades — proceed only if you understand the tradeoffs.

### B1. Point the Zitadel OIDC app at the RES Cognito pool

The repo's `sso/` OIDC app takes a single `cognito_callback_url`. Set it to the
**RES-managed pool's** OIDC callback (not a pool you create):

```
https://<pool-domain>/oauth2/idpresponse
```

Set that as `cognito_callback_url` in `sso/envs/<env>/terraform.tfvars` and
re-apply the `sso/` module, then collect the credentials:

```bash
terraform -chdir=sso output -raw cognito_oidc_client_id
terraform -chdir=sso output -raw cognito_oidc_client_secret
terraform            output -raw issuer_url   # https://<domain_name>
```

### B2. Add Zitadel as an OIDC IdP on the RES Cognito pool

In the Cognito console → `res-<env>-user-pool` → **Sign-in experience →
Federated identity provider sign-in → Add identity provider → OpenID Connect**:

| Cognito field | Value |
|---------------|-------|
| Issuer URL | `https://<domain_name>` (Cognito reads `/.well-known/openid-configuration`) |
| Client ID | `cognito_oidc_client_id` output |
| Client secret | `cognito_oidc_client_secret` output |
| Authorized scopes | `openid profile email` |

Map the OIDC `email` claim to the Cognito `email` attribute (and `given_name` /
`family_name` / `name` if you want them populated). As with SAML, the `email`
value must match an AD-synced RES user.

### B3. Wire RES to use the IdP

Because the RES SSO form is SAML-only, enabling the OIDC IdP for RES logins
means editing the Cognito app-client IdP list and the RES
`<env>.cluster-settings` DynamoDB entry
(`identity-provider.cognito.sso_idp_provider_email_attribute = email`) directly,
per the "non-production environment" guidance in the RES docs. Validate in a
non-production environment first.

---

## 👥 Sourcing Zitadel users from the same AD

Because RES links logins to AD-synced users by email, Zitadel needs to present
the *same* users. Options, in rough order of preference:

1. **Zitadel brokers/federates to the same AD/LDAP.** Configure Zitadel's
   inbound LDAP identity provider against the directory RES uses (Zitadel
   console → org → **Identity Providers → LDAP**). Users authenticate against AD
   through Zitadel; emails line up automatically. See the
   [README LDAP section](../README.md#️-optional-adldap-identity-provider).
2. **Provision matching Zitadel users** (SCIM/API/manual) with emails identical
   to the AD users. Higher maintenance; only sensible for small, static user
   sets.

Whichever you choose, verify the asserted email exactly matches the RES Users
page entry for that person.

## ✅ Verify the integration

1. Confirm the test user appears on the RES **Users** page (trigger an AD sync
   if needed — Identity management page on 2025.03+, or the
   `<env>-scheduled-ad-sync` Lambda on older releases).
2. Open the RES portal login and choose the Zitadel SSO option.
3. Authenticate in Zitadel; you should land back in the RES portal
   authenticated as that user.
4. On first successful login the RES user transitions from *inactive* to active.

## 🛠️ Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Login succeeds at Zitadel but RES rejects the session | Asserted email doesn't match any AD-synced RES user, or the user hasn't synced yet |
| Cognito error `invalid_saml_response` / audience mismatch | `AudienceRestriction` ≠ `urn:amazon:cognito:sp:<user-pool-id>` |
| Redirect/ACS mismatch | Zitadel ACS URL isn't exactly `https://<pool-domain>/saml2/idpresponse` |
| No email in RES | `email` attribute/claim not mapped in the Zitadel app |
| SSO toggle won't enable | Provider Name collides with a reserved name, or metadata URL unreachable |

## 📝 Terraform notes

This repo's `sso/` module currently provisions an OIDC application only
(`zitadel_application_oidc`). To manage the **SAML** path as code, a
`zitadel_application_saml` resource would be added to `sso/main.tf` (feeding it
the RES pool's SP metadata / entity ID), with the Zitadel metadata URL surfaced
as an output for the RES SSO form. That change is out of scope for this
runbook — the steps above use the Zitadel console.

## 📚 References

- [RES User Guide — Overview](https://docs.aws.amazon.com/res/latest/ug/overview.html)
- [RES — Configure identity federation (SAML)](https://docs.aws.amazon.com/res/latest/ug/configure-id-federation.html)
- [RES — SSO with IAM Identity Center](https://docs.aws.amazon.com/res/latest/ug/sso-idc.html)
- [RES — Prerequisites](https://docs.aws.amazon.com/res/latest/ug/prerequisites.html)
- [aws/res on GitHub](https://github.com/aws/res)
