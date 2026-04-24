# ─────────────────────────────────────────────────────────────────────────────
# infra.ps1 — MNC App Lab Infrastructure Control Script
#
# Usage:
#   .\infra.ps1 create     # First time OR after destroy
#   .\infra.ps1 destroy    # Tear down expensive resources (preserves Jenkins EBS + ECR)
#   .\infra.ps1 recreate   # destroy + create in one shot
#   .\infra.ps1 status     # Show what is currently running
#
# What is PRESERVED across destroy/recreate:
#   ✅ Jenkins EBS volume  (your plugins, credentials, jobs, SonarQube data)
#   ✅ ECR repositories    (your built Docker images)
#   ✅ S3 state bucket     (Terraform state)
#   ✅ DynamoDB lock table
#   ✅ EC2 key pair
#
# What is DESTROYED and recreated:
#   🔄 EKS cluster + node group
#   🔄 RDS MySQL instance
#   🔄 VPC + subnets
#   🔄 Jenkins EC2 (NEW EC2, SAME EBS — all config preserved)
#   🔄 ALBs, security groups, IAM roles
# ─────────────────────────────────────────────────────────────────────────────

param([Parameter(Mandatory=$true)][ValidateSet("create","destroy","recreate","status")][string]$Action)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ─────────────────────────────────────────────────────────────
$AWS_REGION      = "ap-south-1"
$PROJECT_NAME    = "mnc-app"
$ENVIRONMENT     = "dev"
$CLUSTER_NAME    = "$PROJECT_NAME-$ENVIRONMENT-cluster"
$KEY_PAIR_NAME   = "$PROJECT_NAME-keypair"
$LOCK_TABLE      = "terraform-state-lock"
$DB_PASSWORD     = "LabPass123!"   # hardcoded for lab convenience
$ENV_DIR         = "infra\environments\dev"
$K8S_DIR         = "k8s\dev"

