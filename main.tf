

# Internal HTTP load balancer with a managed instance group backend

# [START cloudloadbalancing_int_http_gce]
# VPC network
resource "google_compute_network" "vpc_network" {
  name                    = "vpc-network"
  provider                = google-beta
  auto_create_subnetworks = false
}

# proxy-only subnet
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "vikas-subnet1"
  provider      = google-beta
  ip_cidr_range = "10.0.1.0/24"
  region        = "asia-east1"
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.vpc_network.id
}

# backend subnet
resource "google_compute_subnetwork" "vpc_subnet" {
  name          = "vikas-subnet2"
  provider      = google-beta
  ip_cidr_range = "10.0.2.0/24"
  region        = "asia-east1"
  network       = google_compute_network.vpc_network.id
}

# forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  name                  = "vikas-forwarding-rule"
  provider              = google-beta
  region                = "asia-east1"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.vpc_network.id
  subnetwork            = google_compute_subnetwork.vpc_subnet.id
  network_tier          = "PREMIUM"
}

# HTTP target proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "vikas-target-http-proxy"
  provider = google-beta
  region   = "asia-east1"
  url_map  = google_compute_region_url_map.default.id
}

# URL map
resource "google_compute_region_url_map" "default" {
  name            = "vikas-regional-url-map"
  provider        = google-beta
  region          = "asia-east1"
  default_service = google_compute_region_backend_service.default.id
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "vikas-backend-subnet"
  provider              = google-beta
  region                = "asia-east1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "vikas-template"
  provider     = google-beta
  machine_type = "e2-small"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.vpc_subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF2
      #! /bin/bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq
      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v2/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v2/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v2/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')
      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF2
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_region_health_check" "default" {
  name     = "vikas-hc"
  provider = google-beta
  region   = "asia-east1"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name     = "vikas-mig1"
  provider = google-beta
  region   = "asia-east1"
  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# allow all access from IAP and health check ranges
resource "google_compute_firewall" "fw-iap" {
  name          = "vikas-fw-allow-iap-hc"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.vpc_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# allow http from proxy subnet to backends
resource "google_compute_firewall" "fw-ilb-to-backends" {
  name          = "vikas-fw-allow-ilb-to-backends"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.vpc_network.id
  source_ranges = ["10.0.1.0/24"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

# test instance
resource "google_compute_instance" "vm-test" {
  name         = "vikas-test-vm"
  provider     = google-beta
  zone         = "asia-east1-b"
  machine_type = "e2-small"
  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.vpc_subnet.id
  }
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }
}
