#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# -------------------------------
# System Update
# -------------------------------
sudo apt-get update -y
sudo apt-get upgrade -y

# -------------------------------
# Install Dependencies
# -------------------------------
sudo apt-get install -y \
    docker.io git curl wget unzip openjdk-17-jdk apt-transport-https \
    ca-certificates gnupg lsb-release software-properties-common fontconfig conntrack

# Enable Docker
sudo systemctl enable docker
sudo systemctl start docker

# Add ubuntu user to docker group
sudo usermod -aG docker ubuntu

# -------------------------------
# Install kubectl
# -------------------------------
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# -------------------------------
# Install K3s (single-node)
# -------------------------------
curl -sfL https://get.k3s.io | sh -

# Wait until K3s is ready
sleep 30

# Configure kubeconfig for ubuntu
EC2_IP=$(hostname -I | awk '{print $1}')
mkdir -p /home/ubuntu/.kube
sudo sed "s/127.0.0.1/$EC2_IP/" /etc/rancher/k3s/k3s.yaml | sudo tee /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# -------------------------------
# Run Jenkins container
# -------------------------------
sudo docker run -d --name jenkins --restart unless-stopped \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/local/bin/docker:/usr/local/bin/docker \
  -v /usr/local/bin/kubectl:/usr/local/bin/kubectl \
  -v /usr/local/bin/k3s:/usr/local/bin/k3s \
  -v /run/k3s/containerd/containerd.sock:/run/k3s/containerd/containerd.sock \
  -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
  jenkins/jenkins:lts-jdk17

# -------------------------------
# Fix Docker permissions for Jenkins
# -------------------------------
sleep 20
sudo chmod 666 /var/run/docker.sock
sudo docker exec -u root jenkins bash -c "groupadd -f docker && usermod -aG docker jenkins"
sudo docker restart jenkins

# -------------------------------
# Run SonarQube
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

# -------------------------------
# Reboot if required
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  sudo reboot
fi
