#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# -------------------------------
# Wait for apt locks
# -------------------------------
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
    software-properties-common fontconfig conntrack jq

# -------------------------------
# Docker Setup & Performance Tuning
# -------------------------------

sudo systemctl enable docker
sudo systemctl restart docker
sudo usermod -aG docker ubuntu

# -------------------------------
# Install kubectl
# -------------------------------

# -------------------------------
# Install K3s (Single-node cluster)
# -------------------------------
sudo curl -sfL https://get.k3s.io | sh -
sleep 30

# Configure kubeconfig for Ubuntu user
EC2_IP=$(hostname -I | awk '{print $1}')
sudo mkdir -p /home/ubuntu/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
sudo sed -i "s/127.0.0.1/$EC2_IP/" /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube
sudo chmod 600 /home/ubuntu/.kube/config

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
  -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
  jenkins/jenkins:lts-jdk17

# Wait for Jenkins to initialize
echo "Waiting for Jenkins to start..."
until curl -s http://localhost:8080/login > /dev/null; do
  sleep 10
  echo "Still waiting for Jenkins..."
done
echo "Jenkins is up!"

# Fix Docker & containerd permissions
sudo chmod 666 /var/run/docker.sock || true
sudo chmod 666 /run/k3s/containerd/containerd.sock || true

# Add Jenkins user to Docker group
sudo docker exec -u root jenkins bash -c "groupadd -f docker && usermod -aG docker jenkins"
sudo docker restart jenkins

# -------------------------------
# Run SonarQube (port 9000)
# -------------------------------
sudo docker volume create sonarqube_data
sudo docker volume create sonarqube_extensions
sudo docker volume create sonarqube_logs

sudo docker run -d --name sonarqube --restart unless-stopped \
  -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  -v sonarqube_logs:/opt/sonarqube/logs \
  sonarqube:lts-community

# Wait for SonarQube startup
echo "Waiting for SonarQube to start..."
until curl -s http://localhost:9000 > /dev/null; do
  sleep 15
  echo "Still waiting for SonarQube..."
done
echo "SonarQube is up!"

# -------------------------------
# (Optional) Configure Jenkins SonarQube Integration
# -------------------------------
SONARQUBE_URL="http://sonarqube:9000"
JENKINS_URL="http://localhost:8080"
# Note: SonarQube token setup and Jenkins plugin install can be automated later using Jenkins CLI or Groovy scripts.

# -------------------------------
# Verify Everything
# -------------------------------
echo "===== Installed Versions ====="
docker --version
kubectl version --client
k3s --version
java -version || true
echo "================================"

# -------------------------------
# Optional Reboot
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  reboot
fi

