locals {
  gateway_service = "${var.release_name}-gateway"
  internal_url    = "http://${local.gateway_service}.${var.namespace}.svc.cluster.local"
  external_url    = var.httproute != null ? "https://${var.httproute.hostname}" : null

  # Per-tenant public hostnames: <prefix>-<tenant>-<random suffix>.<domain>.
  # "_" is valid in a tenant ID but not in a hostname.
  per_tenant_hostnames = var.httproute != null && try(var.httproute.tenant_hostnames, null) != null
  tenant_hostname = local.per_tenant_hostnames ? {
    for t in keys(var.tenants) :
    t => "${var.httproute.tenant_hostnames.prefix}-${replace(t, "_", "-")}-${random_string.tenant_suffix[t].result}.${var.httproute.tenant_hostnames.domain}"
  } : {}
  tenant_external_url = {
    for t in keys(var.tenants) : t => local.per_tenant_hostnames ? "https://${local.tenant_hostname[t]}" : local.external_url
  }

  # Hostnames the gateway serves for any authenticated tenant: the in-cluster
  # service names (Grafana, Prometheus) and local port-forwards. They are not
  # reachable through the public Gateway, whose routes only carry the public
  # hostnames.
  internal_hostnames = [
    local.gateway_service,
    "${local.gateway_service}.${var.namespace}",
    "${local.gateway_service}.${var.namespace}.svc",
    "${local.gateway_service}.${var.namespace}.svc.cluster.local",
    "localhost",
    "127.0.0.1",
  ]
  nginx_host_map = join("\n", concat(
    [for h in local.internal_hostnames : "  ${h} \"*\";"],
    [for t in sort(keys(local.tenant_hostname)) : "  ${local.tenant_hostname[t]} \"${t}\";"],
  ))

  # Per-tenant limits for Mimir's runtime config. Each tenant gets every limit
  # explicitly, so changing default_limits applies to all of them.
  tenant_overrides = {
    for t, cfg in var.tenants : t => {
      compactor_blocks_retention_period = coalesce(cfg.retention, var.default_limits.retention)
      ingestion_rate                    = coalesce(cfg.ingestion_rate, var.default_limits.ingestion_rate)
      ingestion_burst_size              = coalesce(cfg.ingestion_burst_size, var.default_limits.ingestion_burst_size)
      max_global_series_per_user        = coalesce(cfg.max_global_series_per_user, var.default_limits.max_global_series_per_user)
    }
  }

  htpasswd = join("\n", [
    for t in sort(keys(var.tenants)) : "${t}:${random_password.tenant[t].bcrypt_hash}"
  ])

  # The chart's nginx takes the tenant from the X-Scope-OrgID header the client
  # sends, even with basic auth on, so a client could pick any tenant. These
  # snippets reject (403) any request whose X-Scope-OrgID differs from the
  # authenticated user. "/" and "/ready" stay open for health checks. The
  # check runs in the rewrite phase, before auth_basic: a right header with a
  # wrong password still gets 401 afterwards.
  #
  # With per-tenant hostnames the Host must also belong to that tenant
  # ($tenant_host = tenant), or be an in-cluster name ($tenant_host = "*").
  # Any other Host, the shared public hostname included, only serves the
  # health paths.
  nginx_http_snippet = local.per_tenant_hostnames ? local.nginx_http_snippet_per_tenant : local.nginx_http_snippet_shared

  nginx_http_snippet_per_tenant = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      "/ready" 1;
      default  0;
    }
    map $host $tenant_host {
      hostnames;
      default "";
    ${local.nginx_host_map}
    }
    map "$tenant_check_public:$tenant_host:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                      1;
      "~^0:\*:([^:|]+):\1$"       1;
      "~^0:([^:|*]+):\1:\1$"      1;
      default                     0;
    }
  EOT

  nginx_http_snippet_shared = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      "/ready" 1;
      default  0;
    }
    map "$tenant_check_public:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                1;
      "~^0:([^:|]+):\1$"    1;
      default               0;
    }
  EOT

  nginx_server_snippet = <<-EOT
    if ($tenant_check_ok = 0) {
      return 403 "use your tenant's hostname with its basic auth and X-Scope-OrgID equal to the user\n";
    }
  EOT

  module_values = {
    # Classic architecture (Mimir 2 style): distributors write straight to the
    # ingesters, no Kafka. Same keys as the chart's classic-architecture.yaml.
    kafka = { enabled = false }
    minio = { enabled = false }

    # The rendered config holds the S3 credentials: keep it in a Secret.
    configStorageType = "Secret"

    mimir = {
      structuredConfig = {
        multitenancy_enabled = true
        ingest_storage = {
          enabled = false
          kafka = {
            address                              = null
            topic                                = null
            auto_create_topic_default_partitions = null
          }
        }
        distributor = { remote_timeout = null }
        ingester    = { push_grpc_method_enabled = null }

        common = {
          storage = {
            backend = "s3"
            s3 = {
              endpoint           = var.s3.endpoint
              bucket_name        = var.s3.bucket
              region             = var.s3.region
              access_key_id      = var.s3.access_key_id
              secret_access_key  = var.s3.secret_access_key
              insecure           = var.s3.insecure
              bucket_lookup_type = var.s3.bucket_lookup_type
            }
          }
        }
        blocks_storage       = { storage_prefix = "blocks" }
        ruler_storage        = { storage_prefix = "ruler" }
        alertmanager_storage = { storage_prefix = "alertmanager" }

        # Tenants not listed in var.tenants cannot authenticate, but keep the
        # global defaults equal to default_limits anyway.
        limits = {
          compactor_blocks_retention_period = var.default_limits.retention
          ingestion_rate                    = var.default_limits.ingestion_rate
          ingestion_burst_size              = var.default_limits.ingestion_burst_size
          max_global_series_per_user        = var.default_limits.max_global_series_per_user
        }

        store_gateway = {
          sharding_ring = { replication_factor = 1 }
        }
      }
    }

    runtimeConfig = {
      overrides = local.tenant_overrides
    }

    ingester = {
      replicas = var.ingester_replicas
      zoneAwareReplication = {
        enabled     = true
        topologyKey = "kubernetes.io/hostname"
      }
      persistentVolume = merge(
        { size = var.ingester_storage_size },
        var.storage_class != null ? { storageClass = var.storage_class } : {},
      )
    }

    store_gateway = {
      replicas             = 1
      zoneAwareReplication = { enabled = false }
      persistentVolume     = var.storage_class != null ? { storageClass = var.storage_class } : {}
    }

    compactor = {
      replicas         = 1
      persistentVolume = var.storage_class != null ? { storageClass = var.storage_class } : {}
    }

    querier         = { replicas = 1 }
    query_scheduler = { replicas = 1 }

    # Alerts stay in Prometheus/Grafana for now (ADR 0019).
    ruler        = { enabled = false }
    alertmanager = { enabled = false }

    gateway = {
      enabled = true
      nginx = {
        basicAuth = {
          enabled        = true
          existingSecret = kubernetes_secret.htpasswd.metadata[0].name
        }
        config = {
          httpSnippet   = local.nginx_http_snippet
          serverSnippet = local.nginx_server_snippet
        }
      }
    }
  }
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "tenant" {
  for_each = var.tenants

  length  = 48
  special = false
}

