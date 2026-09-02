# Stage-2 resources. Applied from this directory after the stage-1 infra is
# healthy and a service-user key file exists (see repo README).
resource "zitadel_project" "this" {
  name = var.project_name
}

# OIDC application representing the external Cognito User Pool. Cognito uses the
# authorization-code flow with a confidential (client-secret) web app.
resource "zitadel_application_oidc" "cognito" {
  project_id = zitadel_project.this.id
  name       = "cognito"

  redirect_uris    = [var.cognito_callback_url]
  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
}
