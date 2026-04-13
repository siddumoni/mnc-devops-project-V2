#!/bin/bash
# Jenkins Master Bootstrap — see README for full description.
# Fresh install : formats EBS, installs Jenkins + SonarQube from scratch.
# Recreate      : mounts existing EBS, starts Jenkins + SonarQube. No reinstall.
# Progress log  : sudo tail -f /var/log/jenkins-setup.log

set -euo pipefail
exec > >(tee /var/log/jenkins-setup.log) 2>&1

echo "=== Jenkins Bootstrap Start: $(date) ==="

AWS_REGION="${aws_region}"
PROJECT_NAME="${project_name}"
CLUSTER_NAME="${cluster_name}"
SONARQUBE_PORT="${sonarqube_port}"
JENKINS_HOME="/var/lib/jenkins"
EBS_DEVICE="/dev/xvdf"
MOUNT_POINT="$JENKINS_HOME"

# -- [1] System packages
echo "=== [1] System packages ==="
dnf update -y -q
dnf install -y -q git wget unzip jq

# -- [2] Java 17
echo "=== [2] Java 17 ==="
if ! java -version 2>&1 | grep -q "17"; then
  dnf install -y -q java-17-amazon-corretto-headless
fi
java -version

# -- [3] Docker
echo "=== [3] Docker ==="
if ! command -v docker &>/dev/null; then
  dnf install -y -q docker
  systemctl enable docker
  systemctl start docker
fi
systemctl start docker 2>/dev/null || true

# -- [4] kubectl
echo "=== [4] kubectl ==="
if ! command -v kubectl &>/dev/null; then
  KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  mv kubectl /usr/local/bin/
fi
kubectl version --client

# -- [5] AWS CLI v2
echo "=== [5] AWS CLI ==="
if ! command -v aws &>/dev/null; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

# -- [6] Mount persistent EBS volume
echo "=== [6] EBS mount ==="
for i in $(seq 1 30); do
  if [ -e "$EBS_DEVICE" ]; then
    echo "EBS device $EBS_DEVICE is available."
    break
  fi
  echo "Waiting for EBS device... ($i/30)"
  sleep 5
done

if [ ! -e "$EBS_DEVICE" ]; then
  echo "ERROR: EBS device $EBS_DEVICE not found after 150s. Exiting."
  exit 1
fi

if ! blkid "$EBS_DEVICE" &>/dev/null; then
  echo "Formatting new EBS volume with XFS..."
  mkfs -t xfs "$EBS_DEVICE"
  FRESH_INSTALL=true
else
  echo "Existing EBS volume detected - skipping format."
  FRESH_INSTALL=false
fi

mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
  mount "$EBS_DEVICE" "$MOUNT_POINT"
fi
if ! grep -q "$EBS_DEVICE" /etc/fstab; then
  echo "$EBS_DEVICE $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
fi
echo "EBS volume mounted at $MOUNT_POINT"

# -- [7] Jenkins install or start
echo "=== [7] Jenkins ==="
MAVEN_VERSION="3.9.6"