# Random part of each tenant's public hostname. Rotate it with
# terraform apply -replace='module.<name>.random_string.tenant_suffix["<tenant>"]'.
resource "random_string" "tenant_suffix" {
  for_each = local.per_tenant_hostnames ? var.tenants : {}

  length  = var.httproute.tenant_hostnames.suffix_length
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "kubernetes_secret" "htpasswd" {
  metadata {
    name      = "${var.release_name}-gateway-htpasswd"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    ".htpasswd" = local.htpasswd
  }
}

resource "helm_release" "mimir" {
  name       = var.release_name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "mimir-distributed"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name
  timeout    = 900
  wait       = true

  values = [
    yamlencode(local.module_values),
    yamlencode(var.values),
  ]
}

resource "kubectl_manifest" "httproute" {
  count = var.httproute != null ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = local.gateway_service
      namespace = var.namespace
    }
    spec = {
      parentRefs = [{
        name        = var.httproute.gateway_name
        namespace   = var.httproute.gateway_namespace
        sectionName = var.httproute.section_name
      }]
      hostnames = concat([var.httproute.hostname], [for t in sort(keys(local.tenant_hostname)) : local.tenant_hostname[t]])
      rules = [{
        matches     = [{ path = { type = "PathPrefix", value = "/" } }]
        backendRefs = [{ name = local.gateway_service, port = 80 }]
      }]
    }
  })

  depends_on = [helm_release.mimir]
}
