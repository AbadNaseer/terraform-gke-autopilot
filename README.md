# terraform-gke-autopilot

Production-ready **Google Kubernetes Engine (GKE) Autopilot** cluster provisioned with **Terraform**. Includes VPC-native networking, Workload Identity, Cloud Armor WAF, Google Cloud Monitoring, and a GitHub Actions CI/CD pipeline.

## Why GKE Autopilot

- **No node management** — Google manages nodes, node pools, OS patching
- **Per-pod billing** — pay only for requested CPU/memory, not idle node capacity
- **Built-in security** — Workload Identity, Shielded Nodes, Binary Authorization enforced by default
- **Auto-scaling** — horizontal and vertical pod scaling without cluster autoscaler configuration

## Architecture

```
GCP Project
└── VPC (vpc-gke-prod)
    ├── Subnet: subnet-gke (10.0.0.0/20)
    │   ├── Pod CIDR:     10.1.0.0/16  (VPC-native alias IPs)
    │   └── Service CIDR: 10.2.0.0/20
    └── GKE Autopilot Cluster (gke-prod)
        ├── Workload Identity (pod → GCP IAM)
        ├── Private cluster (no public nodes)
        ├── Authorized networks (jump-host only)
        └── Namespaces: prod / staging / monitoring
            │
            ├── Nginx Ingress → Cloud Load Balancer
            ├── cert-manager (Let's Encrypt)
            ├── External Secrets (Secret Manager)
            └── Prometheus + Grafana (Managed via Google Cloud Managed Prometheus)
```

## Stack

| Component | Tool |
|-----------|------|
| IaC | Terraform >= 1.5 |
| Provider | hashicorp/google ~> 5.0 |
| Cluster type | GKE Autopilot (private) |
| Networking | VPC-native (alias IPs) |
| Identity | Workload Identity |
| Secrets | External Secrets + GCP Secret Manager |
| WAF | Cloud Armor (OWASP rule set) |
| Monitoring | Google Cloud Managed Prometheus + Grafana |
| Registry | Artifact Registry |
| CI/CD | GitHub Actions + Workload Identity Federation |

## Repository Structure

```
terraform-gke-autopilot/
├── main.tf                   # Root module
├── variables.tf
├── outputs.tf
├── providers.tf
├── versions.tf
├── modules/
│   ├── gke/
│   │   ├── main.tf           # GKE Autopilot cluster
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── networking/
│   │   ├── main.tf           # VPC, subnets, Cloud NAT, Cloud Router
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── iam/
│   │   ├── main.tf           # Service accounts, Workload Identity bindings
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── artifact-registry/
│       ├── main.tf
│       └── variables.tf
├── kubernetes/
│   ├── namespaces.yaml
│   ├── network-policies.yaml
│   └── rbac.yaml
├── environments/
│   ├── dev.tfvars
│   ├── staging.tfvars
│   └── prod.tfvars
├── .github/
│   └── workflows/
│       ├── terraform-plan.yaml
│       └── terraform-apply.yaml
└── README.md
```

## Quick Start

### Prerequisites
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
terraform -v  # >= 1.5.0
```

### Enable GCP APIs
```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudarmor.googleapis.com \
  monitoring.googleapis.com
```

### Deploy
```bash
terraform init

terraform plan -var-file="environments/prod.tfvars" -out=tfplan
terraform apply tfplan
```

### Connect to cluster
```bash
gcloud container clusters get-credentials gke-prod \
  --region us-central1 \
  --project YOUR_PROJECT_ID

kubectl get nodes  # Autopilot: nodes appear as requests are scheduled
```

## Key Variables (`prod.tfvars`)

```hcl
project_id      = "my-gcp-project"
region          = "us-central1"
cluster_name    = "gke-prod"
environment     = "prod"

# Networking
vpc_name        = "vpc-gke-prod"
subnet_cidr     = "10.0.0.0/20"
pod_cidr        = "10.1.0.0/16"
service_cidr    = "10.2.0.0/20"

# Private cluster access
master_ipv4_cidr_block    = "172.16.0.32/28"
authorized_networks = [
  { cidr_block = "10.0.10.5/32", display_name = "jump-host" }
]

enable_cloud_armor        = true
enable_managed_prometheus = true
enable_workload_identity  = true
```

## Workload Identity (Pod → GCP IAM)

```hcl
# modules/iam/main.tf
resource "google_service_account" "api_service" {
  account_id   = "sa-api-service"
  display_name = "API Service - Workload Identity"
}

# Allow K8s service account to impersonate GCP SA
resource "google_service_account_iam_binding" "api_workload_identity" {
  service_account_id = google_service_account.api_service.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[prod/api-service-sa]"
  ]
}

# Grant access to Secret Manager
resource "google_project_iam_member" "api_secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.api_service.email}"
}
```

## Cloud Armor WAF (OWASP Rule Set)

```hcl
resource "google_compute_security_policy" "waf" {
  name = "waf-gke-prod"

  # OWASP Top 10 preconfigured rule
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable')"
      }
    }
  }

  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
  }

  # Rate limiting
  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 1000
        interval_sec = 60
      }
    }
  }
}
```

## CI/CD with Workload Identity Federation (no long-lived keys)

```yaml
# .github/workflows/terraform-apply.yaml
- name: Authenticate to GCP
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/123/locations/global/workloadIdentityPools/github/providers/github
    service_account: sa-github-actions@my-project.iam.gserviceaccount.com

- name: Terraform Apply
  run: terraform apply -var-file="environments/prod.tfvars" -auto-approve tfplan
```

## Monitoring (Google Cloud Managed Prometheus)

GKE Autopilot includes Google Cloud Managed Prometheus (GMP) out of the box:

```yaml
# PodMonitoring resource (GMP equivalent of Prometheus ServiceMonitor)
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: api-service-metrics
spec:
  selector:
    matchLabels:
      app: api-service
  endpoints:
  - port: metrics
    interval: 30s
```

Query metrics in Cloud Monitoring or connect Grafana via the `stackdriver` datasource.

## Cost Estimation (Autopilot vs Standard)

| Workload | Standard (e2-standard-4 × 3) | Autopilot (same pods) |
|---|---|---|
| Idle cluster | ~$150/mo | ~$0 (no idle node cost) |
| 10 pods (0.5 CPU, 512Mi each) | Included in node cost | ~$65/mo |
| Burst to 50 pods | Needs new nodes, ~15min | Immediate, no wait |

Autopilot typically **30-50% cheaper** for variable workloads.
