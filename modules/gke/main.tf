resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  # Autopilot — fully managed nodes
  enable_autopilot = true

  # Private cluster — no public nodes
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # VPC-native (alias IPs)
  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pod_range_name
    services_secondary_range_name = var.service_range_name
  }

  # Authorized networks for kubectl access
  dynamic "master_authorized_networks_config" {
    for_each = length(var.authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # Workload Identity — pods use GCP IAM directly
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Google Cloud Managed Prometheus
  dynamic "monitoring_config" {
    for_each = var.enable_managed_prometheus ? [1] : []
    content {
      enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
      managed_prometheus {
        enabled = true
      }
    }
  }

  # Release channel for automatic k8s upgrades
  release_channel {
    channel = "REGULAR"
  }

  # Binary Authorization (supply-chain security)
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Logging
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Cluster-level addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  resource_labels = var.labels

  lifecycle {
    ignore_changes = [
      # Autopilot manages resource_labels internally
      resource_labels["goog-autopilot-resource-owned-by"],
    ]
  }
}
