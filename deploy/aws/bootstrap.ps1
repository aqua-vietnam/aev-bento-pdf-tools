<#
.SYNOPSIS
    Dựng hạ tầng AEV PDF Tool trên AWS. Chỉ còn MỘT stack phải deploy bằng tay.

.DESCRIPTION
    Chạy được nhiều lần (idempotent): `aws cloudformation deploy` tự tạo mới hoặc cập nhật,
    và bỏ qua stack không có thay đổi.

    Kiến trúc hai stack:
        pdftool-platform   -> ECR + log group + 2 IAM role + ECS cluster + security group
                              + S3 artifact bucket + CodeBuild + CodePipeline.
                              Deploy bằng script này.
        pdftool-service    -> task definition + Cloud Map + ECS service + lịch bật/tắt.
                              KHÔNG deploy ở đây: chính CodePipeline tạo nó ở stage Deploy,
                              vì nó cần ImageTag của bản build đầu tiên. Pipeline tự chạy
                              ngay sau khi được tạo.

    Bản cũ có 7 stack (ecr / foundation / cluster / security-group / scaling / pipeline /
    service). Nếu tài khoản còn các stack cũ đó, chạy teardown-legacy-stacks.ps1 TRƯỚC:
    tên tài nguyên trùng nhau nên stack mới không tạo được đè lên.

.EXAMPLE
    .\bootstrap.ps1
.EXAMPLE
    .\bootstrap.ps1 -OperatorNetworkCidr 10.56.10.0/24
#>
[CmdletBinding()]
param(
    [string]$Region = 'ap-southeast-1',

    # aqua-production. Đây là VPC duy nhất gắn với private hosted zone của namespace
    # internal.aquavietnam.vn -- đặt task ở VPC khác thì tên miền không phân giải được.
    [string]$VpcId = 'vpc-02a4ec6a8e5959339',

    # Dải mạng người dùng nội bộ. Mặc định đúng bằng dải adms-console-task-sg đang mở.
    [string]$OperatorNetworkCidr = '10.0.0.0/8',

    # Dải thứ hai Transit Gateway quảng bá. Để '' nếu không cần.
    [string]$SecondaryNetworkCidr = '172.16.0.0/15'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Hai template giờ thuần ASCII nên biến này không còn bắt buộc, nhưng vẫn đặt: AWS CLI trên
# Windows đọc file:// theo codepage hệ thống, và chỉ cần ai đó thêm một dòng tiếng Việt vào
# template là lỗi "text contents could not be decoded" quay lại ngay.
$env:AWS_CLI_FILE_ENCODING = 'UTF-8'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Tài khoản đang dùng:" -ForegroundColor Yellow
& aws sts get-caller-identity --query 'Arn' --output text
if ($LASTEXITCODE -ne 0) { throw "Không gọi được STS. Session MFA hết hạn? Chạy: aws-mfa <mã 6 số>" }

Write-Host ""
Write-Host "=== pdftool-platform ===" -ForegroundColor Cyan

$cliArgs = @(
    'cloudformation', 'deploy',
    '--stack-name', 'pdftool-platform',
    '--template-file', (Join-Path $here 'pdftool-platform.yaml'),
    '--region', $Region,
    '--capabilities', 'CAPABILITY_NAMED_IAM',
    '--no-fail-on-empty-changeset',
    '--tags', 'Project=AevPdfTool', 'Environment=Prod',
    '--parameter-overrides',
    "VpcId=$VpcId",
    "OperatorNetworkCidr=$OperatorNetworkCidr",
    "SecondaryNetworkCidr=$SecondaryNetworkCidr"
)

& aws @cliArgs
if ($LASTEXITCODE -ne 0) {
    throw "Stack pdftool-platform thất bại. Xem sự kiện: aws cloudformation describe-stack-events --stack-name pdftool-platform --max-items 20"
}
Write-Host "pdftool-platform OK" -ForegroundColor Green

Write-Host ""
Write-Host "Xong phần hạ tầng." -ForegroundColor Green
Write-Host ""
Write-Host "CodePipeline tự chạy ngay sau khi được tạo. Lần chạy đầu mất khoảng 15-25 phút" -ForegroundColor Yellow
Write-Host "(npm ci + vite build + docs + 20 bản i18n), và chính nó tạo ra stack pdftool-service."
Write-Host ""
Write-Host "Theo dõi:"
Write-Host "  aws codepipeline get-pipeline-state --name pdftool-pipeline --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table"
Write-Host ""
Write-Host "Khi pipeline xong, service chạy 1 task và theo lịch 07:00-20:00 (giờ Việt Nam)."
Write-Host "Bật tay ngoài giờ:"
Write-Host "  aws ecs update-service --cluster pdftool-cluster --service pdftool --desired-count 1"
Write-Host ""
Write-Host "Rồi kiểm tra tên miền phân giải được từ trong VPC:"
Write-Host "  http://pdftool.internal.aquavietnam.vn"