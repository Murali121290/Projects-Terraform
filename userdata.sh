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
# Install K3s (single-node)
# -------------------------------
sudo curl -sfL https://get.k3s.io | sh -

# Wait until K3s is ready
sleep 30

# Configure kubeconfig for ubuntu
EC2_IP=$(hostname -I | awk '{print $1}')
mkdir -p /home/ubuntu/.kube
sudo sed "s/127.0.0.1/$EC2_IP/" /etc/rancher/k3s/k3s.yaml | sudo tee /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube

# -------------------------------
# Ensure ctr wrapper exists
# -------------------------------
cat <<'EOF' | sudo tee /usr/local/bin/ctr
#!/bin/bash
exec /usr/local/bin/k3s ctr "$@"
EOF
sudo chmod +x /usr/local/bin/ctr

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
  -v /usr/local/bin/ctr:/usr/local/bin/ctr \
  -v /run/k3s/containerd:/run/k3s/containerd \
  -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
  jenkins/jenkins:lts-jdk17

# -------------------------------
# Run SonarQube container
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
# Fix Docker & Jenkins permissions
# -------------------------------
sleep 20
sudo chmod 666 /var/run/docker.sock
sudo docker exec -u root jenkins bash -c "groupadd -f docker && usermod -aG docker jenkins || true"
sudo docker run --rm -v jenkins_home:/var/jenkins_home alpine sh -c "chown -R 1000:1000 /var/jenkins_home" || true
sudo docker restart jenkins


# -------------------------------
# Reboot if required
# -------------------------------
if [ -f /var/run/reboot-required ]; then
  echo "System reboot required. Rebooting..."
  sudo reboot
fi
