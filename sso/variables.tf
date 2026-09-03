variable "domain_name" {
  description = "FQDN where the Zitadel service is reachable, e.g. id.example.com. Matches stage 1."
  type        = string
}

variable "jwt_profile_file" {
  description = "Path to the service-user JSON key used to authenticate against the Zitadel API."
  type        = string
  default     = "zitadel-admin-sa.json"
}

variable "project_name" {
  description = "Name of the Zitadel project to create."
  type        = string
  default     = "demo"
}

variable "cognito_callback_url" {
  description = "Cognito OIDC callback (redirect) URL for the Zitadel OIDC app. Placeholder allowed until Cognito exists."
  type        = string
  default     = "https://example.auth.us-east-1.amazoncognito.com/oauth2/idpresponse"
}
