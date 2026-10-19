variable "namespace" {
  description = "Namespace for Mimir (created by the module)."
  type        = string
  default     = "mimir"
}

variable "release_name" {
  description = "Helm release name. Service names derive from it (e.g. <release>-gateway)."
  type        = string
  default     = "mimir"
}

variable "chart_version" {
  description = "Version of the grafana/mimir-distributed chart."
  type        = string
  default     = "6.2.1"
}

variable "s3" {
  description = <<-EOT
    S3-compatible object storage for blocks, ruler and alertmanager data (one
    bucket, separate prefixes). `endpoint` is host:port without scheme;
    `insecure = true` means plain HTTP. `bucket_lookup_type = "path"` suits
    Garage and MinIO.
  EOT
  type = object({
    endpoint           = string
    bucket             = string
    region             = optional(string, "us-east-1")
    access_key_id      = string
    secret_access_key  = string
    insecure           = optional(bool, false)
    bucket_lookup_type = optional(string, "path")
  })
  sensitive = true
}

variable "tenants" {
  description = <<-EOT
    Tenants, keyed by tenant ID (also the basic-auth username). One per
    customer: hosts go in labels, not in tenants. Every field is optional and
    falls back to `default_limits`; values use Mimir's limit names and units
    (retention like "90d", 0 = keep forever).
  EOT
  type = map(object({
    retention                  = optional(string)
    ingestion_rate             = optional(number)
    ingestion_burst_size       = optional(number)
    max_global_series_per_user = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for t in keys(var.tenants) : can(regex("^[a-z0-9][a-z0-9_-]{0,149}$", t))])
    error_message = "Tenant IDs must be lowercase letters, digits, '-' or '_' (no ':' or '|')."
  }
}

variable "default_limits" {
  description = "Limits applied to every tenant unless the tenant overrides them."
  type = object({
    retention                  = optional(string, "90d")
    ingestion_rate             = optional(number, 10000)
    ingestion_burst_size       = optional(number, 200000)
    max_global_series_per_user = optional(number, 150000)
  })
  default = {}
}

variable "ingester_replicas" {
  description = "Ingesters, spread over three logical zones (replication factor 3). Use a multiple of 3."
  type        = number
  default     = 3
}

variable "storage_class" {
  description = "StorageClass for ingester, store-gateway and compactor volumes. null = cluster default. Durable data lives in S3."
  type        = string
  default     = null
}

variable "ingester_storage_size" {
  description = "Volume size per ingester (WAL and TSDB head)."
  type        = string
  default     = "10Gi"
}

variable "httproute" {
  description = <<-EOT
    Optional Gateway API HTTPRoute to the Mimir gateway (push and query for
    remote clients). null = no route.

    `hostname` is the shared public hostname. With `tenant_hostnames` set, every
    tenant also gets its own hostname `<prefix>-<tenant>-<random suffix>.<domain>`
    and the gateway accepts a tenant's credentials only on that hostname (or on
    the in-cluster service names); the shared hostname then answers only the
    health paths. `domain` must be covered by the listener's certificate: a
    wildcard keeps the tenant names out of Certificate Transparency.
  EOT
  type = object({
    hostname          = string
    gateway_name      = string
    gateway_namespace = string
    section_name      = optional(string, "https")
    tenant_hostnames = optional(object({
      domain        = string
      prefix        = optional(string, "mimir")
      suffix_length = optional(number, 8)
    }))
  })
  default = null
}

variable "values" {
  description = "Extra values for mimir-distributed, applied after the module's (Helm deep-merges maps; lists replace)."
  type        = any
  default     = {}
}
