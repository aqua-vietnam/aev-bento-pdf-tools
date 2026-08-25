# AEV PDF Tool trên AWS ECS — CI/CD và scale-to-zero

Triển khai fork này lên ECS Fargate trong VPC `aqua-production`, phục vụ tại
**http://pdftool.internal.aquavietnam.vn** (chỉ trong mạng nội bộ, qua Site-to-Site VPN).

---

## 1. Tài nguyên: cái gì dùng lại, cái gì tạo mới

Đã rà soát tài khoản `474082330515` trước khi thiết kế để không dựng trùng.

### Dùng lại (không tạo mới)

| Tài nguyên | Định danh | Ghi chú |
|---|---|---|
| Cloud Map namespace | `internal.aquavietnam.vn` (`ns-ox4hvwgzwledegxh`) | Đã có, dùng chung với `adms`, `adms-console`, `smtp-relay-blue` |
| Private hosted zone | `Z04248794JU73UK411J4` | Cloud Map tự quản, chỉ gắn `vpc-02a4ec6a8e5959339` |
| VPC + subnet | `vpc-02a4ec6a8e5959339`, `subnet-0c0cbd6ec131f44d0`, `subnet-0da3b3f0179bc907c` | Đúng subnet `adms-console` đang dùng |
| NAT gateway | `nat-0cfb2b0c036e4ec93` | Đường ra cho task kéo image ECR |
| GitHub connection | `aquavn-github` (`59427c0a-…`) | Đang AVAILABLE, cùng org `aqua-vietnam` |

### Tạo mới

| Stack | Tạo ra |
|---|---|
| `pdftool-ecr` | ECR repo `pdftool-ecr-repo` (IMMUTABLE, giữ 10 image) |
| `pdftool-foundation` | Log group `/ecs/pdftool`, `pdftool-execution-role`, `pdftool-task-role` |
| `pdftool-cluster` | ECS cluster `pdftool-cluster` (100% FARGATE_SPOT) |
| `pdftool-security-group` | `pdftool-task-sg` — mở TCP 80 từ `10.0.0.0/8` |
| `pdftool-scaling` | 2 Lambda bật/tắt, alarm idle, Resolver query logging |
| `pdftool-pipeline` | S3 artifact bucket, CodeBuild `pdftool-build`, CodePipeline `pdftool-pipeline` |
| `pdftool-service` | Task definition, Cloud Map service `pdftool`, ECS service — **do pipeline tạo** |

**Không đụng vào** `aev-prod-pipeline` / `aev-prod-build`: pipeline đó có Source trỏ repo khác
(`aqv-ew/AQVEW`, nhánh `prod`) và deploy vào `aev-prod-vpc`. Một CodePipeline chỉ có một Source.

---

## 2. Luồng CI/CD

```
git push origin aev-custom
        │
        ▼
CodePipeline "pdftool-pipeline"
  Source  ── CodeStar connection aquavn-github, nhánh aev-custom
  Build   ── CodeBuild "pdftool-build" (deploy/aws/buildspec.yml)
  │           1. docker build -f Dockerfile          → nginx nghe 8080, branding AEV
  │           2. docker build -f Dockerfile.port80   → đổi sang nghe 80
  │           3. push ECR với tag = git short sha
  │           4. ghi build.json {"ImageTag": "…"}
  ▼
  Deploy  ── CloudFormation CREATE_UPDATE stack "pdftool-service"
              ImageTag lấy từ build.json qua Fn::GetParam
```

Deploy bằng CloudFormation, không phải action ECS, vì task definition do CloudFormation quản lý.
Nếu để CodePipeline tự đăng ký revision ngoài CloudFormation thì mỗi lần ai đó cập nhật stack
(đổi CPU, đổi subnet…) service sẽ tụt về image cũ ghi trong tham số stack.

**Deploy KHÔNG làm thay đổi `desiredCount`.** `pdftool-service.yaml` cố ý không khai báo thuộc
tính đó, nên CloudFormation không đụng vào — deploy lúc service đang ngủ thì nó vẫn ngủ (và sẽ
chạy image mới ở lần bật kế tiếp), deploy lúc đang chạy thì nó rolling-update tại chỗ.

---

## 3. Scale-to-zero

### Chiều tắt

nginx ghi access log ra stdout → `/ecs/pdftool` → metric filter đếm số dòng →
alarm `pdftool-idle` kêu khi **30 phút** liên tiếp không có dòng nào → EventBridge →
`pdftool-scale-down` đặt `desiredCount=0`.

Metric filter đếm **mọi** dòng log chứ không chỉ dòng access, có chủ đích: nginx in vài dòng lúc
khởi động, nhờ đó alarm về `OK` mỗi khi task lên. Nếu chỉ đếm dòng access thì một task được đánh
thức mà người dùng không quay lại sẽ giữ alarm ở `ALARM` liên tục, không có chuyển trạng thái nào
để EventBridge bắt, và service chạy mãi không ai tắt.

### Chiều bật — bằng chính truy vấn DNS

