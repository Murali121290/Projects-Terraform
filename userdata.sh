#!/bin/bash
exec > /var/log/userdata.log 2>&1
set -xe

echo "[INFO] ======== Starting EC2 Bootstrap ========="

# --- Wait for apt locks ---
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   echo "Waiting for apt lock..."
   sleep 10
done

# -------------------------------
# System Update & Tools
# -------------------------------
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
    docker.io git curl wget unzip openjdk-17-jdk apt-transport-https \
    ca-certificates gnupg lsb-release software-properties-common fontconfig conntrack jq

# Enable Docker and add ubuntu user to group
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ubuntu
sudo chmod 666 /var/run/docker.sock

# -------------------------------
# Install K3s (Single Node)
# -------------------------------
curl -sfL https://get.k3s.io | sh -s - --disable traefik
sleep 30

# Configure kubeconfig for ubuntu
EC2_IP=$(hostname -I | awk '{print $1}')
mkdir -p /home/ubuntu/.kube
sudo sed "s/127.0.0.1/$EC2_IP/" /etc/rancher/k3s/k3s.yaml | sudo tee /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# -------------------------------
# Fix containerd socket permissions for Jenkins
# -------------------------------
sudo groupadd -f containerd
sudo chown root:containerd /run/k3s/containerd/containerd.sock
sudo chmod 660 /run/k3s/containerd/containerd.sock

# -------------------------------
# Ensure ctr wrapper exists (for Jenkins)
# -------------------------------
cat <<'EOF' | sudo tee /usr/local/bin/ctr
#!/bin/bash
exec /usr/local/bin/k3s ctr "$@"
EOF
sudo chmod +x /usr/local/bin/ctr

# -------------------------------
# Install kubectl (CLI tool for Jenkins)
# -------------------------------
sudo snap install kubectl --classic || true

# -------------------------------
# Get group IDs for proper container mapping
# -------------------------------
DOCKER_GID=$(getent group docker | cut -d: -f3)
CONTAINERD_GID=$(getent group containerd | cut -d: -f3)

# -------------------------------
# Run Jenkins container (with access to Docker & K3s)
# -------------------------------
if [ ! "$(sudo docker ps -q -f name=jenkins)" ]; then
  sudo docker run -d --name jenkins --restart unless-stopped \
    -p 8080:8080 -p 50000:50000 \
    -v jenkins_home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/bin/docker:/usr/bin/docker \
    -v /usr/local/bin/kubectl:/usr/local/bin/kubectl \
    -v /usr/local/bin/k3s:/usr/local/bin/k3s \
    -v /usr/local/bin/ctr:/usr/local/bin/ctr \
    -v /run/k3s/containerd/containerd.sock:/run/k3s/containerd/containerd.sock \
    -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
    --group-add $DOCKER_GID \
    --group-add $CONTAINERD_GID \
    jenkins/jenkins:lts-jdk17
fi

# -------------------------------
# Run SonarQube container
# -------------------------------
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
# Fix Jenkins permissions after boot
# -------------------------------
sleep 20
sudo docker exec -u root jenkins bash -c "usermod -aG docker jenkins && usermod -aG containerd jenkins || true"
sudo docker run --rm -v jenkins_home:/var/jenkins_home alpine sh -c "chown -R 1000:1000 /var/jenkins_home" || true
sudo docker restart jenkins

# -------------------------------
# Wait for SonarQube to become ready
# -------------------------------
echo "[INFO] Waiting for SonarQube..."
until curl -s http://localhost:9000/api/system/status | grep -q '"status":"UP"'; do
  sleep 10
  echo "Waiting..."
done
echo "[INFO] SonarQube is UP!"

# -------------------------------
# Print Jenkins admin password
# -------------------------------
echo "[INFO] Jenkins admin password:"
sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword || true

# -------------------------------
# Reboot if required
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "[INFO] System reboot required. Rebooting..."
  sudo reboot
fi

echo "[INFO] ======== Bootstrap Completed Successfully ========="
