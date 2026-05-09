project_id   = "my-gcp-project-prod"
region       = "us-central1"
cluster_name = "gke-prod"
environment  = "prod"

vpc_name     = "vpc-gke-prod"
subnet_cidr  = "10.0.0.0/20"
pod_cidr     = "10.1.0.0/16"
service_cidr = "10.2.0.0/20"

master_ipv4_cidr_block = "172.16.0.32/28"

authorized_networks = [
  {
    cidr_block   = "10.0.10.5/32"
    display_name = "jump-host"
  }
]

enable_workload_identity  = true
enable_managed_prometheus = true
enable_cloud_armor        = true
