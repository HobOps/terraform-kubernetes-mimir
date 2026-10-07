# terraform-kubernetes-mimir

Terraform module that installs a **multi-tenant Grafana Mimir** (chart
`grafana/mimir-distributed`) for a central metrics cluster: one tenant per
customer, basic auth per tenant, per-tenant limits and retention, S3 object
storage and an optional Gateway API route for remote clients (Grafana Alloy,
Prometheus `remote_write`).

Providers (`helm`, `kubernetes`, `kubectl`, `random`) are configured by the
**caller**. Where the tenant credentials end up (Vault, SOPS, a Grafana
datasource) is also the caller's choice: the module only outputs them.

Per-cluster monitoring (kube-prometheus-stack, exporters) stays in
[`terraform-kubernetes-monitoring`](https://github.com/HobOps/terraform-kubernetes-monitoring);
this module is applied once, from its own root, so adding a tenant never
touches a cluster stack.

## What it deploys

| Piece | Choice |
|---|---|
| Architecture | **Classic** (distributors → ingesters, no Kafka), the chart's `classic-architecture.yaml` |
| Ingesters | `ingester_replicas` (default 3) in three logical zones, replication factor 3, anti-affinity by hostname |
| Other components | 1 replica each; store-gateway replication factor 1; memcached caches off; ruler and alertmanager off |
| Storage | One S3 bucket with prefixes `blocks/`, `ruler/`, `alertmanager/`; volumes on `storage_class` |
| Config | Rendered into a Secret (it holds the S3 credentials) |
| Auth | nginx gateway with basic auth; one random password per tenant |
| Tenant binding | `X-Scope-OrgID` **must equal the authenticated user**, or the gateway answers 403 |
| Limits | Per-tenant overrides (retention, ingestion rate/burst, max series) in the runtime config |

### Why the tenant binding

The chart's nginx forwards whatever `X-Scope-OrgID` the client sends, even with
basic auth enabled: a client with valid credentials could write to or read from
any tenant. The module adds an `httpSnippet`/`serverSnippet` pair that rejects
requests whose header differs from the basic-auth user. `/` and `/ready` stay
open for health checks. Tenant federation (`a|b`) is therefore not possible
through the gateway.

## Usage

```hcl
module "mimir" {
  source = "git::https://github.com/HobOps/terraform-kubernetes-mimir.git?ref=v0.1.0"

  tenants = {
    acme   = {}
    globex = { retention = "180d", max_global_series_per_user = 300000 }
  }

  s3 = {
    endpoint          = "s3.example.internal:3900"
    bucket            = "mimir"
    region            = "garage"
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    insecure          = true # plain HTTP
  }

  storage_class = "local-path"

  httproute = {
    hostname          = "mimir.example.com"
    gateway_name      = "public-gateway"
    gateway_namespace = "infrastructure"
  }
}
```

A client pushes with basic auth `acme:<password>` and the header
`X-Scope-OrgID: acme` to `https://mimir.example.com/api/v1/push`; Grafana
queries `https://mimir.example.com/prometheus` the same way.

See [`examples/complete`](examples/complete).

## Inputs

| Name | Description | Default |
|---|---|---|
| `tenants` | Map of tenant ID → optional `retention`, `ingestion_rate`, `ingestion_burst_size`, `max_global_series_per_user` | `{}` |
| `default_limits` | Limits for every tenant unless overridden | 90d, 10000/s, burst 200000, 150000 series |
| `s3` | `endpoint`, `bucket`, `region`, `access_key_id`, `secret_access_key`, `insecure`, `bucket_lookup_type` | required |
| `namespace` | Namespace (created) | `mimir` |
| `release_name` | Helm release name | `mimir` |
| `chart_version` | `mimir-distributed` version | `6.2.1` |
| `ingester_replicas` | Ingesters (multiple of 3) | `3` |
| `storage_class` | StorageClass for volumes | cluster default |
| `ingester_storage_size` | Volume per ingester | `10Gi` |
| `httproute` | `hostname`, `gateway_name`, `gateway_namespace`, `section_name` | `null` |
| `values` | Extra chart values, merged after the module's | `{}` |

## Outputs

| Name | Description |
|---|---|
| `namespace` | Namespace |
| `internal_url` | In-cluster gateway URL |
| `external_url` | Public URL (with `httproute`) |
| `tenants` | Sensitive: per tenant `username`, `password`, `push_url`, `query_url`, `push_url_internal`, `query_url_internal` |

## Notes

- Tenant IDs: lowercase letters, digits, `-` and `_`.
- Removing a tenant removes its password (it can no longer push or query); its
  blocks stay in the bucket until retention or manual cleanup.
- Upgrading the chart: re-check the gateway nginx template still defines
  `httpSnippet`/`serverSnippet` and the classic-architecture keys.
