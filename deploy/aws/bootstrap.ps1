<#
.SYNOPSIS
    Dựng toàn bộ hạ tầng AEV PDF Tool trên AWS theo đúng thứ tự phụ thuộc.

.DESCRIPTION
    Chạy được nhiều lần (idempotent): `aws cloudformation deploy` tự tạo mới hoặc cập nhật,
    và bỏ qua stack không có thay đổi.

    Thứ tự bắt buộc, vì các stack sau Fn::ImportValue từ stack trước:
        pdftool-ecr             -> ECR repository
        pdftool-foundation      -> log group + 2 IAM role
        pdftool-cluster         -> ECS cluster (FARGATE_SPOT)
        pdftool-security-group  -> SG cho task, mở 80 từ mạng nội bộ
        pdftool-scaling         -> Lambda bật/tắt + alarm idle + Resolver query logging
        pdftool-pipeline        -> CodeBuild + CodePipeline

    KHÔNG có pdftool-service ở đây: stack đó do chính CodePipeline tạo ở stage Deploy, vì nó
    cần ImageTag của bản build đầu tiên. Pipeline tự chạy ngay sau khi được tạo.

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

    [ValidateSet('10', '15', '20', '25', '30', '60', '120')]
    [string]$IdleWindowMinutes = '30'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# AWS CLI trên Windows đọc file:// theo codepage hệ thống, không phải UTF-8. Thiếu biến này thì
# mọi template có tiếng Việt đều lỗi "text contents could not be decoded".
$env:AWS_CLI_FILE_ENCODING = 'UTF-8'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Deploy-Stack {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ParameterOverrides = @()
    )

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan

    $cliArgs = @(
        'cloudformation', 'deploy',
        '--stack-name', $Name,
        '--template-file', (Join-Path $here "$Name.yaml"),
        '--region', $Region,
        '--capabilities', 'CAPABILITY_NAMED_IAM',
        '--no-fail-on-empty-changeset',
        '--tags', 'Project=AevPdfTool', 'Environment=Prod'
    )
    if ($ParameterOverrides.Count -gt 0) {
        $cliArgs += '--parameter-overrides'
        $cliArgs += $ParameterOverrides
    }

    & aws @cliArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Stack $Name thất bại. Xem sự kiện: aws cloudformation describe-stack-events --stack-name $Name --max-items 20"
    }
    Write-Host "$Name OK" -ForegroundColor Green
}

Write-Host "Tài khoản đang dùng:" -ForegroundColor Yellow
& aws sts get-caller-identity --query 'Arn' --output text
if ($LASTEXITCODE -ne 0) { throw "Không gọi được STS. Session MFA hết hạn? Chạy: aws-mfa <mã 6 số>" }

Deploy-Stack -Name 'pdftool-ecr'
Deploy-Stack -Name 'pdftool-foundation'
Deploy-Stack -Name 'pdftool-cluster'
Deploy-Stack -Name 'pdftool-security-group' -ParameterOverrides @(
    "VpcId=$VpcId",
    "OperatorNetworkCidr=$OperatorNetworkCidr"
)
Deploy-Stack -Name 'pdftool-scaling' -ParameterOverrides @(
    "VpcId=$VpcId",
    "IdleWindowMinutes=$IdleWindowMinutes"
)
Deploy-Stack -Name 'pdftool-pipeline'

Write-Host ""
Write-Host "Xong phần hạ tầng." -ForegroundColor Green
Write-Host ""
Write-Host "CodePipeline tự chạy ngay sau khi được tạo. Lần chạy đầu mất khoảng 15-25 phút" -ForegroundColor Yellow
Write-Host "(npm ci + vite build + docs + 20 bản i18n), và chính nó tạo ra stack pdftool-service."
Write-Host ""
Write-Host "Theo dõi:"
Write-Host "  aws codepipeline get-pipeline-state --name pdftool-pipeline --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table"
Write-Host ""
Write-Host "Khi pipeline xong, CloudFormation tạo service ở desiredCount 1 và alarm idle sẽ đưa"
Write-Host "về 0 sau IdleWindowMinutes. Từ lần deploy sau, desiredCount không bị đụng tới nữa."
Write-Host ""
Write-Host "Bật tay không cần chờ chu kỳ DNS:"
Write-Host "  aws lambda invoke --function-name pdftool-scale-up --cli-binary-format raw-in-base64-out --payload '{}' out.json"
Write-Host ""
Write-Host "Rồi kiểm tra tên miền phân giải được từ trong VPC:"
Write-Host "  http://pdftool.internal.aquavietnam.vn"