Khi service ở 0 task, Cloud Map gỡ bản ghi A. Trình duyệt tra
`pdftool.internal.aquavietnam.vn` → NXDOMAIN → trang báo lỗi. **Nhưng** truy vấn đó đã được
Route 53 Resolver query logging ghi lại; một subscription filter khớp tên miền đẩy thẳng sang
`pdftool-scale-up`, hàm này đặt `desiredCount=1`.

```
Người dùng mở URL
   → DNS query (thất bại, NXDOMAIN)
   → Resolver query log  ~1-3 phút
   → subscription filter → Lambda → desiredCount=1
   → Fargate kéo image + khởi động  ~40-60 giây
   → F5 lại là vào được
```

### Đánh đổi phải nói rõ với người dùng

**Lần truy cập đầu tiên sau khi ngủ luôn thất bại**, phải chờ khoảng **2–4 phút** rồi F5. Không
có cách nào tránh được nếu không có thứ gì chạy sẵn để đón request — mà thứ đó (ALB nội bộ,
~18 USD/tháng) đắt hơn chính tiền chạy task 24/7.

Nếu độ trễ này gây khó chịu, **đừng dựng ALB** — bật lịch hâm nóng đầu ngày:

```powershell
aws cloudformation deploy --stack-name pdftool-scaling `
  --template-file deploy/aws/pdftool-scaling.yaml `
  --capabilities CAPABILITY_NAMED_IAM `
  --parameter-overrides VpcId=vpc-02a4ec6a8e5959339 WakeUpScheduleState=ENABLED
```

Service sẽ sẵn sàng lúc 07:30 các ngày trong tuần.

---

## 4. Chi phí

| Khoản | Ước tính / tháng |
|---|---|
| Fargate Spot 0.25 vCPU / 0.5 GB, dùng ~4h/ngày | ~0,4 USD |
| — nếu chạy 24/7 để so sánh | ~3,1 USD |
| ECR storage (10 image) | ~0,5 USD |
| CloudWatch Logs (Resolver query log, giữ 1 ngày) | ~0,3–1 USD |
| Lambda + EventBridge | trong free tier |
| CodeBuild MEDIUM, ~20 phút/lần build | ~0,2 USD mỗi lần deploy |

Nói thẳng: scale-to-zero ở đây tiết kiệm khoảng **2–3 USD/tháng**, và một phần bị Resolver query
log ăn lại. Giá trị thật của nó không nằm ở con số đó mà ở chỗ không có tài nguyên nào chạy
không công. Nếu muốn đơn giản hơn, giữ task 24/7 rồi xoá stack `pdftool-scaling` cũng là lựa
chọn hợp lý.

---

## 5. Vận hành

```powershell
# Bật ngay, không chờ chu kỳ DNS
aws lambda invoke --function-name pdftool-scale-up --cli-binary-format raw-in-base64-out --payload '{}' out.json

# Tắt ngay
aws lambda invoke --function-name pdftool-scale-down --cli-binary-format raw-in-base64-out --payload '{}' out.json

# Đang chạy mấy task, image nào
aws ecs describe-services --cluster pdftool-cluster --services pdftool `
  --query 'services[0].{desired:desiredCount,running:runningCount,taskdef:taskDefinition}'

# Log của container
aws logs tail /ecs/pdftool --follow

# Trạng thái pipeline
aws codepipeline get-pipeline-state --name pdftool-pipeline `
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table

# Rollback về một commit cũ: deploy lại stack service với tag cũ (image còn trong ECR 10 bản)
aws cloudformation deploy --stack-name pdftool-service `
  --template-file deploy/aws/pdftool-service.yaml `
  --parameter-overrides ImageTag=<git-short-sha-cu>
```

---

## 6. Những cái bẫy đã gặp, đừng mắc lại

- **`AWS_CLI_FILE_ENCODING=UTF-8`** — AWS CLI trên Windows đọc `file://` theo codepage hệ thống.
  Thiếu biến này thì mọi template có tiếng Việt đều lỗi
  `text contents could not be decoded`. `bootstrap.ps1` đã tự đặt.
- **VPC là bắt buộc, không phải tuỳ chọn.** Private hosted zone của namespace chỉ gắn
  `vpc-02a4ec6a8e5959339`. Đặt task ở `aev-prod-vpc` thì tên miền không phân giải được.
- **Không sửa `nginx.conf` ở gốc repo.** Đó là file của upstream; mọi thay đổi trong đó là một
  xung đột merge mỗi lần sync theo quy trình `aev-upgrade`. Việc đổi cổng nằm ở
  `deploy/aws/Dockerfile.port80` — file mới hoàn toàn của AEV.
- **`net.ipv4.ip_unprivileged_port_start = 0`** trong task definition là thứ cho phép uid 101
  bind cổng 80 mà không cần chạy root. Bỏ dòng đó là container chết ngay với
  `bind() to 0.0.0.0:80 failed (13: Permission denied)`.
- **ECR repo IMMUTABLE** → không có tag `latest`, và push lại cùng tag sẽ lỗi. Buildspec đã bỏ
  qua bước build khi tag đã tồn tại.
- **Mỗi VPC chỉ gắn được một Resolver query-log config.** Hiện `aqua-production` chưa có cái nào.
  Nếu sau này có công cụ khác bật DNS logging toàn VPC, `pdftool-scaling` sẽ xung đột và phải
  dùng chung config đó.
