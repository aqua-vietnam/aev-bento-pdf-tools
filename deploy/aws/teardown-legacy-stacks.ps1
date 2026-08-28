<#
.SYNOPSIS
    Gỡ sạch 7 stack của kiến trúc cũ, để bootstrap.ps1 dựng lại theo mô hình 2 stack.

.DESCRIPTION
    Chỉ chạy MỘT LẦN, khi chuyển từ bản 7 stack (pdftool-ecr / -foundation / -cluster /
    -security-group / -scaling / -pipeline / -service) sang bản 2 stack
    (pdftool-platform / pdftool-service).

    Vì sao phải xoá thay vì update: gần như mọi tài nguyên đều có tên cố định
    (pdftool-execution-role, pdftool-task-sg, cluster pdftool-cluster, ECR repo...). Stack mới
    tạo lại đúng những cái tên đó, và CloudFormation sẽ báo "already exists" nếu stack cũ còn
    đang giữ chúng.

    Thứ tự xoá ngược với thứ tự tạo. Ba việc CloudFormation KHÔNG tự làm được, script làm hộ:
      1. Đưa ECS service về 0 task trước khi xoá stack service, nếu không việc xoá treo rất lâu.
      2. Dọn sạch S3 artifact bucket -- bucket còn object thì DELETE_FAILED.
      3. Xoá ECR repository và log group /ecs/pdftool: hai thứ này có DeletionPolicy Retain nên
         sống sót sau khi stack biến mất, rồi va tên với stack mới.

    MẤT GÌ: toàn bộ image trong ECR (pipeline sẽ build lại), log container cũ, và service ngừng
    phục vụ cho tới khi pipeline chạy xong (~15-25 phút).

.EXAMPLE
    .\teardown-legacy-stacks.ps1 -WhatIf
.EXAMPLE
    .\teardown-legacy-stacks.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Region = 'ap-southeast-1',

    # Thứ tự ngược với bootstrap cũ: service trước (nó phụ thuộc tất cả), pipeline và scaling
    # tiếp theo, rồi tới các stack nền.
    [string[]]$LegacyStacks = @(
        'pdftool-service',
        'pdftool-pipeline',
        'pdftool-scaling',
        'pdftool-security-group',
        'pdftool-cluster',
        'pdftool-foundation',
        'pdftool-ecr'
    ),

    [string]$LegacyEcrRepo = 'pdftool-ecr-repo',
    [string]$LegacyLogGroup = '/ecs/pdftool',
    [string]$LegacyCluster = 'pdftool-cluster',
    [string]$LegacyService = 'pdftool'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:AWS_CLI_FILE_ENCODING = 'UTF-8'
$env:AWS_PAGER = ''

function Test-StackExists {
    param([string]$Name)
    & aws cloudformation describe-stacks --stack-name $Name --region $Region --query 'Stacks[0].StackName' --output text 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

Write-Host "Tài khoản đang dùng:" -ForegroundColor Yellow
& aws sts get-caller-identity --query 'Arn' --output text
if ($LASTEXITCODE -ne 0) { throw "Không gọi được STS. Session MFA hết hạn? Chạy: aws-mfa <mã 6 số>" }

$existing = @($LegacyStacks | Where-Object { Test-StackExists $_ })
if ($existing.Count -eq 0) {
    Write-Host "Không còn stack cũ nào. Chạy thẳng bootstrap.ps1." -ForegroundColor Green
    return
}

Write-Host ""
Write-Host "Sẽ xoá theo thứ tự:" -ForegroundColor Yellow
$existing | ForEach-Object { Write-Host "  - $_" }
Write-Host ""

if (-not $PSCmdlet.ShouldProcess(($existing -join ', '), 'Xoá stack CloudFormation')) { return }

# --- 1. Đưa service về 0 task -------------------------------------------------
# Xoá stack trong lúc còn task đang chạy vẫn được, nhưng ECS phải drain từng task và bước xoá
# kéo dài vài phút không cần thiết.
if ($existing -contains 'pdftool-service') {
    Write-Host "Đưa ECS service về 0 task..." -ForegroundColor Cyan
    & aws ecs update-service --cluster $LegacyCluster --service $LegacyService --desired-count 0 --region $Region --query 'service.desiredCount' --output text 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  (bỏ qua: service không tồn tại hoặc đã ở 0)" -ForegroundColor DarkGray }
}

# --- 2. Dọn S3 artifact bucket ------------------------------------------------
if ($existing -contains 'pdftool-pipeline') {
    $accountId = & aws sts get-caller-identity --query 'Account' --output text
    $bucket = "codepipeline-$Region-$accountId-pdftool"
    Write-Host "Dọn artifact bucket s3://$bucket ..." -ForegroundColor Cyan
    & aws s3 rm "s3://$bucket" --recursive --region $Region --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  (bỏ qua: bucket không tồn tại hoặc đã rỗng)" -ForegroundColor DarkGray }
}

# --- 3. Xoá từng stack, chờ xong mới sang cái tiếp theo -----------------------
foreach ($name in $existing) {
    Write-Host ""
    Write-Host "=== Xoá $name ===" -ForegroundColor Cyan
    & aws cloudformation delete-stack --stack-name $name --region $Region
    if ($LASTEXITCODE -ne 0) { throw "delete-stack $name thất bại." }

    & aws cloudformation wait stack-delete-complete --stack-name $name --region $Region
    if ($LASTEXITCODE -ne 0) {
        throw "Chờ xoá $name thất bại. Xem: aws cloudformation describe-stack-events --stack-name $name --max-items 20"
    }
    Write-Host "$name đã xoá." -ForegroundColor Green
}

# --- 4. Dọn tài nguyên DeletionPolicy Retain ---------------------------------
# Hai thứ này sống sót sau khi stack biến mất và sẽ va tên với pdftool-platform.
Write-Host ""
Write-Host "Dọn tài nguyên còn sót (DeletionPolicy Retain)..." -ForegroundColor Cyan

Write-Host "  ECR repository $LegacyEcrRepo"
& aws ecr delete-repository --repository-name $LegacyEcrRepo --force --region $Region --query 'repository.repositoryName' --output text 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "    (không tồn tại, bỏ qua)" -ForegroundColor DarkGray }

Write-Host "  Log group $LegacyLogGroup"
& aws logs delete-log-group --log-group-name $LegacyLogGroup --region $Region 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "    (không tồn tại, bỏ qua)" -ForegroundColor DarkGray }

foreach ($lg in @('/aws/lambda/pdftool-scale-up', '/aws/lambda/pdftool-scale-down')) {
    Write-Host "  Log group $lg"
    & aws logs delete-log-group --log-group-name $lg --region $Region 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "    (không tồn tại, bỏ qua)" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "Đã gỡ xong kiến trúc cũ. Bước tiếp theo:" -ForegroundColor Green
Write-Host "  .\bootstrap.ps1"
Write-Host ""
Write-Host "Lưu ý: Cloud Map service 'pdftool' do stack pdftool-service quản lý nên đã bị xoá cùng" -ForegroundColor Yellow
Write-Host "stack đó. Nếu vì lý do nào đó nó còn sót lại, stack mới sẽ báo trùng tên -- xoá tay:"
Write-Host "  aws servicediscovery list-services --query ""Services[?Name=='pdftool'].Id"" --output text"
Write-Host "  aws servicediscovery delete-service --id <id>"