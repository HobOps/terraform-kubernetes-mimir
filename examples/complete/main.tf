module "mimir" {
  source = "../.."

  tenants = {
    acme   = {}
    globex = { retention = "180d" }
  }

  s3 = {
    endpoint          = var.s3_endpoint
    bucket            = var.s3_bucket
    region            = "garage"
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    insecure          = true
  }

  storage_class = "local-path"

  httproute = {
    hostname          = "mimir.example.com"
    gateway_name      = "public-gateway"
    gateway_namespace = "infrastructure"
  }
}

output "tenants" {
  value     = module.mimir.tenants
  sensitive = true
}
