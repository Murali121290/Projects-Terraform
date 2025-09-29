#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# Update system
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
# Run Jenkins in Docker (port 8080) with Docker access
# -------------------------------
if [ ! "$(sudo docker ps -q -f name=jenkins)" ]; then
  sudo docker run -d --name jenkins --restart unless-stopped \
    -p 8080:8080 -p 50000:50000 \
    -v jenkins_home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/bin/docker:/usr/bin/docker \
    jenkins/jenkins:lts-jdk17
fi

# -------------------------------
# Run SonarQube in Docker with volumes (port 9000)
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
# Install Minikube
# -------------------------------
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# -------------------------------
# Install kubectl (via snap, auto-updates)
# -------------------------------
sudo snap install kubectl --classic

# -------------------------------
# Start Minikube (Docker driver)
# -------------------------------
# Force Docker group immediately for ubuntu user
newgrp docker <<EONG
minikube start --driver=docker
EONG

# -------------------------------
# Reboot if required
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  sudo reboot
fi
