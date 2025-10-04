#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# -------------------------------
# Update system
# -------------------------------
sudo apt-get update -y
sudo apt-get upgrade -y

# Install Docker + Java 17 + basic tools
sudo apt-get install -y docker.io git curl wget unzip openjdk-17-jdk apt-transport-https ca-certificates gnupg lsb-release software-properties-common fontconfig conntrack

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Add ubuntu user to Docker group
sudo usermod -aG docker ubuntu

# -------------------------------
# Install kubectl (latest stable)
# -------------------------------
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# -------------------------------
# Install k3s (server mode)
# -------------------------------
curl -sfL https://get.k3s.io | sh -

# Wait until k3s is up
sleep 30

# Setup kubeconfig for ubuntu user (replace 127.0.0.1 with EC2 IP)
EC2_IP=$(hostname -I | awk '{print $1}')
mkdir -p /home/ubuntu/.kube
sudo sed "s/127.0.0.1/$EC2_IP/" /etc/rancher/k3s/k3s.yaml | sudo tee /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# -------------------------------
# Run Jenkins in Docker
# -------------------------------
if [ ! "$(sudo docker ps -q -f name=jenkins)" ]; then
  sudo docker run -d --name jenkins --restart unless-stopped \
    -p 8080:8080 -p 50000:50000 \
    -v jenkins_home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/bin/docker:/usr/bin/docker \
    -v /usr/local/bin/kubectl:/usr/local/bin/kubectl \
    -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
    jenkins/jenkins:lts-jdk17
fi

# -------------------------------
# Post-setup inside Jenkins container
# -------------------------------
sudo docker exec -u root jenkins bash -c "apt-get update && apt-get install -y git curl"
sudo docker exec -u root jenkins bash -c "ln -sf /usr/local/bin/kubectl /usr/bin/kubectl"

# Verify tools inside Jenkins
sudo docker exec jenkins docker --version
sudo docker exec jenkins kubectl version --client || true
sudo docker exec jenkins kubectl get nodes || true

# -------------------------------
# Run SonarQube in Docker (port 9000)
# -------------------------------
sudo sysctl --system
sudo docker volume create sonarqube_data
sudo docker volume create sonarqube_extensions
sudo docker volume create sonarqube_logs

if [ ! "$(sudo docker ps -q -f name=sonarqube)" ]; then
  sudo docker run -d --name sonarqube --restart unless-stopped \
    -p 9000:9000 \
    -v sonarqube_data:/opt/sonarqube/data \
    -v sonarqube_extensions:/opt/sonarqube/extensions \
    -v sonarqube_logs:/opt/sonarqube/logs \
    sonarqube:lts-community
fi

# -------------------------------
# Reboot if required
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  sudo reboot
fi
