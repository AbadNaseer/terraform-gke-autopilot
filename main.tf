locals {
  common_labels = {
    environment = var.environment
    managed_by  = "terraform"
    project     = "gke-platform"
  }
}

module "networking" {
  source = "./modules/networking"

  project_id   = var.project_id
  region       = var.region
  environment  = var.environment
  vpc_name     = var.vpc_name
  subnet_cidr  = var.subnet_cidr
  pod_cidr     = var.pod_cidr
  service_cidr = var.service_cidr
  labels       = local.common_labels
}

module "iam" {
  source = "./modules/iam"

  project_id  = var.project_id
  environment = var.environment
  labels      = local.common_labels
}

module "gke" {
  source = "./modules/gke"

  project_id                = var.project_id
  region                    = var.region
  cluster_name              = var.cluster_name
  environment               = var.environment
  network_id                = module.networking.vpc_id
  subnet_id                 = module.networking.gke_subnet_id
  pod_range_name            = module.networking.pod_range_name
  service_range_name        = module.networking.service_range_name
  master_ipv4_cidr_block    = var.master_ipv4_cidr_block
  authorized_networks       = var.authorized_networks
  enable_workload_identity  = var.enable_workload_identity
  enable_managed_prometheus = var.enable_managed_prometheus
  node_service_account_email = module.iam.node_service_account_email
  labels                    = local.common_labels
}

module "artifact_registry" {
  source = "./modules/artifact-registry"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = local.common_labels
}

# Cloud Armor WAF security policy
resource "google_compute_security_policy" "waf" {
  name    = "waf-${var.cluster_name}"
  project = var.project_id

  # OWASP XSS prevention
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable')"
      }
    }
    description = "Block XSS attempts"
  }

  # OWASP SQLi prevention
  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "Block SQLi attempts"
  }

  # LFI prevention
  rule {
    action   = "deny(403)"
    priority = 1002
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-stable')"
      }
    }
    description = "Block LFI attempts"
  }

  # Rate limiting — 1000 req/60s per IP
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
    description = "Rate limit all IPs"
  }

  # Default allow
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}
