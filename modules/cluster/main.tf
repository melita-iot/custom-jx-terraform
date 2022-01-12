// ----------------------------------------------------------------------------
// Create and configure the Kubernetes cluster
//
// https://www.terraform.io/docs/providers/google/r/container_cluster.html
// ----------------------------------------------------------------------------
locals {
  cluster_oauth_scopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/compute",
    "https://www.googleapis.com/auth/devstorage.full_control",
    "https://www.googleapis.com/auth/service.management",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring",
  ]
}
resource "google_container_cluster" "jx_cluster" {
  name                     = var.cluster_name
  description              = "jenkins-x cluster"
  location                 = var.cluster_location
  network                  = var.cluster_network
  subnetwork               = var.cluster_subnetwork
  enable_kubernetes_alpha  = var.enable_kubernetes_alpha
  enable_legacy_abac       = var.enable_legacy_abac
  enable_shielded_nodes    = var.enable_shielded_nodes
  remove_default_node_pool = true
  initial_node_count       = var.min_node_count
  logging_service          = var.logging_service
  monitoring_service       = var.monitoring_service


  //----added by david-----

  node_version            = var.node_version
  min_master_version      = var.min_master_version

  ip_allocation_policy {
    cluster_ipv4_cidr_block  = var.cluster_ipv4_cidr_block
    services_ipv4_cidr_block = var.services_ipv4_cidr_block
  }

  //-----------------------

  // should disable master auth
  master_auth {
    username = ""
    password = ""
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  release_channel {
    channel = var.release_channel
  }

  workload_identity_config {
    identity_namespace = "${var.gcp_project}.svc.id.goog"
  }

  resource_labels = var.resource_labels

}

resource "google_container_node_pool" "primary" {
  name                = "${var.cluster_name}-primary"
  location            = var.cluster_location
  cluster             = google_container_cluster.jx_cluster.name
  initial_node_count  = var.min_node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  node_config {
    preemptible  = var.node_preemptible
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size
    disk_type    = var.node_disk_type

    oauth_scopes = local.cluster_oauth_scopes

    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }
  }
}

module "jx-health" {
  count  = var.jx2 && var.kuberhealthy ? 0 : 1
  source = "github.com/jenkins-x/terraform-jx-health?ref=main"

  depends_on = [
    google_container_node_pool.primary
  ]
}

// ----------------------------------------------------------------------------
// Add main Jenkins X Kubernetes namespace
//
// https://www.terraform.io/docs/providers/kubernetes/r/namespace.html
// ----------------------------------------------------------------------------
resource "kubernetes_namespace" "jenkins_x_namespace" {
  count = var.jx2 ? 1 : 0
  metadata {
    name = var.jenkins_x_namespace
  }
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
  depends_on = [
    google_container_node_pool.primary
  ]
}

// ----------------------------------------------------------------------------
// Add the Terraform generated jx-requirements.yml to a configmap so it can be
// sync'd with the Git repository
//
// https://www.terraform.io/docs/providers/kubernetes/r/namespace.html
// ----------------------------------------------------------------------------
resource "kubernetes_config_map" "jenkins_x_requirements" {
  count = var.jx2 ? 0 : 1
  metadata {
    name      = "terraform-jx-requirements"
    namespace = "default"
  }
  data = {
    "jx-requirements.yml" = var.content
  }
  depends_on = [
    google_container_node_pool.primary
  ]
}

resource "helm_release" "jx-git-operator" {
  count = var.jx2 || var.jx_git_url == "" ? 0 : 1

  provider         = helm
  name             = "jx-git-operator"
  chart            = "jx-git-operator"
  namespace        = "jx-git-operator"
  repository       = "https://jenkins-x-charts.github.io/repo"
  version          = var.jx_git_operator_version
  create_namespace = true

  set {
    name  = "bootServiceAccount.enabled"
    value = true
  }
  set {
    name  = "bootServiceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = "${var.cluster_name}-boot@${var.gcp_project}.iam.gserviceaccount.com"
  }
  set {
    name  = "env.NO_RESOURCE_APPLY"
    value = true
  }
  set {
    name  = "url"
    value = var.jx_git_url
  }
  set {
    name  = "username"
    value = var.jx_bot_username
  }
  set {
    name  = "password"
    value = var.jx_bot_token
  }

  lifecycle {
    ignore_changes = all
  }
  depends_on = [
    google_container_node_pool.primary
  ]
}
