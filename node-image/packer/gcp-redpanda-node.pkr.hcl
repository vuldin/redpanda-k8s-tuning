# Packer template for building Redpanda-tuned GCP GKE node image
# This creates a custom GCE image with Redpanda tuning pre-applied
#
# Usage:
#   packer init gcp-redpanda-node.pkr.hcl
#   packer build -var 'project_id=my-project' gcp-redpanda-node.pkr.hcl

packer {
  required_version = ">= 1.9.0"

  required_plugins {
    googlecompute = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

# ============================================================================
# Variables
# ============================================================================

variable "project_id" {
  type        = string
  description = "GCP project ID where the image will be created"
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "GCP zone to use for the builder VM"
}

variable "source_image_family" {
  type        = string
  default     = "ubuntu-2204-lts"
  description = "Source image family to build from"
}

variable "source_image_project" {
  type        = string
  default     = "ubuntu-os-cloud"
  description = "GCP project containing the source image"
}

variable "machine_type" {
  type        = string
  default     = "n2-standard-4"
  description = "Machine type for the builder VM"
}

variable "disk_size" {
  type        = number
  default     = 20
  description = "Disk size in GB for the builder VM"
}

variable "disk_type" {
  type        = string
  default     = "pd-ssd"
  description = "Disk type for the builder VM"
}

variable "image_name" {
  type        = string
  default     = "redpanda-gke-node"
  description = "Name of the output image (will be suffixed with timestamp)"
}

variable "image_family" {
  type        = string
  default     = "redpanda-gke-nodes"
  description = "Image family for versioning"
}

variable "image_description" {
  type        = string
  default     = "GKE node image optimized for Redpanda with pre-applied kernel tuning"
  description = "Description of the output image"
}

variable "iotune_duration" {
  type        = string
  default     = "10m"
  description = "Duration for iotune benchmark (use longer for production)"
}

# ============================================================================
# Source Configuration
# ============================================================================

source "googlecompute" "redpanda_node" {
  project_id = var.project_id
  zone       = var.zone

  # Source image
  source_image_family  = var.source_image_family
  source_image_project_id = [var.source_image_project]

  # Builder VM configuration
  machine_type = var.machine_type
  disk_size    = var.disk_size
  disk_type    = var.disk_type

  # SSH configuration
  ssh_username = "packer"
  ssh_timeout  = "10m"

  # Output image configuration
  image_name        = "${var.image_name}-{{timestamp}}"
  image_family      = var.image_family
  image_description = var.image_description

  # Image labels
  image_labels = {
    created_by   = "packer"
    image_family = var.image_family
    optimized_for = "redpanda"
  }

  # Tags for firewall rules (if needed)
  tags = ["packer-builder"]

  # Shutdown behavior
  on_host_maintenance = "MIGRATE"
  preemptible        = false
}

# ============================================================================
# Build Configuration
# ============================================================================

build {
  name    = "redpanda-gke-node"
  sources = ["source.googlecompute.redpanda_node"]

  # Update system packages
  provisioner "shell" {
    inline = [
      "echo '==> Updating system packages'",
      "sudo apt-get update -qq",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq",
      "sudo apt-get install -y -qq curl gnupg2 ca-certificates lsb-release wget"
    ]
  }

  # Install Docker (required for GKE)
  provisioner "shell" {
    inline = [
      "echo '==> Installing Docker'",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io"
    ]
  }

  # Install Kubernetes components (kubectl, kubelet)
  provisioner "shell" {
    inline = [
      "echo '==> Installing Kubernetes components'",
      "curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl"
    ]
  }

  # Install Redpanda (for rpk)
  provisioner "shell" {
    inline = [
      "echo '==> Installing Redpanda (rpk)'",
      "curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.deb.sh' | sudo -E bash",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq redpanda",
      "rpk version"
    ]
  }

  # Run Redpanda tuning
  provisioner "shell" {
    environment_vars = [
      "IOTUNE_DURATION=${var.iotune_duration}"
    ]
    inline = [
      "echo '==> Running Redpanda tuning'",
      "sudo rpk redpanda mode production",
      "sudo rpk redpanda tune all --reboot-allowed=false || echo 'Some tuners may have failed, continuing...'",
      "echo '==> Tuning completed'"
    ]
  }

  # Create systemd service for tuning persistence
  provisioner "file" {
    content = <<-EOF
      [Unit]
      Description=Redpanda Node Tuning
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/rpk redpanda tune all --reboot-allowed=false
      RemainAfterExit=yes
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target
    EOF
    destination = "/tmp/redpanda-tune.service"
  }

  provisioner "shell" {
    inline = [
      "echo '==> Installing systemd service for tuning persistence'",
      "sudo mv /tmp/redpanda-tune.service /etc/systemd/system/redpanda-tune.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable redpanda-tune.service"
    ]
  }

  # Create tuning marker
  provisioner "shell" {
    inline = [
      "echo '==> Creating tuning marker'",
      "echo \"$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")\" | sudo tee /var/lib/redpanda-tuned",
      "echo \"Image built with Packer\" | sudo tee -a /var/lib/redpanda-tuned"
    ]
  }

  # Add GKE-specific optimizations
  provisioner "shell" {
    inline = [
      "echo '==> Applying GKE-specific optimizations'",
      # Disable swap
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^\\(.*\\)$/#\\1/g' /etc/fstab",
      # Enable IP forwarding
      "echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf",
      "echo 'net.bridge.bridge-nf-call-iptables=1' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf",
      # Load kernel modules
      "echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/kubernetes.conf",
      "echo 'overlay' | sudo tee -a /etc/modules-load.d/kubernetes.conf"
    ]
  }

  # Clean up
  provisioner "shell" {
    inline = [
      "echo '==> Cleaning up'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*",
      # Clear bash history
      "history -c",
      "cat /dev/null > ~/.bash_history"
    ]
  }

  # Validation
  provisioner "shell" {
    inline = [
      "echo '==> Validating installation'",
      "echo 'Checking rpk...'",
      "rpk version",
      "echo 'Checking Docker...'",
      "sudo docker --version",
      "echo 'Checking kubelet...'",
      "kubelet --version",
      "echo 'Checking tuning marker...'",
      "cat /var/lib/redpanda-tuned",
      "echo 'Checking systemd service...'",
      "systemctl is-enabled redpanda-tune.service",
      "echo '==> Validation complete!'"
    ]
  }

  # Image creation summary
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}

# ============================================================================
# Output
# ============================================================================

# After build, Packer will output:
# - Image name: redpanda-gke-node-<timestamp>
# - Image family: redpanda-gke-nodes
# - Image self-link for use in Terraform/gcloud
#
# Use the image with GKE:
#   gcloud container node-pools create redpanda-pool \
#     --cluster=my-cluster \
#     --image-type=CUSTOM \
#     --image=redpanda-gke-node-<timestamp> \
#     --image-project=<project-id> \
#     --machine-type=n2-standard-16 \
#     --num-nodes=3
