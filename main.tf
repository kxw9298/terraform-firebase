# Define sensitive variables for service account credentials
variable "google_service_account_key" {
  description = "Service account key JSON for Firestore access"
  type        = string
  sensitive   = true
}

# Example of reading the key locally (you can use Terraform Cloud environment variables as well)
locals {
  service_account_key = jsondecode(file("<path_to_your_service_account_key.json>"))
}

# Extract required fields from JSON object
locals {
  client_email  = local.service_account_key.client_email
  private_key   = replace(local.service_account_key.private_key, "\n", "\\n")  # Properly format private key
  project_id    = local.service_account_key.project_id
}


terraform {
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "http" {}

# Generate JWT token using local-exec provisioner
data "external" "generate_jwt" {
  program = ["bash", "-c", <<EOT
    set -e
    client_email=${local.client_email}
    private_key=${local.private_key}
    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    claim=$(echo -n '{"iss":"'$client_email'","scope":"https://www.googleapis.com/auth/datastore","aud":"https://oauth2.googleapis.com/token","exp":'$(($(date +%s)+3600))',"iat":'$(date +%s)'}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    signed_content=$(echo -n "$header.$claim" | openssl dgst -sha256 -sign <(echo -n "$private_key" | base64 -d) | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    echo $header.$claim.$signed_content
EOT
  ]
}

# Exchange JWT token for Access Token
data "http" "get_access_token" {
  url = "https://oauth2.googleapis.com/token"

  request_body = jsonencode({
    grant_type   = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assertion    = data.external.generate_jwt.result["output"]
  })

  request_headers = {
    Content-Type = "application/json"
  }
}

# Parse the access token from the HTTP response
locals {
  access_token = jsondecode(data.http.get_access_token.response_body)["access_token"]
}

# Query Firestore Collection
data "http" "get_firestore_documents" {
  url = "https://firestore.googleapis.com/v1/projects/${local.project_id}/databases/(default)/documents/YOUR_COLLECTION_NAME"

  request_headers = {
    Authorization = "Bearer ${local.access_token}"
    Content-Type  = "application/json"
  }
}

# Output the response body containing documents
output "firestore_documents" {
  value = jsondecode(data.http.get_firestore_documents.response_body)
}