# ── Colours ───────────────────────────────────────────────────────────────
function Write-Step   { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK     { param($msg) Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Fail   { param($msg) Write-Host "  ❌ $msg" -ForegroundColor Red }
function Write-Info   { param($msg) Write-Host "  ℹ️  $msg" -ForegroundColor Gray }

# ── Helper: wait with polling ─────────────────────────────────────────────
function Wait-Until {
    param([scriptblock]$Condition, [string]$Message, [int]$MaxSeconds = 600, [int]$IntervalSeconds = 15)
    $elapsed = 0
    while (-not (& $Condition)) {
        if ($elapsed -ge $MaxSeconds) { throw "Timeout waiting for: $Message" }
        Write-Info "Waiting for $Message... ($elapsed/$MaxSeconds s)"
        Start-Sleep $IntervalSeconds
        $elapsed += $IntervalSeconds
    }
    Write-OK $Message
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP — runs automatically on first create
# Creates S3 bucket, DynamoDB, key pair, patches tfvars
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Bootstrap {
    Write-Step "Bootstrap — one-time setup"

    # Get account ID
    $script:ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
    Write-OK "Account ID: $($script:ACCOUNT_ID)"

    # FIX: STATE_BUCKET must match the "v2" prefix used in the backend block
    # placeholder inside infra/environments/dev/main.tf
    $STATE_BUCKET = "$PROJECT_NAME-v2-terraform-state-$($script:ACCOUNT_ID)"

    # ── S3 state bucket ───────────────────────────────────────────────────
    Write-Info "Checking S3 state bucket..."
    $bucketCheck = aws s3api head-bucket --bucket $STATE_BUCKET 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Creating S3 bucket: $STATE_BUCKET"
        aws s3api create-bucket --bucket $STATE_BUCKET --region $AWS_REGION `
            --create-bucket-configuration LocationConstraint=$AWS_REGION | Out-Null
        aws s3api put-bucket-versioning --bucket $STATE_BUCKET `
            --versioning-configuration Status=Enabled | Out-Null
        $enc = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
        aws s3api put-bucket-encryption --bucket $STATE_BUCKET `
            --server-side-encryption-configuration $enc | Out-Null
        aws s3api put-public-access-block --bucket $STATE_BUCKET `
            --public-access-block-configuration `
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null
        Write-OK "S3 bucket created: $STATE_BUCKET"
    } else {
        Write-OK "S3 bucket already exists"
    }

    # ── DynamoDB ──────────────────────────────────────────────────────────
    Write-Info "Checking DynamoDB lock table..."
    $tableCheck = aws dynamodb describe-table --table-name $LOCK_TABLE --region $AWS_REGION 2>&1
    if ($LASTEXITCODE -ne 0) {
        aws dynamodb create-table --table-name $LOCK_TABLE `
            --attribute-definitions AttributeName=LockID,AttributeType=S `
            --key-schema AttributeName=LockID,KeyType=HASH `
            --billing-mode PAY_PER_REQUEST --region $AWS_REGION | Out-Null
        Write-OK "DynamoDB table created"
    } else {
        Write-OK "DynamoDB table already exists"
    }

    # ── EC2 Key Pair ──────────────────────────────────────────────────────
    Write-Info "Checking EC2 key pair..."
    $keyCheck = aws ec2 describe-key-pairs --key-names $KEY_PAIR_NAME --region $AWS_REGION 2>&1
    if ($LASTEXITCODE -ne 0) {
        $keyPath = "$env:USERPROFILE\.ssh\$KEY_PAIR_NAME.pem"
        $keyMaterial = aws ec2 create-key-pair --key-name $KEY_PAIR_NAME `
            --region $AWS_REGION --query "KeyMaterial" --output text
        $keyMaterial | Set-Content -Path $keyPath -NoNewline
        Write-OK "Key pair created → $keyPath  (BACK THIS UP)"
    } else {
        Write-OK "Key pair already exists"
    }

    # ── Get latest Amazon Linux 2023 AMI ──────────────────────────────────
    Write-Info "Getting latest Amazon Linux 2023 AMI..."
    $AMI_ID = aws ec2 describe-images --owners amazon `
        --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" `
        --query "sort_by(Images, &CreationDate)[-1].ImageId" `
        --output text --region $AWS_REGION
    Write-OK "AMI ID: $AMI_ID"

    # ── Patch tfvars and backend config ───────────────────────────────────
    Write-Info "Patching tfvars and backend config with real values..."

    # Patch terraform.tfvars
    $tfvarsPath = "$ENV_DIR\terraform.tfvars"
    $tfvars = Get-Content $tfvarsPath -Raw
    $tfvars = $tfvars -replace "ACCOUNT_ID_PLACEHOLDER", $script:ACCOUNT_ID
    $tfvars = $tfvars -replace "AMI_ID_PLACEHOLDER", $AMI_ID
    Set-Content -Path $tfvarsPath -Value $tfvars -NoNewline
    Write-OK "terraform.tfvars patched"

    # Patch backend bucket in environments/dev/main.tf
    $mainTfPath = "$ENV_DIR\main.tf"
    $mainTf = Get-Content $mainTfPath -Raw
    $mainTf = $mainTf -replace "mnc-app-v2-terraform-state-ACCOUNT_ID_PLACEHOLDER", $STATE_BUCKET
    Set-Content -Path $mainTfPath -Value $mainTf -NoNewline
    Write-OK "Backend bucket patched in main.tf"

    Write-OK "Bootstrap complete. State bucket: $STATE_BUCKET"
}

# ─────────────────────────────────────────────────────────────────────────────
# PASS 1 — AWS infrastructure (VPC, Jenkins, ECR, EKS cluster, RDS)
# Skips kubernetes_namespace because EKS does not exist yet
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Pass1 {
    Write-Step "Pass 1 — Creating AWS infrastructure"

    Push-Location $ENV_DIR
    try {
        Write-Info "terraform init..."
        terraform init -reconfigure | Out-Null
        Write-OK "terraform init complete"

        # Import is now called INSIDE the Push-Location block,
        # so it runs in the correct directory with the correct backend.
        Import-JenkinsEBS

        Write-Info "terraform apply Pass 1 (AWS resources, skipping kubernetes_namespace)..."
        terraform apply `
            -target="module.dev.module.vpc" `
            -target="module.dev.module.jenkins" `
            -target="module.dev.module.ecr" `
            -target="module.dev.module.eks" `
            -target="module.dev.module.rds" `
            -target="module.dev.aws_security_group.alb" `
            -target="module.dev.aws_ssm_parameter.db_host" `
            -target="module.dev.aws_ssm_parameter.db_name" `
            -target="module.dev.aws_ssm_parameter.db_password" `
            -target="module.dev.aws_ssm_parameter.ecr_registry" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve

        if ($LASTEXITCODE -ne 0) { throw "Pass 1 terraform apply failed" }
        Write-OK "Pass 1 complete"
    } finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR EKS — polls until cluster is ACTIVE and all nodes are Ready
# Also waits for CoreDNS — required before any pods can be scheduled
# ─────────────────────────────────────────────────────────────────────────────
function Wait-ForEKS {
    Write-Step "Waiting for EKS cluster and nodes to be ready"

    # Update kubeconfig
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>&1 | Out-Null

    # Wait for cluster ACTIVE
    Wait-Until -Message "EKS cluster ACTIVE" -MaxSeconds 900 -IntervalSeconds 20 -Condition {
        $status = aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION `
            --query "cluster.status" --output text 2>&1
        $status -eq "ACTIVE"
    }

    # Refresh kubeconfig after cluster is active
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>&1 | Out-Null

    # Wait for nodes Ready
    # FIX: Wrap kubectl output in @() so .Count always returns item count even
    #      when only 1 node is returned (single string vs array distinction).
    # FIX: Use " Ready " with surrounding spaces to avoid matching "NotReady"
    #      — "NotReady" contains "Ready" so -notmatch "Ready" would incorrectly
    #      exclude NotReady nodes from the $notReady list, masking the problem.
    Wait-Until -Message "All EKS nodes Ready" -MaxSeconds 600 -IntervalSeconds 20 -Condition {
        $notReady = @(kubectl get nodes --no-headers 2>&1 | Where-Object { $_ -notmatch " Ready " -and $_ -notmatch "^$" })
        $allNodes = @(kubectl get nodes --no-headers 2>&1 | Where-Object { $_ -match "\S" })
        ($allNodes.Count -gt 0) -and ($notReady.Count -eq 0)
    }

    # Wait for CoreDNS — kube-proxy and vpc-cni must be running before CoreDNS,
    # and CoreDNS must be running before any application pods can resolve DNS
    # (i.e. connect to RDS by hostname).
    Write-Info "Waiting for CoreDNS pods to be Running..."
    Wait-Until -Message "CoreDNS Running" -MaxSeconds 300 -IntervalSeconds 15 -Condition {
        $coreDNS = @(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>&1)
        $running = @($coreDNS | Where-Object { $_ -match "Running" })
        $running.Count -ge 1
    }

    Write-OK "EKS cluster, nodes, and CoreDNS all ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# PASS 2 — Create kubernetes_namespace (needs EKS to be healthy)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Pass2 {
    Write-Step "Pass 2 — Creating Kubernetes namespace"

    Push-Location $ENV_DIR
    try {
        terraform apply `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -var="enable_kubernetes_resources=true" `
            -auto-approve

        if ($LASTEXITCODE -ne 0) { throw "Pass 2 terraform apply failed" }
        Write-OK "Pass 2 complete — kubernetes namespace created"
    } finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL ALB CONTROLLER — via Helm
# Uses the IRSA role ARN from Terraform output (always correct after recreate)
# ─────────────────────────────────────────────────────────────────────────────
function Install-ALBController {
    Write-Step "Installing AWS Load Balancer Controller"

    Push-Location $ENV_DIR
    try {
        $ROLE_ARN = terraform output -raw alb_controller_role_arn
        $VPC_ID   = terraform output -raw vpc_id
    } finally {
        Pop-Location
    }

    helm repo add eks https://aws.github.io/eks-charts 2>&1 | Out-Null
    helm repo update | Out-Null

    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
        --namespace kube-system `
        --set clusterName=$CLUSTER_NAME `
        --set serviceAccount.create=true `
        --set serviceAccount.name=aws-load-balancer-controller `
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN" `
        --set region=$AWS_REGION `
        --set vpcId=$VPC_ID `
        --wait `
        --timeout 5m

    Write-OK "ALB Controller installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL CLUSTER AUTOSCALER — via Helm
# Enables min=1 / max=2 auto-scaling based on pod resource requests
# ─────────────────────────────────────────────────────────────────────────────
function Install-ClusterAutoscaler {
    Write-Step "Installing Cluster Autoscaler"

    # ── Step 1: Get the current OIDC provider URL from the live cluster ───
    # This is always fresh — reads from the actual cluster, not Terraform state.
    $OIDC_URL = aws eks describe-cluster `
        --name $CLUSTER_NAME `
        --region $AWS_REGION `
        --query "cluster.identity.oidc.issuer" `
        --output text
    # Strip the https:// prefix — IAM trust policy needs it without scheme
    $OIDC_HOST = $OIDC_URL -replace "https://", ""
    Write-Info "OIDC provider: $OIDC_HOST"

    # ── Step 2: Get account ID and build the role ARN ─────────────────────
    $ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

    # ── Step 3: Update the IAM role trust policy with the current OIDC URL ─
    # The Terraform-created role exists but its trust policy has the OLD OIDC URL.
    # We patch it here so it always matches the current cluster's OIDC provider.
    $ROLE_NAME = "$PROJECT_NAME-$ENVIRONMENT-cluster-autoscaler-role"
    $TRUST_POLICY = @{
        Version   = "2012-10-17"
        Statement = @(
            @{
                Effect    = "Allow"
                Principal = @{ Federated = "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}" }
                Action    = "sts:AssumeRoleWithWebIdentity"
                Condition = @{
                    StringEquals = @{
                        "${OIDC_HOST}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
                        "${OIDC_HOST}:aud" = "sts.amazonaws.com"
                    }
                }
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    # Check if role exists — create it if not, update trust policy if yes
    $roleCheck = aws iam get-role --role-name $ROLE_NAME 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Creating Cluster Autoscaler IAM role..."
        aws iam create-role `
            --role-name $ROLE_NAME `
            --assume-role-policy-document $TRUST_POLICY | Out-Null

        # Attach the autoscaler policy (already created by Terraform in eks module)
        $POLICY_ARN = "arn:aws:iam::${ACCOUNT_ID}:policy/$PROJECT_NAME-$ENVIRONMENT-cluster-autoscaler"
        aws iam attach-role-policy `
            --role-name $ROLE_NAME `
            --policy-arn $POLICY_ARN | Out-Null
        Write-OK "IAM role created: $ROLE_NAME"
    } else {
        Write-Info "Updating trust policy on existing role: $ROLE_NAME"
        aws iam update-assume-role-policy `
            --role-name $ROLE_NAME `
            --policy-document $TRUST_POLICY | Out-Null
        Write-OK "Trust policy updated with current OIDC URL"
    }

    $ROLE_ARN = "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

    # ── Step 4: Install via Helm with the fresh role ARN ──────────────────
    helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>&1 | Out-Null
    helm repo update | Out-Null

    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler `
        --namespace kube-system `
        --set autoDiscovery.clusterName=$CLUSTER_NAME `
        --set awsRegion=$AWS_REGION `
        --set rbac.serviceAccount.create=true `
        --set rbac.serviceAccount.name=cluster-autoscaler `
        --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN" `
        --set image.tag=v1.31.0 `
        --set extraArgs.balance-similar-node-groups=true `
        --set extraArgs.skip-nodes-with-system-pods=false `
        --set extraArgs.scale-down-delay-after-add="5m" `
        --set extraArgs.scale-down-unneeded-time="5m" `
        --wait `
        --timeout 5m

    Write-OK "Cluster Autoscaler installed with fresh IRSA role: $ROLE_ARN"
}

# ─────────────────────────────────────────────────────────────────────────────
# PATCH CONFIGMAP — inject real RDS endpoint into k8s/dev/configmap.yaml
# ─────────────────────────────────────────────────────────────────────────────
function Update-ConfigMap {
    Write-Step "Patching ConfigMap with real RDS endpoint"

    Push-Location $ENV_DIR
    try {
        $RDS_HOST = terraform output -raw db_host
    } finally {
        Pop-Location
    }

    $cmPath = "$K8S_DIR\configmap.yaml"
    $cm = Get-Content $cmPath -Raw
    $cm = $cm -replace "DB_HOST_PLACEHOLDER", $RDS_HOST
    $cm = $cm -replace '"mnc-app-dev-mysql\.[^"]*"', "`"$RDS_HOST`""
    Set-Content -Path $cmPath -Value $cm -NoNewline

    Write-OK "ConfigMap patched with RDS host: $RDS_HOST"
}

# ─────────────────────────────────────────────────────────────────────────────
# INVOKE K8S MANIFESTS (non-deployment only)
# Deployment YAMLs have placeholder image tags — Jenkins applies those.
# Renamed from Apply-K8sManifests to use an approved PowerShell verb.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-K8sManifests {
    Write-Step "Applying Kubernetes manifests (non-deployment)"

    # Inject DB secret from SSM
    Write-Info "Injecting DB secret from SSM..."
    $DB_PASS = aws ssm get-parameter `
        --name "/$PROJECT_NAME/$ENVIRONMENT/db/password" `
        --with-decryption --query "Parameter.Value" --output text --region $AWS_REGION

    kubectl create secret generic app-db-secret `
        "--from-literal=DB_PASSWORD=$DB_PASS" `
        --namespace=$ENVIRONMENT `
        --dry-run=client -o yaml | kubectl apply -f -

    Remove-Variable DB_PASS
    Write-OK "DB secret injected"

    # Apply non-deployment manifests
    kubectl apply -f "$K8S_DIR\namespace.yaml"
    kubectl apply -f "$K8S_DIR\configmap.yaml"
    kubectl apply -f "$K8S_DIR\backend-service.yaml"
    kubectl apply -f "$K8S_DIR\frontend-service.yaml"
    kubectl apply -f "$K8S_DIR\ingress.yaml"

    Write-OK "Manifests applied. Waiting for ALB to be provisioned (2-3 min)..."
    Write-Info "Pods will come up after first Jenkins pipeline run (Step 5 in README)"

    # Wait for ALB address to appear in ingress status
    $maxWait = 180
$elapsed = 0
while ($elapsed -lt $maxWait) {
    $albAddr = (kubectl get ingress app-ingress -n $ENVIRONMENT `
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>&1 | Out-String).Trim()

    if (-not [string]::IsNullOrWhiteSpace($albAddr) -and $albAddr -notmatch "Error") {
        Write-OK "App ALB ready: http://$albAddr"
        break
    }

    Start-Sleep 15
    $elapsed += 15
    Write-Info "ALB provisioning... ($elapsed/$maxWait s)"
}
}

# ─────────────────────────────────────────────────────────────────────────────
# WAIT FOR JENKINS — polls until Jenkins HTTP 200
# ─────────────────────────────────────────────────────────────────────────────
function Wait-ForJenkins {
    Write-Step "Waiting for Jenkins to be ready"

    Push-Location $ENV_DIR
    try {
        $JENKINS_IP = terraform output -raw jenkins_public_ip
    } finally {
        Pop-Location
    }

    Write-Info "Jenkins EC2 public IP: $JENKINS_IP"
    Write-Info "Userdata script takes 5-8 minutes on first run (installing Jenkins + SonarQube)..."
    Write-Info "On recreate it loads from EBS — faster (~2 min)"

    Wait-Until -Message "Jenkins responding on port 8080" -MaxSeconds 600 -IntervalSeconds 20 -Condition {
        try {
            $r = Invoke-WebRequest -Uri "http://$($JENKINS_IP):8080/login" `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $r.StatusCode -eq 200
        } catch { $false }
    }

    # Get Jenkins initial password from SSM (only meaningful on fresh install)
    Start-Sleep 10  # brief pause for SSM put-parameter to complete
    $initPass = aws ssm get-parameter --name "/$PROJECT_NAME/jenkins/initial-password" `
        --with-decryption --query "Parameter.Value" --output text --region $AWS_REGION 2>&1

    Write-OK "Jenkins is up!"
    Write-Host ""
    Write-Host "  Jenkins URL  : http://$JENKINS_IP`:8080" -ForegroundColor White
    Write-Host "  SonarQube URL: http://$JENKINS_IP`:9000"  -ForegroundColor White
    if ($initPass -and $initPass -notmatch "ParameterNotFound") {
        Write-Host "  Initial Password (fresh install only): $initPass" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW SUMMARY — outputs all important URLs and next steps
# Renamed from Print-Summary to use an approved PowerShell verb.
# ─────────────────────────────────────────────────────────────────────────────
function Show-Summary {
    Write-Step "Infrastructure ready"

    Push-Location $ENV_DIR
    try {
        $JENKINS_IP  = terraform output -raw jenkins_public_ip
        $JENKINS_ALB = terraform output -raw jenkins_alb_dns
        $ECR_URLS    = terraform output -json ecr_repository_urls | ConvertFrom-Json
    } finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  MNC App Lab — Infrastructure Ready                         ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "║  Jenkins  (direct) : http://$($JENKINS_IP):8080" -ForegroundColor White
    Write-Host "║  Jenkins  (ALB)    : http://$JENKINS_ALB" -ForegroundColor White
    Write-Host "║  SonarQube         : http://$($JENKINS_IP):9000" -ForegroundColor White
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "║  ECR Backend  : $($ECR_URLS.backend)" -ForegroundColor White
    Write-Host "║  ECR Frontend : $($ECR_URLS.frontend)" -ForegroundColor White
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  NEXT STEPS                                                  ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "║  1. Open Jenkins and configure (README Step 4)               ║" -ForegroundColor White
    Write-Host "║  2. Run first pipeline (README Step 5) — pods come up here  ║" -ForegroundColor White
    Write-Host "║  3. When done learning: .\infra.ps1 destroy                 ║" -ForegroundColor White
    Write-Host "║  4. Next session      : .\infra.ps1 recreate                ║" -ForegroundColor White
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# DESTROY — safe ordered teardown
# Order matters: K8s resources → EKS → RDS → Jenkins EC2 → VPC
# EBS volume is detached from Terraform state before destroy so it is preserved
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Destroy {
    Write-Step "Destroying infrastructure (preserving Jenkins EBS, ECR, S3, DynamoDB, Key Pair)"

    Write-Warn "This will destroy EKS, RDS, Jenkins EC2, VPC and all associated resources."
    Write-Warn "Jenkins EBS (your plugins/config/SonarQube data) will be PRESERVED."
    $confirm = Read-Host "  Type 'yes' to continue"
    if ($confirm -ne "yes") { Write-Info "Destroy cancelled."; return }

    # ── Step 1: Delete Kubernetes resources first ──────────────────────────
    # If we destroy EKS before deleting Ingress, the ALB Controller never gets
    # a chance to delete the AWS ALB — it becomes an orphaned resource that
    # blocks VPC deletion (ALBs hold ENIs in the VPC subnets).
    Write-Step "Deleting Kubernetes resources (so ALB Controller can clean up ALBs)"

    $kubeConfig = aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Delete ingress first — this tells the ALB Controller to delete the AWS ALB
        kubectl delete ingress app-ingress -n $ENVIRONMENT --ignore-not-found=true 2>&1 | Out-Null
        Write-Info "Ingress deleted — waiting for ALB to be removed by ALB Controller..."

        # FIX: ALB Controller names ALBs with a "k8s-" prefix (e.g. k8s-dev-appingre-xxxx),
        # not with the project name. Filter by the cluster tag that ALB Controller always
        # stamps on every ALB it manages, which is reliable regardless of the name format.
        # Wait up to 5 minutes — ALB deletion can take 3-5 minutes in practice.
        $albWait = 0
        while ($albWait -lt 300) {
            $albs = aws elbv2 describe-load-balancers --region $AWS_REGION `
                --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-$ENVIRONMENT')].LoadBalancerName" `
                --output text 2>&1
            if (-not $albs -or $albs -match "^None$" -or $albs.Trim() -eq "") {
                Write-OK "All app ALBs removed"
                break
            }
            Write-Info "Waiting for ALB deletion... ($albWait/300 s) — $albs"
            Start-Sleep 15
            $albWait += 15
        }

        # Delete remaining K8s resources
        kubectl delete -f "$K8S_DIR\backend-service.yaml"   --ignore-not-found=true 2>&1 | Out-Null
        kubectl delete -f "$K8S_DIR\frontend-service.yaml"  --ignore-not-found=true 2>&1 | Out-Null
        kubectl delete deployment backend frontend -n $ENVIRONMENT --ignore-not-found=true 2>&1 | Out-Null
        kubectl delete namespace $ENVIRONMENT --ignore-not-found=true 2>&1 | Out-Null
        Write-OK "Kubernetes resources cleaned up"
    } else {
        Write-Warn "Could not connect to EKS — may already be destroyed. Continuing..."
    }

    Write-Step "Pre-deleting CloudWatch Log Group (prevents recreate conflict)"
$logGroupName = "/aws/vpc/$PROJECT_NAME-$ENVIRONMENT/flow-logs"

Push-Location $ENV_DIR
terraform state rm "module.dev.module.vpc.aws_cloudwatch_log_group.vpc_flow_logs" 2>&1 | Out-Null
Pop-Location

aws logs delete-log-group `
    --log-group-name $logGroupName `
    --region $AWS_REGION 2>&1 | Out-Null
Write-OK "CloudWatch Log Group deleted and removed from state: $logGroupName"

    # ── Step 2: Remove EBS volume from Terraform state ─────────────────────
    # This prevents terraform destroy from deleting the persistent EBS volume.
    # The volume has prevent_destroy=true but we also remove it from state
    # for extra safety.
    Write-Step "Preserving Jenkins EBS volume (removing from Terraform state)"
    Push-Location $ENV_DIR
    try {
        $ebsVolumeId = terraform output -raw jenkins_ebs_volume_id 2>&1
        if ($LASTEXITCODE -eq 0 -and $ebsVolumeId -match "^vol-") {
            Write-Info "Jenkins EBS volume ID: $ebsVolumeId"

            # Remove volume attachment from state first, then the volume itself
            terraform state rm "module.dev.module.jenkins.aws_volume_attachment.jenkins_home" 2>&1 | Out-Null
            terraform state rm "module.dev.module.jenkins.aws_ebs_volume.jenkins_home" 2>&1 | Out-Null
            Write-OK "Jenkins EBS removed from Terraform state — volume $ebsVolumeId is preserved in AWS"

            # Save volume ID to a local file so create can reattach it
            # FIX: Use -NoNewline so Get-Content later does not read a trailing newline
            $ebsVolumeId | Set-Content -Path "..\..\..\.jenkins-ebs-volume-id" -NoNewline
            Write-OK "EBS volume ID saved to .jenkins-ebs-volume-id"
        } else {
            Write-Warn "Could not get EBS volume ID — it may have already been removed from state"
        }
    } catch {
        Write-Warn "Error removing EBS from state: $_"
    } finally {
        Pop-Location
    }
    # ── Clean up manually created Cluster Autoscaler IAM role ─────────────
    # This role is created by Install-ClusterAutoscaler outside of Terraform.
    # Must be deleted before terraform destroy or the policy deletion will
    # fail with DeleteConflict (policy still attached to this role).
    Write-Step "Cleaning up Cluster Autoscaler IAM role"
    $script:ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
    $CA_ROLE_NAME  = "$PROJECT_NAME-$ENVIRONMENT-cluster-autoscaler-role"
    $CA_POLICY_ARN = "arn:aws:iam::$($script:ACCOUNT_ID):policy/$PROJECT_NAME-$ENVIRONMENT-cluster-autoscaler"

    $roleExists = aws iam get-role --role-name $CA_ROLE_NAME 2>&1
    if ($LASTEXITCODE -eq 0) {
        aws iam detach-role-policy `
            --role-name $CA_ROLE_NAME `
            --policy-arn $CA_POLICY_ARN 2>&1 | Out-Null
        aws iam delete-role `
            --role-name $CA_ROLE_NAME 2>&1 | Out-Null
        Write-OK "Cluster Autoscaler IAM role deleted: $CA_ROLE_NAME"
    } else {
        Write-Info "Cluster Autoscaler IAM role not found — skipping"
    }
    # ── Step 3: Terraform destroy (ordered targets) ────────────────────────
    Write-Step "Running terraform destroy (ordered)"
    Push-Location $ENV_DIR
    try {
        # Remove kubernetes_namespace from state first (cluster being destroyed)
        terraform state rm "module.dev.kubernetes_namespace.env" 2>&1 | Out-Null

        # Destroy EKS first (nodes drain cleanly before cluster is removed)
        Write-Info "Destroying EKS..."
        terraform destroy `
            -target="module.dev.module.eks" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve
        Write-OK "EKS destroyed"

        # Destroy RDS
        Write-Info "Destroying RDS..."
        terraform destroy `
            -target="module.dev.module.rds" `
            -target="module.dev.aws_ssm_parameter.db_host" `
            -target="module.dev.aws_ssm_parameter.db_name" `
            -target="module.dev.aws_ssm_parameter.db_password" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve
        Write-OK "RDS destroyed"

        # Destroy Jenkins EC2 and ALB (EBS already removed from state — won't be touched)
        Write-Info "Destroying Jenkins EC2 and ALB..."
        terraform destroy `
            -target="module.dev.module.jenkins" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve
        Write-OK "Jenkins EC2 destroyed (EBS preserved)"

        # FIX: Removed Out-Null suppression — a failed destroy here would silently
        # leave the SSM parameter in state, causing drift. Let errors surface.
        Write-Info "Destroying ECR SSM parameter..."
        terraform destroy `
            -target="module.dev.aws_ssm_parameter.ecr_registry" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve
        Write-OK "ECR SSM parameter destroyed"

        # Destroy VPC and ALB SG last (ENIs must be clear)
        Write-Info "Destroying VPC..."
        terraform destroy `
            -target="module.dev.module.vpc" `
            -target="module.dev.aws_security_group.alb" `
            -var-file="terraform.tfvars" `
            -var="db_password=$DB_PASSWORD" `
            -auto-approve
        Write-OK "VPC destroyed"

    } finally {
        Pop-Location
    }

    Write-Host ""
    Write-OK "Destroy complete!"
    Write-Info "Preserved: Jenkins EBS volume, ECR repositories, S3 state bucket, DynamoDB, Key Pair"
    Write-Info "To rebuild: .\infra.ps1 create"
}

# ─────────────────────────────────────────────────────────────────────────────
# IMPORT EBS — called during create after previous destroy
# Imports the preserved EBS volume back into Terraform state.
# Renamed from Reattach-EBS to use an approved PowerShell verb.
# ─────────────────────────────────────────────────────────────────────────────
function Import-JenkinsEBS {
    # NOTE: Caller must already be inside $ENV_DIR when calling this function.
    # This function does NOT push/pop location — it relies on the caller's context.

    $ebsIdFile = "..\..\..\.jenkins-ebs-volume-id"   # relative to ENV_DIR
    if (-not (Test-Path $ebsIdFile)) {
        Write-Info "No saved EBS volume ID found — fresh install"
        return
    }

    $ebsVolumeId = (Get-Content $ebsIdFile -Raw).Trim()
    if (-not $ebsVolumeId -or -not ($ebsVolumeId -match "^vol-")) {
        Write-Info "Invalid EBS volume ID in file — skipping reattach"
        return
    }

    Write-Step "Reimporting preserved Jenkins EBS volume: $ebsVolumeId"

    $volState = aws ec2 describe-volumes --volume-ids $ebsVolumeId `
        --query "Volumes[0].State" --output text --region $AWS_REGION 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "EBS volume $ebsVolumeId not found in AWS. Cannot continue — data may be lost."
    }

    Write-Info "EBS volume state: $volState"

    if ($volState -eq "in-use") {
        Write-Warn "Volume is still in-use. Attempting detach before import..."
        aws ec2 detach-volume --volume-id $ebsVolumeId --region $AWS_REGION 2>&1 | Out-Null
        Start-Sleep 15   # give AWS time to detach
    }

    # Check if already in state (idempotency — safe to re-run)
    $stateList = terraform state list 2>&1
    if ($stateList -match "module\.dev\.module\.jenkins\.aws_ebs_volume\.jenkins_home") {
        Write-OK "EBS volume already in Terraform state — skipping import"
        return
    }

    Write-Info "Importing EBS volume into Terraform state..."
    terraform import `
        -var-file="terraform.tfvars" `
        -var="db_password=$DB_PASSWORD" `
        "module.dev.module.jenkins.aws_ebs_volume.jenkins_home" `
        $ebsVolumeId

    if ($LASTEXITCODE -ne 0) {
        throw "terraform import failed for EBS volume $ebsVolumeId — aborting to prevent data loss"
    }

    Write-OK "EBS volume $ebsVolumeId imported into Terraform state"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS — show current state of all resources
# ─────────────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Step "Infrastructure Status"

    # EKS
    Write-Host "`n[ EKS Cluster ]" -ForegroundColor Cyan
    $clusterStatus = aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION `
        --query "cluster.status" --output text 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Cluster: $CLUSTER_NAME — $clusterStatus"
        aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>&1 | Out-Null
        kubectl get nodes 2>&1
        Write-Host ""
        Write-Host "Pods in dev namespace:" -ForegroundColor Gray
        kubectl get pods -n dev 2>&1
    } else {
        Write-Warn "EKS cluster not found — infrastructure may be destroyed"
    }

    # Jenkins EC2
    Write-Host "`n[ Jenkins EC2 ]" -ForegroundColor Cyan
    # FIX: Wrap in try/catch — if aws CLI fails (e.g. permissions) ConvertFrom-Json
    # would throw a terminating parse error on the error text returned by aws.
    try {
        $jenkinsJson = aws ec2 describe-instances --region $AWS_REGION `
            --filters "Name=tag:Name,Values=$PROJECT_NAME-jenkins-master" "Name=instance-state-name,Values=running" `
            --query "Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,Type:InstanceType}" `
            --output json 2>&1
        $jenkins = $jenkinsJson | ConvertFrom-Json
        if ($jenkins.State) {
            Write-OK "Jenkins: $($jenkins.State) | $($jenkins.Type) | http://$($jenkins.IP):8080"
        } else {
            Write-Warn "Jenkins EC2 not running"
        }
    } catch {
        Write-Warn "Could not query Jenkins EC2: $_"
    }

    # Jenkins EBS
    Write-Host "`n[ Jenkins EBS (persistent) ]" -ForegroundColor Cyan
    $ebsIdFile = ".jenkins-ebs-volume-id"
    if (Test-Path $ebsIdFile) {
        # FIX: .Trim() here too — consistent with Import-JenkinsEBS
        $ebsId = (Get-Content $ebsIdFile -Raw).Trim()
        try {
            $ebsState = aws ec2 describe-volumes --volume-ids $ebsId `
                --query "Volumes[0].{State:State,Size:Size}" --output json --region $AWS_REGION 2>&1 | ConvertFrom-Json
            if ($ebsState.State) {
                Write-OK "EBS volume: $ebsId — $($ebsState.State) — $($ebsState.Size)GB"
            }
        } catch {
            Write-Warn "Could not query EBS volume $ebsId`: $_"
        }
    } else {
        Write-Info "No EBS volume ID on file (will be set after first create)"
    }

    # RDS
    Write-Host "`n[ RDS MySQL ]" -ForegroundColor Cyan
    try {
        $rds = aws rds describe-db-instances --region $AWS_REGION `
            --db-instance-identifier "$PROJECT_NAME-$ENVIRONMENT-mysql" `
            --query "DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Endpoint:Endpoint.Address}" `
            --output json 2>&1 | ConvertFrom-Json
        if ($rds.Status) {
            Write-OK "RDS: $($rds.Status) | $($rds.Class) | $($rds.Endpoint)"
        } else {
            Write-Warn "RDS instance not found"
        }
    } catch {
        Write-Warn "RDS instance not found — may be destroyed"
    }

    # ECR
    Write-Host "`n[ ECR Repositories (always preserved) ]" -ForegroundColor Cyan
    foreach ($repo in @("backend","frontend")) {
        $images = aws ecr list-images --repository-name "$PROJECT_NAME/$repo" --region $AWS_REGION `
            --query "length(imageIds)" --output text 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "$PROJECT_NAME/$repo — $images image(s)"
        } else {
            Write-Warn "$PROJECT_NAME/$repo — not found"
        }
    }

    # Cost estimate
    Write-Host "`n[ Rough Cost Estimate ]" -ForegroundColor Cyan
    Write-Host "  When RUNNING (per hour):" -ForegroundColor Gray
    Write-Host "    Jenkins t3.large     ~₹6.50/hr" -ForegroundColor Gray
    Write-Host "    EKS control plane    ~₹8.50/hr" -ForegroundColor Gray
    Write-Host "    EKS t3.small SPOT    ~₹0.75/hr" -ForegroundColor Gray
    Write-Host "    RDS db.t3.micro      ~₹1.60/hr" -ForegroundColor Gray
    Write-Host "    Total when running   ~₹17.35/hr" -ForegroundColor Yellow
    Write-Host "  When DESTROYED:" -ForegroundColor Gray
    Write-Host "    EBS 30GB gp3         ~₹0.14/hr (always)" -ForegroundColor Gray
    Write-Host "    ECR storage          ~negligible" -ForegroundColor Gray
    Write-Host "  2 hr/day learning = ~₹35/day = ~₹1,050/month" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# CREATE — full provision flow
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Create {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  MNC App Lab — CREATE                                        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

    Invoke-Bootstrap

    $logGroupName = "/aws/vpc/$PROJECT_NAME-$ENVIRONMENT/flow-logs"
Write-Info "Checking CloudWatch log group status before Terraform..."
$waited = 0
while ($waited -lt 90) {
    $result = aws logs describe-log-groups `
        --log-group-name-prefix $logGroupName `
        --query "logGroups[?logGroupName=='$logGroupName'].logGroupName" `
        --output text --region $AWS_REGION 2>&1
    $exists = if ($result) { $result.ToString().Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($exists)) {
        Write-OK "Log group clear — proceeding to Terraform"
        break
    }
    Write-Info "Log group still propagating... ($waited/90s)"
    Start-Sleep 10
    $waited += 10
}

    Invoke-Pass1
    Wait-ForEKS
    Invoke-Pass2
    Install-ALBController
    Install-ClusterAutoscaler
    Update-ConfigMap
    Invoke-K8sManifests
    Wait-ForJenkins
    Show-Summary
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN — dispatch based on action
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "MNC App Lab — infra.ps1 | Action: $Action" -ForegroundColor Magenta
Write-Host "Region: $AWS_REGION | Project: $PROJECT_NAME | Environment: $ENVIRONMENT" -ForegroundColor Gray

switch ($Action) {
    "create"   { Invoke-Create }
    "destroy"  { Invoke-Destroy }
    "recreate" {
        Invoke-Destroy
        Invoke-Create
    }
    "status"   { Show-Status }
}
