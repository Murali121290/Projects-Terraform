#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# -------------------------------
# System Update & Dependencies
# -------------------------------
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y docker.io git curl wget unzip openjdk-17-jdk \
    apt-transport-https ca-certificates gnupg lsb-release \
    software-properties-common fontconfig conntrack

# Enable Docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ubuntu

# -------------------------------
# Install kubectl
# -------------------------------
sudo curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
sudo rm kubectl

# -------------------------------
# Install K3s (single-node)
# -------------------------------
sudo curl -sfL https://get.k3s.io | sh -
sleep 30

# Setup kubeconfig for ubuntu user
EC2_IP=$(hostname -I | awk '{print $1}')
mkdir -p /home/ubuntu/.kube
sudo sed "s/127.0.0.1/$EC2_IP/" /etc/rancher/k3s/k3s.yaml > /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# -------------------------------
# Run Jenkins container
# -------------------------------
sudo docker run -d --name jenkins --restart unless-stopped \
  -u root \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  -v /usr/local/bin/kubectl:/usr/local/bin/kubectl \
  -v /usr/local/bin/ctr:/usr/local/bin/ctr \
  -v /run/k3s/containerd:/run/k3s/containerd \
  -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
  jenkins/jenkins:lts-jdk17

# Wait for Jenkins to initialize
sleep 30

# Fix Docker socket + containerd permissions
sudo chmod 666 /var/run/docker.sock || true
sudo chmod 666 /run/k3s/containerd/containerd.sock || true

# Add Jenkins user to Docker group (inside container)

sudo docker exec -u root jenkins bash -c "groupadd -f docker && usermod -aG docker jenkins"
sudo docker restart jenkins

# -------------------------------
# Run SonarQube (port 9000)
# -------------------------------

sudo docker volume create sonarqube_data
sudo docker volume create sonarqube_extensions
sudo docker volume create sonarqube_logs
docker run -d --name sonarqube --restart unless-stopped \
  -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  sonarqube:lts-community

# -------------------------------
# Optional Reboot
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  reboot
fi


