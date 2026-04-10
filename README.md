# MNC App — DevOps Lab

A production-grade 3-tier Java application built for hands-on DevOps learning.
Single lab environment with full CI/CD pipeline — Jenkins, SonarQube, ECR, EKS, RDS MySQL on AWS.

> **How to use this README:** Section 1 is pure theory — read it before interviews. Section 2 onwards is your actual lab setup guide. The lab gives you the real workflow experience at a fraction of the cost.

---

## Table of Contents

**Theory (Interview Prep)**
1. [How MNCs Run Production DevOps](#1-how-mncs-run-production-devops)
2. [Production vs Lab — Side by Side](#2-production-vs-lab--side-by-side)

**Lab Setup**

3. [Your Lab Architecture](#3-your-lab-architecture)
4. [Prerequisites — Install Tools](#4-prerequisites--install-tools)
5. [Repository Structure](#5-repository-structure)
6. [Step 1 — AWS Account Preparation](#step-1--aws-account-preparation)
7. [Step 2 — Clone and Configure the Repo](#step-2--clone-and-configure-the-repo)
8. [Step 3 — Bootstrap and Create Infrastructure](#step-3--bootstrap-and-create-infrastructure)
9. [Step 4 — Configure Jenkins (First Time Only)](#step-4--configure-jenkins-first-time-only)
10. [Step 5 — Run Your First Pipeline](#step-5--run-your-first-pipeline)
11. [Daily Workflow — Create, Learn, Destroy](#daily-workflow--create-learn-destroy)
12. [Troubleshooting](#troubleshooting)
13. [Estimated Cost](#estimated-cost)
14. [Quick Reference Commands](#quick-reference-commands)

---

# SECTION 1 — THEORY (INTERVIEW PREP)

---

## 1. How MNCs Run Production DevOps

### 1.1 The Three-Environment Model

Every MNC maintains at minimum three isolated environments. Each has its own VPC, EKS cluster, RDS database, and Terraform state file. They share only ECR (the image registry) — because the whole point is to build an image once and promote the same binary through environments without rebuilding.

```
GitHub → Jenkins → ECR (images) → EKS dev → EKS staging → EKS prod
                                      ↓            ↓            ↓
                                   RDS dev    RDS staging   RDS prod
```

**Why three environments and not one?**

Dev is where developers push code freely — it may be broken at any time. Staging is a production mirror where the QA team runs regression tests, performance tests, and UAT. No one pushes directly to staging — only Jenkins does, and only after dev is green. Prod is where real users are. A bug in prod means revenue loss and SLA breach. The three-environment gate means a defect has to survive dev, pass a human approval for staging, and then pass two human approvals before it reaches prod.

### 1.2 Branch Strategy and CI/CD Flow

MNCs use a branch-per-environment model enforced by the Jenkinsfile.

| Git branch | Deploys to | Trigger | Approval required |
|---|---|---|---|
| `feature/*` | nowhere | push | none — build + test only |
| `develop` | dev namespace | automatic on push | none |
| `release/*` | staging namespace | automatic on push | 1 approval (tech lead) |
| `main` | prod namespace | automatic on push | 2 approvals (tech lead + DevOps manager) |

The dual approval for prod is not optional in regulated industries. Banking (SOX), healthcare (HIPAA), and payment processing (PCI-DSS) all require segregation of duties — the person who writes the code cannot be the same person who approves its deployment to production. Jenkins enforces this by requiring approvals from different Jenkins role groups (`tech-leads` and `devops-managers`).

### 1.3 What the Jenkins Pipeline Actually Does

Every pipeline run in an MNC follows this exact sequence. Understanding each stage is essential for interview questions about CI/CD.

**Stage 1 — Checkout:** Jenkins pulls the code and prints the branch name, git commit SHA, and target environment. The SHA is the cornerstone of traceability — every Docker image is tagged with it so you can always answer "which commit is running in prod right now?"

**Stage 2 — Build and Unit Tests:** Maven compiles the Spring Boot application and runs all unit tests. Unit tests use H2 in-memory database — they do not connect to real MySQL. JaCoCo measures code coverage. If coverage drops below 70%, the pipeline fails here and nothing is deployed. This is the fastest feedback loop — a developer knows within 3 minutes whether their code compiles and tests pass.

**Stage 3 — SonarQube Analysis:** Maven sends compiled bytecode and the JaCoCo coverage report to SonarQube. SonarQube analyses the code for bugs, security vulnerabilities, code smells, and duplication. This takes 2-5 minutes.

**Stage 4 — Quality Gate:** The pipeline pauses and waits for SonarQube to post its verdict. If the Quality Gate fails (too many bugs, coverage too low, security hotspots), the pipeline aborts. Nothing gets built or deployed. This gate runs on every branch, every push.

**Stage 5 — Docker Build and Push to ECR:** Jenkins builds a multi-stage Docker image. Stage 1 of the Dockerfile is a Maven/Java build container that compiles the JAR. Stage 2 is a minimal JRE runtime image that contains only the JAR. The resulting image is ~200MB instead of ~600MB. Both frontend and backend images are tagged with the git SHA (e.g. `sha-a3f2c1d`) and pushed to ECR. The same images are promoted through environments — you never rebuild for staging or prod.

**Stage 6 — Deploy:** Jenkins updates kubeconfig to point at the target cluster, pulls the database password from AWS SSM Parameter Store (never from a file), injects it into a Kubernetes Secret, substitutes the real ECR URL and image tag into copies of the deployment YAML files, and runs kubectl apply. Kubernetes then pulls the images from ECR and starts pods. kubectl rollout status blocks until all pods are healthy or the timeout is reached.

**Stage 7 — Smoke Tests:** Jenkins curls the ALB address and checks that `/actuator/health` returns HTTP 200 and `/api/products` returns HTTP 200. If either check fails, the pipeline automatically runs kubectl rollout undo to revert to the previous deployment. The pipeline marks itself as failed.

### 1.4 Infrastructure Design Decisions MNCs Make

**Why EKS and not EC2 directly?** EKS gives you self-healing (if a pod crashes, Kubernetes restarts it), horizontal scaling via HPA, rolling deployments with zero downtime, and a standardised way to manage 10 or 1000 services with the same tooling.

**Why ECR and not DockerHub?** ECR is inside your AWS account boundary. Images never leave your VPC for authentication. ECR scan-on-push checks images for CVEs automatically. In a banking environment you cannot pull from public DockerHub — firewall rules block it.

**Why SSM Parameter Store for secrets and not Kubernetes Secrets directly?** Kubernetes Secrets are base64-encoded, not encrypted, in etcd. Anyone with cluster-admin can read them. SSM SecureString values are encrypted with KMS. Jenkins reads them at deploy time using its EC2 IAM role — no static credentials anywhere.

**Why Flyway for database schema?** Without a migration tool, schema changes require manual SQL runs before each deployment. Flyway tracks which SQL files have been applied in a `flyway_schema_history` table. On app startup, it automatically applies any new migration files in order. This means schema changes are version-controlled alongside code and applied atomically with the deployment.

**Why multi-stage Docker builds?** The build stage needs Maven, JDK, and all source files. The runtime stage needs only the compiled JAR and a minimal JRE. If you ship the build stage, you ship your source code, build tools, and test dependencies to production — all of which expand the attack surface and image size. Multi-stage builds produce a minimal, hardened runtime image.

### 1.5 Production EKS Configuration (What MNCs Actually Use)

In production, EKS is configured very differently from a lab:

**Node groups:** Production uses ON_DEMAND instances (never SPOT — SPOT nodes can be terminated with 2 minutes notice, which causes pod evictions and service disruption). There are often multiple node groups — one for application workloads, one for monitoring, one for batch jobs — each with different instance types and taints.

**Node placement:** Production EKS nodes are in private subnets. They have no public IP addresses. All outbound internet traffic goes through NAT Gateways. Inbound traffic comes only from ALBs in public subnets. This means a compromised pod cannot directly receive inbound connections from the internet.

**Pod anti-affinity:** Production deployments use `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity rules. This forces Kubernetes to spread replicas across different nodes. If a node fails, at most one replica of each deployment is lost. In the lab we use `preferredDuring...` because we only have one node.

**HPA (Horizontal Pod Autoscaler):** Production deployments have HPA configured. If average CPU across all backend pods exceeds 70%, Kubernetes automatically adds more replicas up to a maximum. When traffic drops, it scales back down. In the lab we do not use HPA because we have a single node with limited resources.

**PDB (PodDisruptionBudget):** Production deployments have a PDB that says "at least 2 replicas must always be available." When a node is drained for maintenance (cluster upgrades, Cluster Autoscaler scale-down), Kubernetes respects this budget — it will not evict a pod if doing so would violate the PDB.

**Multi-AZ RDS:** Production RDS runs with `multi_az = true`. AWS maintains a synchronous standby replica in a different Availability Zone. If the primary fails, AWS automatically fails over to the standby in under 2 minutes. In the lab we use single-AZ to save cost.

---

## 2. Production vs Lab — Side by Side

| Aspect | MNC Production | Your Lab |
|---|---|---|
| Environments | 3 (dev + staging + prod) | 1 (dev only) |
| VPCs | 3 separate VPCs | 1 VPC |
| EKS clusters | 1 per environment | 1 shared |
| Node type | ON_DEMAND | SPOT |
| Node subnet | Private (behind NAT) | Public (no NAT) |
| Nodes per env | 3-10+ | 1-2 (auto-scaled) |
| Node instance | t3.large to m5.xlarge | t3.small |
| RDS | Multi-AZ | Single-AZ |
| RDS instance | db.r6g.large or larger | db.t3.micro |
| Replicas | 3 per service (prod) | 1 |
| HPA | Yes | No |
| PDB | Yes | No |
| Anti-affinity | Required | Preferred |
| Jenkins | Private subnet | Public subnet |
| HTTPS | ACM + HTTPS everywhere | HTTP only |
| Approval gates | 2 for prod | None |
| Branch strategy | feature/develop/release/main | develop only |
| Monthly cost | ₹50,000–₹2,00,000+ | ₹600-900 (2hr/day) |

**What you get the same experience on:**
- Full CI/CD pipeline (build → test → sonar → quality gate → push → deploy → smoke test)
- Terraform infrastructure as code with S3 remote state
- EKS with AWS Load Balancer Controller and Cluster Autoscaler
- ECR image registry with lifecycle policies
- Flyway database migrations
- Kubernetes Secrets from SSM Parameter Store
- Rolling deployments with automatic rollback on smoke test failure
- Multi-stage Docker builds
- SonarQube quality gates

---

# SECTION 2 — LAB SETUP

---

## 3. Your Lab Architecture

```
Internet
   │
   ▼
Jenkins ALB (public subnet) ──────────────────► Jenkins EC2 (public subnet, t3.large)
                                                  │  port 8080 — Jenkins UI
                                                  │  port 9000 — SonarQube (Docker)
                                                  │  /dev/xvdf  — 30GB EBS (PERSISTENT)
                                                  │              Jenkins home + SonarQube data

App ALB (public subnet, created by ALB Controller)
   │
   ├── /api/*      → backend pod  (EKS node, t3.small SPOT)
   └── /*          → frontend pod (EKS node, t3.small SPOT)
                            │
                            ▼
                    RDS MySQL (private subnet, db.t3.micro)

ECR: mnc-app/backend   ─────────► backend pod pulls image
ECR: mnc-app/frontend  ─────────► frontend pod pulls image

S3: terraform state
DynamoDB: state lock
SSM: /mnc-app/dev/db/password  (injected into K8s Secret at deploy time)
```

**Key design choice — no NAT Gateway:**
EKS nodes and Jenkins EC2 are in public subnets with direct internet access. Security groups block all unwanted inbound traffic. This saves ~₹5,300/month. In production, all of these would be in private subnets behind NAT Gateways.

**Key design choice — EBS persistence:**
The Jenkins EBS volume (`/dev/xvdf`) is never deleted during destroy/recreate. All your Jenkins plugins, credentials, job configurations, and SonarQube project data survive every session. The script only recreates the EC2 instance — the new instance mounts the same EBS and finds everything already configured.

---

## 4. Prerequisites — Install Tools

Open **PowerShell as Administrator** (right-click Start → Terminal Admin).

```powershell
# Allow PowerShell scripts (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Install all tools via winget
winget install Amazon.AWSCLI
winget install Hashicorp.Terraform
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Git.Git
```

Close and reopen PowerShell after each install. Verify all tools:

```powershell
@("aws","terraform","kubectl","helm","git") | ForEach-Object {
    $v = & $_ --version 2>&1 | Select-Object -First 1
    Write-Host "OK $_: $v" -ForegroundColor Green
}
```

Fix Git line endings (prevents CRLF warnings):

```powershell
git config --global core.autocrlf false
git config --global core.eol lf
```

---

## 5. Repository Structure

```
mnc-devops-project\
│
├── infra.ps1                          ← YOUR MAIN SCRIPT (create/destroy/recreate/status)
│
├── infra\
│   ├── main.tf                        Root module — wires all sub-modules
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules\
│   │   ├── vpc\                       VPC, public subnets (EKS+Jenkins), private subnets (RDS)
│   │   ├── ec2-jenkins\               Jenkins EC2, persistent EBS, ALB, IAM role
│   │   ├── eks\                       EKS cluster, SPOT node group, aws-auth, add-ons, IRSA roles
│   │   ├── ecr\                       ECR repos with lifecycle policies (never destroyed)
│   │   └── rds\                       MySQL RDS in private subnet
│   └── environments\
│       └── dev\
│           ├── main.tf                Has S3 backend block + calls root module
│           ├── variables.tf
│           └── terraform.tfvars       Your lab values (patched by infra.ps1 on first run)
│
├── k8s\
│   └── dev\
│       ├── namespace.yaml
│       ├── configmap.yaml             DB_HOST patched by infra.ps1 after terraform apply
│       ├── secret.yaml                Placeholder — Jenkins injects real DB_PASSWORD
│       ├── backend-deployment.yaml    Has ECR_REGISTRY_PLACEHOLDER / IMAGE_TAG_PLACEHOLDER
│       ├── frontend-deployment.yaml   Same placeholders — Jenkins uses sed to substitute
│       ├── backend-service.yaml
│       ├── frontend-service.yaml
│       └── ingress.yaml               ALB Controller creates AWS ALB from this
│
├── app\
│   ├── backend\                       Spring Boot (Java 17, Maven, JPA, Flyway, Actuator)
│   │   ├── Dockerfile                 Multi-stage: Maven builder → slim JRE runtime
│   │   ├── pom.xml
│   │   └── src\
│   │       ├── main\java\com\mnc\app\
│   │       │   ├── MncApplication.java
│   │       │   ├── controller\ProductController.java
│   │       │   ├── service\ProductService.java
│   │       │   ├── repository\ProductRepository.java
│   │       │   └── model\Product.java
│   │       ├── main\resources\
│   │       │   ├── application.properties
│   │       │   ├── application-test.properties (H2 for unit tests)
│   │       │   └── db\migration\V1__init_schema.sql (Flyway — runs on startup)
│   │       └── test\java\com\mnc\app\ProductServiceTest.java
│   ├── frontend\                      React 18 + Nginx
│   │   ├── Dockerfile                 Multi-stage: Node builder → Nginx runtime (~25MB)
│   │   ├── nginx.conf                 SPA routing, gzip, /health endpoint
│   │   ├── package.json
│   │   └── src\ (App.jsx, index.js, index.css)
│   └── database\migration\            Reference copy of Flyway SQL
│
├── jenkins\
│   └── Jenkinsfile                    CI/CD pipeline: build→test→sonar→gate→push→deploy→smoke
│
└── scripts\                           Bash equivalents for Linux teammates
```

> **About deployment YAML placeholders:** `backend-deployment.yaml` and `frontend-deployment.yaml` contain the literal strings `ECR_REGISTRY_PLACEHOLDER` and `IMAGE_TAG_PLACEHOLDER`. Never run `kubectl apply -f k8s/dev/` directly — that would try to pull an image literally named `ECR_REGISTRY_PLACEHOLDER/mnc-app/backend:IMAGE_TAG_PLACEHOLDER`. Always use `kubectl apply` on the individual non-deployment files, and let the Jenkins pipeline handle the deployment files.

---

## Step 1 — AWS Account Preparation

### 1.1 Create IAM user for Terraform

1. AWS Console → IAM → Users → Create user
2. Username: `terraform-admin`
3. Permissions: Attach directly → `AdministratorAccess`
4. Security credentials tab → Access keys → Command Line Interface
5. Download the CSV — copy both keys

### 1.2 Configure AWS CLI

```powershell
aws configure
# AWS Access Key ID:     PASTE_KEY_ID
# AWS Secret Access Key: PASTE_SECRET_KEY
# Default region:        ap-south-1
# Default output:        json
```

Verify:

```powershell
aws sts get-caller-identity
# Should show your account ID and arn:aws:iam::.../terraform-admin
```

---

## Step 2 — Clone and Configure the Repo

```powershell
# Create project folder and clone
New-Item -ItemType Directory -Path "C:\Users\$env:USERNAME\DevOps\Projects" -Force | Out-Null
Set-Location "C:\Users\$env:USERNAME\DevOps\Projects"
git clone https://github.com/YOUR_USERNAME/mnc-devops-project.git
Set-Location mnc-devops-project
```

> **Note:** The `infra.ps1 create` script automatically patches `terraform.tfvars` and `main.tf` with your real AWS account ID and latest AMI ID on first run. You do not need to edit these files manually.

---

## Step 3 — Bootstrap and Create Infrastructure

This single command handles everything — bootstrap, Terraform, EKS, Helm, Kubernetes:

```powershell
.\infra.ps1 create
```

**What happens (in order):**

1. Detects your AWS account ID automatically
2. Creates S3 state bucket, DynamoDB lock table, EC2 key pair (if not already existing)
3. Patches `terraform.tfvars` and `main.tf` with real values
4. Checks for a preserved Jenkins EBS volume from a previous session — reattaches it if found
5. **Pass 1** — `terraform apply` with `-target` flags: creates VPC, Jenkins EC2, ECR, EKS cluster and node group, RDS, security groups, SSM parameters
6. Waits for EKS cluster to be `ACTIVE`
7. Waits for all EKS nodes to be `Ready`
8. Waits for CoreDNS pods to be `Running` (this must complete before app pods can do DNS lookups)
9. **Pass 2** — full `terraform apply`: creates the `dev` Kubernetes namespace
10. Installs AWS Load Balancer Controller via Helm
11. Installs Cluster Autoscaler via Helm
12. Patches `k8s/dev/configmap.yaml` with the real RDS endpoint from Terraform output
13. Applies non-deployment Kubernetes manifests (namespace, configmap, secret skeleton, services, ingress)
14. Waits for the App ALB to be provisioned by the ALB Controller
15. Waits for Jenkins to respond on port 8080
16. Prints all URLs and next steps

**Expected total time:** 25-35 minutes on first run. On recreate: 20-25 minutes.

> **Why two Terraform passes?** The Kubernetes Terraform provider needs to connect to the EKS API server to create the `kubernetes_namespace` resource. On the very first apply, the cluster does not exist yet. Pass 1 creates all AWS resources (including the cluster). Pass 2 runs after the cluster is healthy and creates the namespace. This is a known Terraform pattern for EKS.

---

## Step 4 — Configure Jenkins (First Time Only)

After `infra.ps1 create` completes, you will see Jenkins URL printed. Open it in Chrome.

> On **recreate** (not first time): Jenkins loads all your previous configuration from EBS — skip to Step 5.

### 4.1 Unlock Jenkins

Run this to get the initial password:

```powershell
aws ssm get-parameter --name "/mnc-app/jenkins/initial-password" --with-decryption --query "Parameter.Value" --output text --region ap-south-1
```

Paste it into the Jenkins unlock screen.

### 4.2 Install Plugins

Customize Jenkins → **Install suggested plugins** (~5 minutes).

After restart, Manage Jenkins → Plugins → Available plugins — install these:

| Plugin | Purpose |
|---|---|
| `Pipeline` | Jenkinsfile support |
| `Docker Pipeline` | docker.build / docker.push steps |
| `SonarQube Scanner` | withSonarQubeEnv + waitForQualityGate |
| `GitHub` | Webhook triggers |
| `Timestamper` | Timestamps on all log lines |
| `AnsiColor` | Coloured console output |
| `JaCoCo` | Code coverage reports |

After installing → Restart Jenkins.

### 4.3 Create GitHub Personal Access Token

1. `https://github.com/settings/tokens` → Generate new token (classic)
2. Name: `jenkins-mnc-app`
3. Scopes: `repo` (all sub-items) + `admin:repo_hook`
4. Generate and copy immediately

### 4.4 Add Credentials in Jenkins

Manage Jenkins → Credentials → System → Global credentials → Add Credentials

**GitHub:**

| Field | Value |
|---|---|
| Kind | Username with password |
| Username | your GitHub username |
| Password | GitHub token from 4.3 |
| ID | `github-credentials` |

**SonarQube token** (add after 4.5):

| Field | Value |
|---|---|
| Kind | Secret text |
| Secret | token from SonarQube |
| ID | `sonarqube-token` |

### 4.5 Configure SonarQube

SonarQube runs on port 9000 on the same Jenkins EC2. Open `http://<JENKINS_IP>:9000` in your browser.

Login: `admin` / `admin` → change password.

Generate analysis token:

1. Top-right → admin → My Account → Security tab
2. Generate Tokens → Name: `jenkins-token`, Type: Global Analysis Token
3. Copy token → add to Jenkins credentials as `sonarqube-token` (4.4 above)

### 4.6 Configure SonarQube Server in Jenkins

Manage Jenkins → System → SonarQube servers → Add SonarQube:

| Field | Value |
|---|---|
| Name | `SonarQube-Server` ← must match exactly (Jenkinsfile uses this string) |
| Server URL | `http://localhost:9000` |
| Server auth token | `sonarqube-token` |

Save.

### 4.7 Configure Java and Maven Tools

Manage Jenkins → Tools:

**JDK → Add JDK:**
- Name: `Java-17` ← exact (Jenkinsfile: `jdk 'Java-17'`)
- Install automatically ✓, Version: Java 17

**Maven → Add Maven:**
- Name: `Maven-3.9` ← exact (Jenkinsfile: `maven 'Maven-3.9'`)
- Install automatically ✓, Version: 3.9.6

Save.

### 4.8 Create Multibranch Pipeline Job

1. Jenkins home → New Item
2. Name: `mnc-app-pipeline`, Type: Multibranch Pipeline → OK
3. Branch Sources → Add source → GitHub
   - Credentials: `github-credentials`
   - Repository URL: `https://github.com/YOUR_USERNAME/mnc-devops-project`
4. Build Configuration → Script Path: `jenkins/Jenkinsfile`
5. Scan Triggers → Periodically if not otherwise run → 1 minute
6. Save

### 4.9 Add GitHub Webhook

In your GitHub repo: Settings → Webhooks → Add webhook

| Field | Value |
|---|---|
| Payload URL | `http://<JENKINS_IP>:8080/github-webhook/` |
| Content type | `application/json` |
| Events | Just the push event |

---

## Step 5 — Run Your First Pipeline

> **Pods only come up after this step.** Up to this point ECR has no images and no pods are running. The pipeline builds the Docker images and deploys them.

```powershell
Set-Location "C:\Users\$env:USERNAME\DevOps\Projects\mnc-devops-project"
git checkout develop
Add-Content -Path "README.md" -Value "`n<!-- trigger: first pipeline run -->"
git add .
git commit -m "trigger: first dev pipeline run"
git push origin develop
```

Watch the pipeline in Jenkins → mnc-app-pipeline → develop.

**Pipeline stages in order:**

```
Stage 1 — Checkout            : prints branch, commit SHA, environment
Stage 2 — Build & Unit Tests  : mvn clean install with H2 (no real MySQL)
                                 JaCoCo coverage >= 70% enforced
Stage 3 — SonarQube Analysis  : sends code + coverage to SonarQube
Stage 4 — Quality Gate        : waits for SonarQube verdict (blocks if fail)
Stage 5 — Docker Build & Push : builds backend + frontend, tags sha-xxxxxxx, pushes to ECR
Stage 6 — Deploy → DEV        : kubectl apply, waits for rollout
Stage 7 — Smoke Tests         : curls /actuator/health + /api/products → auto-rollback on fail
```

First run: ~10 minutes (Maven downloads dependencies). Subsequent runs: ~4-5 minutes.

After the pipeline succeeds:

```powershell
# Get the app ALB URL
kubectl get ingress app-ingress -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Test the API
$ALB = kubectl get ingress app-ingress -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
(Invoke-WebRequest -Uri "http://$ALB/api/products" -UseBasicParsing).Content
```

---

## Daily Workflow — Create, Learn, Destroy

### Start of session (~20-25 min)

```powershell
.\infra.ps1 recreate
```

Jenkins loads from EBS — **all your plugins, credentials, and jobs are already there**. No reconfiguration. Push a commit to trigger the pipeline and you are coding.

### End of session (~10 min)

```powershell
.\infra.ps1 destroy
```

Destroys EKS, RDS, Jenkins EC2, VPC. Preserves Jenkins EBS, ECR, S3, DynamoDB, key pair.

### Check what is running

```powershell
.\infra.ps1 status
```

Shows cluster status, pod status, Jenkins EC2 status, EBS status, ECR image counts, and cost estimate.

---

## Troubleshooting

### "Pods stuck in Pending"

```powershell
kubectl describe pod <pod-name> -n dev
# Read the Events: section
```

| Events message | Fix |
|---|---|
| `Insufficient cpu` | Cluster Autoscaler hasn't scaled up yet — wait 2 min |
| `0/1 nodes are available` | Node not Ready yet — `kubectl get nodes -w` |
| `did not match node selector` | Node count issue — check Cluster Autoscaler logs |

### "ImagePullBackOff"

```powershell
aws ecr list-images --repository-name mnc-app/backend --region ap-south-1
```

If empty: first Jenkins pipeline hasn't run yet. Trigger Step 5.

### "Pods crash — SchemaManagementException"

Flyway migration failed. Check:

```powershell
kubectl logs <pod-name> -n dev | Select-String -Pattern "flyway|ERROR"
```

Common cause: `DB_HOST` in ConfigMap is still `DB_HOST_PLACEHOLDER`. Check that `infra.ps1 create` ran `Update-ConfigMap` successfully. Fix manually:

```powershell
$RDS = terraform -chdir="infra\environments\dev" output -raw db_host
(Get-Content "k8s\dev\configmap.yaml") -replace "DB_HOST_PLACEHOLDER", $RDS | Set-Content "k8s\dev\configmap.yaml"
kubectl apply -f k8s\dev\configmap.yaml
kubectl rollout restart deployment/backend -n dev
```

### "ALB stuck at pending"

```powershell
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=30
```

Usually means ALB Controller is not installed. Re-run:

```powershell
.\infra.ps1 create
# create is idempotent — safe to re-run, skips already-done steps
```

### "terraform apply fails — EBS volume already exists"

This happens when the EBS was removed from state but not imported back. Fix:

```powershell
$EBS_ID = Get-Content ".jenkins-ebs-volume-id"
Push-Location "infra\environments\dev"
terraform import -var-file="terraform.tfvars" -var="db_password=LabPass123!" "module.dev.module.jenkins.aws_ebs_volume.jenkins_home" $EBS_ID
Pop-Location
```

### "Jenkins URL slow / old IP"

After recreate, Jenkins may remember the old public IP. The userdata script fixes this automatically. If you see slow redirects, wait 30 seconds after Jenkins starts — the restart picks up the new URL.

### "terraform init fails — backend configuration changed"

```powershell
Remove-Item -Recurse -Force "infra\environments\dev\.terraform"
Remove-Item -Force "infra\environments\dev\.terraform.lock.hcl" -ErrorAction SilentlyContinue
Push-Location "infra\environments\dev"
terraform init -reconfigure
Pop-Location
```

---

## Estimated Cost

Running 2 hours per day:

| Resource | Cost when running | Cost when destroyed |
|---|---|---|
| EKS control plane | ~₹8.50/hr | ₹0 |
| Jenkins t3.large | ~₹6.50/hr | ₹0 |
| EKS t3.small SPOT | ~₹0.75/hr | ₹0 |
| RDS db.t3.micro | ~₹1.60/hr | ₹0 |
| **Total running** | **~₹17.35/hr** | |
| Jenkins EBS 30GB | ~₹0.14/hr | ~₹0.14/hr (always) |

**2 hours/day = ~₹35/day = ~₹1,050/month**
**Vs leaving it running 24/7 = ~₹12,000/month**

Always run `.\infra.ps1 destroy` at the end of each session.

---

## Quick Reference Commands

```powershell
# ── infra.ps1 ─────────────────────────────────────────────────────────────
.\infra.ps1 create     # Full provision (first time or after destroy)
.\infra.ps1 destroy    # Tear down (preserves EBS + ECR)
.\infra.ps1 recreate   # destroy + create in one shot
.\infra.ps1 status     # Show what is running

# ── kubectl ────────────────────────────────────────────────────────────────
kubectl get pods -n dev
kubectl get pods -n dev -w
kubectl logs -f deployment/backend -n dev
kubectl describe pod <name> -n dev
kubectl exec -it deployment/backend -n dev -- sh
kubectl rollout undo deployment/backend -n dev
kubectl rollout status deployment/backend -n dev
kubectl top pods -n dev
kubectl top nodes
kubectl describe configmap aws-auth -n kube-system

# ── Reconnect kubectl after opening a new PowerShell ──────────────────────
aws eks update-kubeconfig --region ap-south-1 --name mnc-app-dev-cluster

# ── Get Jenkins initial password ───────────────────────────────────────────
aws ssm get-parameter --name "/mnc-app/jenkins/initial-password" --with-decryption --query "Parameter.Value" --output text --region ap-south-1

# ── Check ECR images ───────────────────────────────────────────────────────
aws ecr list-images --repository-name mnc-app/backend  --region ap-south-1
aws ecr list-images --repository-name mnc-app/frontend --region ap-south-1

# ── Manual rollback ────────────────────────────────────────────────────────
kubectl rollout history deployment/backend -n dev
kubectl rollout undo deployment/backend -n dev
kubectl rollout status deployment/backend -n dev
```