if [ "$${FRESH_INSTALL}" = "true" ]; then
  echo "Fresh install - installing Jenkins..."
  wget -q -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
  rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
  dnf install -y -q jenkins

  mkdir -p "$JENKINS_HOME"/{.jenkins,.m2,.kube,.docker}
  mkdir -p /opt/sonarqube/{data,extensions,logs}
  chown -R jenkins:jenkins "$JENKINS_HOME"
  usermod -aG docker jenkins

  if [ ! -d "/opt/apache-maven-$${MAVEN_VERSION}" ]; then
    wget -q "https://archive.apache.org/dist/maven/maven-3/$${MAVEN_VERSION}/binaries/apache-maven-$${MAVEN_VERSION}-bin.tar.gz" -O /tmp/maven.tar.gz
    tar -xzf /tmp/maven.tar.gz -C /opt/
    rm /tmp/maven.tar.gz
  fi
  ln -sf /opt/apache-maven-$${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

  systemctl enable jenkins
  systemctl start jenkins

  echo "Waiting for Jenkins initial startup..."
  for i in $(seq 1 60); do
    if curl -sf http://localhost:8080/login >/dev/null 2>&1; then
      echo "Jenkins is up!"
      break
    fi
    sleep 10
  done

  INITIAL_PASSWORD=$(cat "$JENKINS_HOME/secrets/initialAdminPassword" 2>/dev/null || echo "not-ready")
  aws ssm put-parameter \
    --name "/$PROJECT_NAME/jenkins/initial-password" \
    --value "$INITIAL_PASSWORD" \
    --type "SecureString" \
    --overwrite \
    --region "$AWS_REGION" || true
  echo "Initial Jenkins password stored in SSM."

else
  echo "Existing Jenkins installation on EBS - starting without reinstall."

  # Jenkins service binary may not exist on a freshly launched EC2 (new OS, old EBS).
  # Install the package only — all data stays on the already-mounted EBS.
  if ! systemctl list-units --type=service | grep -q jenkins; then
    echo "Jenkins service not on this OS - installing package (data on EBS preserved)..."
    wget -q -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    dnf install -y -q jenkins
  fi

  if [ ! -f "/usr/local/bin/mvn" ]; then
    if [ ! -d "/opt/apache-maven-$${MAVEN_VERSION}" ]; then
      wget -q "https://archive.apache.org/dist/maven/maven-3/$${MAVEN_VERSION}/binaries/apache-maven-$${MAVEN_VERSION}-bin.tar.gz" -O /tmp/maven.tar.gz
      tar -xzf /tmp/maven.tar.gz -C /opt/
      rm /tmp/maven.tar.gz
    fi
    ln -sf /opt/apache-maven-$${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn
  fi

  usermod -aG docker jenkins 2>/dev/null || true
  # Fix ownership after remount — UID/GID may differ on a new EC2 instance
  chown -R jenkins:jenkins "$JENKINS_HOME"

  systemctl enable jenkins
  systemctl start jenkins
  echo "Jenkins started with existing data."

  # Update Jenkins URL to the new public IP so the UI loads without redirect loops
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  JENKINS_CONFIG="$JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml"
  if [ -f "$JENKINS_CONFIG" ]; then
    sed -i "s|<jenkinsUrl>.*</jenkinsUrl>|<jenkinsUrl>http://$${PUBLIC_IP}:8080/</jenkinsUrl>|" "$JENKINS_CONFIG"
    echo "Jenkins URL updated to: http://$${PUBLIC_IP}:8080/"
    systemctl restart jenkins
    sleep 30
  fi
fi

# -- [8] SonarQube (Docker, data persists on EBS)
echo "=== [8] SonarQube ==="
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -w vm.max_map_count=262144
mkdir -p /opt/sonarqube/{data,extensions,logs}
chown -R 1000:1000 /opt/sonarqube
docker stop sonarqube 2>/dev/null || true
docker rm   sonarqube 2>/dev/null || true
docker run -d \
  --name sonarqube \
  --restart always \
  -p "$${SONARQUBE_PORT}":9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -v /opt/sonarqube/data:/opt/sonarqube/data \
  -v /opt/sonarqube/extensions:/opt/sonarqube/extensions \
  -v /opt/sonarqube/logs:/opt/sonarqube/logs \
  sonarqube:community
echo "SonarQube starting on port $${SONARQUBE_PORT}..."

# -- [9] Configure kubectl for EKS
echo "=== [9] kubectl for EKS ==="
for i in $(seq 1 20); do
  CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query "cluster.status" \
    --output text 2>/dev/null || echo "NOT_FOUND")
  if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    echo "EKS cluster is ACTIVE."
    break
  fi
  echo "EKS cluster status: $CLUSTER_STATUS - waiting... ($i/20)"
  sleep 30
done
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --kubeconfig "$JENKINS_HOME/.kube/config" || true
chown -R jenkins:jenkins "$JENKINS_HOME/.kube" 2>/dev/null || true

# -- [10] Store public IP in SSM
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
aws ssm put-parameter \
  --name "/$PROJECT_NAME/jenkins/public-ip" \
  --value "$PUBLIC_IP" \
  --type "String" \
  --overwrite \
  --region "$AWS_REGION" || true

echo ""
echo "=== Bootstrap complete: $(date) ==="
echo "Jenkins  : http://$${PUBLIC_IP}:8080"
echo "SonarQube: http://$${PUBLIC_IP}:$${SONARQUBE_PORT}"
echo "Fresh install - SSM param: /$PROJECT_NAME/jenkins/initial-password"
echo "Recreate  - Jenkins and SonarQube loaded with existing data."
