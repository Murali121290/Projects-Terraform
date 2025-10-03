              #!/bin/bash
              exec > /var/log/userdata.log 2>&1
              set -xe

              # Wait for apt locks
              while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
                echo "Waiting for apt lock..."
                sleep 5
              done

              export DEBIAN_FRONTEND=noninteractive

              # Add Kubernetes apt repo (for kubectl compatibility)
              mkdir -p /etc/apt/keyrings
              curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
              echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" > /etc/apt/sources.list.d/kubernetes.list || true

              apt-get update -y
              apt-get upgrade -y

              # Install packages
              apt-get install -y docker.io git curl wget unzip openjdk-17-jdk apt-transport-https ca-certificates gnupg lsb-release software-properties-common fontconfig conntrack

              # Start & enable docker
              systemctl enable docker
              systemctl start docker

              # Add ubuntu user to docker group
              usermod -aG docker ubuntu || true

              # Install kubectl (snap as fallback if apt fails)
              if ! command -v kubectl >/dev/null 2>&1; then
                snap install kubectl --classic || {
                  curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
                  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                  rm -f kubectl
                }
              fi

              # Install minikube
              if ! command -v minikube >/dev/null 2>&1; then
                curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
                install minikube-linux-amd64 /usr/local/bin/minikube
                rm -f minikube-linux-amd64
              fi

              # Ensure docker group id for mapping into Jenkins container
              DOCKER_GID=$(getent group docker | cut -d: -f3)
              if [ -z "$DOCKER_GID" ]; then
                DOCKER_GID=999
              fi

              # Make .kube and .minikube dirs for ubuntu user
              mkdir -p /home/ubuntu/.kube /home/ubuntu/.minikube
              chown -R ubuntu:ubuntu /home/ubuntu/.kube /home/ubuntu/.minikube

              # Start minikube as ubuntu user with Docker driver (best-effort)
              su - ubuntu -c "minikube start --driver=docker --memory=4096 --cpus=2" || echo "minikube start failed - continue"

              # Create Docker volumes for Jenkins and SonarQube
              docker volume create jenkins_home || true
              docker volume create sonarqube_data || true
              docker volume create sonarqube_extensions || true
              docker volume create sonarqube_logs || true

              # Run SonarQube container (if not running)
              if [ -z "$(docker ps -q -f name=sonarqube)" ]; then
                docker run -d --name sonarqube --restart unless-stopped \
                  -p 9000:9000 \
                  -v sonarqube_data:/opt/sonarqube/data \
                  -v sonarqube_extensions:/opt/sonarqube/extensions \
                  -v sonarqube_logs:/opt/sonarqube/logs \
                  sonarqube:lts-community || true
              fi

              # Run Jenkins container with access to docker, kubectl, minikube configs
              if [ -z "$(docker ps -q -f name=jenkins)" ]; then
                docker run -d --name jenkins --restart unless-stopped \
                  -p 8080:8080 -p 50000:50000 \
                  -v jenkins_home:/var/jenkins_home \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  -v /usr/bin/docker:/usr/bin/docker \
                  -v /usr/local/bin/kubectl:/usr/bin/kubectl \
                  -v /usr/local/bin/minikube:/usr/bin/minikube \
                  -v /home/ubuntu/.kube:/var/jenkins_home/.kube \
                  -v /home/ubuntu/.minikube:/var/jenkins_home/.minikube \
                  --group-add $DOCKER_GID \
                  jenkins/jenkins:lts-jdk17 || true
              fi

              # Install git & docker CLI inside Jenkins container as fallback
              docker exec -u root jenkins bash -c "apt-get update && apt-get install -y git docker.io || true"

              # Ensure symlinks inside container (if missing)
              docker exec -u root jenkins bash -c "ln -sf /usr/bin/kubectl /usr/local/bin/kubectl || true"
              docker exec -u root jenkins bash -c "ln -sf /usr/bin/minikube /usr/local/bin/minikube || true"

              # Output versions for debug
              docker exec jenkins which docker || true
              docker exec jenkins docker --version || true
              docker exec jenkins which kubectl || true
              docker exec jenkins which minikube || true

              # Ensure sysctl (for sonarqube if needed)
              sysctl --system || true

              echo "Bootstrap finished" >> /var/log/userdata.log
