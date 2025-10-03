#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# -------------------------------
# Add Kubernetes apt repo (fix for missing GPG key)
# -------------------------------
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

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
# Install Minikube + kubectl on host
# -------------------------------
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

sudo snap install kubectl --classic

# Start Minikube (Docker driver)
sudo -u ubuntu -i minikube start --driver=docker --force

# -------------------------------
# Get docker group ID for Jenkins mapping
# -------------------------------
DOCKER_GID=$(getent group docker | cut -d: -f3)

# -------------------------------
# Run Jenkins in Docker (with Docker + Minikube + kubectl access)
# -------------------------------
if [ ! "$(sudo docker ps -q -f name=jenkins)" ]; then
  sudo docker run -d --name jenkins --restart unless-stopped \
    -p 8080:8080 -p 50000:50000 \
    -v jenkins_home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/bin/docker:/usr/bin/docker \
    -v /usr/local/bin/kubectl:/usr/local/bin/kubectl \
    -v /usr/local/bin/minikube:/usr/local/bin/minikube \
    -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
    -v /home/ubuntu/.minikube:/var/jenkins_home/.minikube \
    --group-add $DOCKER_GID \
    jenkins/jenkins:lts-jdk17
fi

# -------------------------------
# Post-setup inside Jenkins container
# -------------------------------

# Install Git (no need for docker.io inside Jenkins)
sudo docker exec -u root jenkins bash -c "apt-get update && apt-get install -y git"

# Symlink kubectl and minikube to /usr/bin inside container for PATH access
sudo docker exec -u root jenkins bash -c "ln -sf /usr/local/bin/kubectl /usr/bin/kubectl"
sudo docker exec -u root jenkins bash -c "ln -sf /usr/local/bin/minikube /usr/bin/minikube"

# Verify Docker, kubectl, minikube are available inside Jenkins
sudo docker exec jenkins which docker
sudo docker exec jenkins docker --version
sudo docker exec jenkins which kubectl
sudo docker exec jenkins which minikube

# -------------------------------
# Install Jenkins plugins automatically
# -------------------------------
JENKINS_PLUGINS="git workflow-aggregator docker-plugin docker-workflow blueocean sonar github"

# Install plugins inside Jenkins
for plugin in $JENKINS_PLUGINS; do
  sudo docker exec -u root jenkins bash -c \
    "curl -L -o /var/jenkins_home/plugins/${plugin}.hpi https://updates.jenkins.io/latest/${plugin}.hpi"
done

# Set correct ownership
sudo docker exec -u root jenkins bash -c "chown -R jenkins:jenkins /var/jenkins_home/plugins"

# Restart Jenkins so plugins load
sudo docker restart jenkins

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


