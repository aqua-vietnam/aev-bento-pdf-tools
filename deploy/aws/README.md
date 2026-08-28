# AEV PDF Tool trên AWS ECS — CI/CD và lịch bật/tắt

Triển khai fork này lên ECS Fargate trong VPC `aqua-production`, phục vụ tại
**http://pdftool.internal.aquavietnam.vn** (chỉ trong mạng nội bộ, qua Site-to-Site VPN).

Toàn bộ hạ tầng nằm trong **2 stack CloudFormation**, và chỉ **1 stack** phải deploy bằng tay.

---

## 1. Hai stack, không phải bảy

Bản đầu tiên chia thành 7 stack: `pdftool-ecr`, `-foundation`, `-cluster`, `-security-group`,
`-scaling`, `-pipeline`, `-service`. Bảy stack cho một site tĩnh nội bộ nghĩa là bảy lệnh deploy
theo đúng thứ tự, năm chuỗi `Fn::ImportValue` phải giữ khớp nhau, và không sửa được một rule
security group nếu chưa nhớ ra stack nào đang giữ nó. Tất cả những thứ đó có chung một vòng
đời: tạo một lần rồi gần như không đụng tới.

| Stack | Chứa gì | Ai deploy |
|---|---|---|
| `pdftool-platform` | ECR repo, log group `/ecs/pdftool`, `pdftool-execution-role`, `pdftool-task-role`, ECS cluster, `pdftool-task-sg`, S3 artifact bucket, CodeBuild, CodePipeline | `bootstrap.ps1`, một lần |
| `pdftool-service` | Task definition, Cloud Map service, ECS service, lịch bật/tắt (Application Auto Scaling) | CodePipeline, mỗi lần push |

**Vì sao không gom nốt thành 1:** `pdftool-service` nhận `ImageTag` của bản build làm tham số và
bị chính pipeline cập nhật mỗi lần deploy. Một stack không tự update chính nó được, nên pipeline
bắt buộc phải nằm ngoài stack mà nó deploy. Hai là con số nhỏ nhất khả thi.

### Template viết bằng tiếng Anh

Cả hai file `.yaml` giờ thuần ASCII. Lý do không chỉ là quy ước: AWS CLI trên Windows đọc
`file://` theo codepage hệ thống, nên template có ký tự ngoài ASCII sẽ lỗi
`text contents could not be decoded` nếu thiếu `AWS_CLI_FILE_ENCODING=UTF-8`. Giữ template ASCII
là bỏ hẳn cái bẫy đó. Tài liệu cho người (chính file này) vẫn tiếng Việt.

### Dùng lại, không tạo mới

| Tài nguyên | Định danh | Ghi chú |
|---|---|---|
| Cloud Map namespace | `internal.aquavietnam.vn` (`ns-ox4hvwgzwledegxh`) | Dùng chung với `adms`, `adms-console`, `smtp-relay-blue` |
| Private hosted zone | `Z04248794JU73UK411J4` | Cloud Map tự quản, chỉ gắn `vpc-02a4ec6a8e5959339` |
| VPC + subnet | `vpc-02a4ec6a8e5959339`, `subnet-0c0cbd6ec131f44d0`, `subnet-0da3b3f0179bc907c` | Đúng subnet `adms-console` đang dùng |
| NAT gateway | `nat-0cfb2b0c036e4ec93` | Đường ra cho task kéo image ECR |
| GitHub connection | `aquavn-github` (`59427c0a-…`) | Đang AVAILABLE, cùng org `aqua-vietnam` |

**Không đụng vào** `aev-prod-pipeline` / `aev-prod-build`: pipeline đó có Source trỏ repo khác
(`aqv-ew/AQVEW`, nhánh `prod`) và deploy vào `aev-prod-vpc`. Một CodePipeline chỉ có một Source.

---

## 2. Luồng CI/CD

```
git push origin aev-custom
        │
        ▼
CodePipeline "pdftool-pipeline"          (trong stack pdftool-platform)
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

Stage Deploy chỉ truyền `ImageTag`, nên **mọi tham số khác quay về default ghi trong template**,
không phải giá trị của lần deploy trước. Muốn đổi CPU/RAM/subnet/giờ chạy lâu dài thì sửa default
trong `pdftool-service.yaml` rồi commit, đừng chỉ chạy `--parameter-overrides` một lần bằng CLI —
lần push kế tiếp sẽ xoá thay đổi đó.

---

## 3. Lịch bật/tắt — thay cho scale-to-zero

### Đã bỏ cái gì và vì sao

Bản trước tự tắt sau 30 phút không ai dùng, và tự bật khi có truy vấn DNS tới tên miền nội bộ.
Nó chạy đúng, và số đo cũng rõ ràng: **lần truy cập đầu tiên sau khi ngủ LUÔN thất bại**, người
dùng phải chờ ~2 phút (23 giây cho Lambda + ~90 giây Fargate kéo image) rồi F5. Với một công cụ
người ta bấm vào giữa lúc đang làm việc khác, đó là cái giá quá đắt cho khoản tiết kiệm vài USD.

Bỏ theo đó: 2 Lambda, alarm idle, metric filter, Route 53 Resolver query logging (khoản tốn kém
nhất của cơ chế cũ), Lambda Function URL, và Cloudflare wake worker (`deploy/cloudflare/`).
Đây cũng là lý do chính khiến 7 stack gom lại được thành 2.

### Cái gì thay thế

Một thời khoá biểu cố định. Trong giờ chạy, service luôn sẵn sàng — không ai phải chờ.
Ngoài giờ, không có gì chạy và không tính tiền.

| | Mặc định |
|---|---|
| Bật | `cron(0 7 ? * * *)` — 07:00 |
| Tắt | `cron(0 20 ? * * *)` — 20:00 |
| Múi giờ | `Asia/Ho_Chi_Minh` |

**Mặc định là mọi ngày, không phải MON-FRI.** Cơ chế cũ có đường đánh thức theo nhu cầu nên
lịch chỉ là bổ trợ; giờ thì không còn đường nào cả — đặt `MON-FRI` nghĩa là thứ Bảy site chết
hẳn, không cứu được trừ khi có người chạy lệnh AWS CLI. Nếu chắc chắn không ai dùng cuối tuần
thì thu hẹp lại để tiết kiệm thêm, nhưng đó là một quyết định có hậu quả, không phải mặc định.

Hiện thực bằng **Application Auto Scaling scheduled action**, không phải Lambda + EventBridge như
bản cũ: hai dòng cron khai báo trên một scalable target là xong. Không có code hàm, không IAM
role riêng, không log group, không có gì để mục ruỗng theo thời gian.

### Ai sở hữu `desiredCount`

Scalable target, và chỉ nó. Vì thế `pdftool-service.yaml` **cố ý không khai báo `DesiredCount`**
trên ECS service. Hành vi đã kiểm chứng bằng thực nghiệm ngày 2026-08-26, không phải suy đoán từ
tài liệu:

- Lúc **CREATE**, CloudFormation dùng 1 (không phải 0 như mặc định của ECS API) — nên ngay sau
  lần chạy pipeline đầu tiên đã có task chạy.
- Lúc **UPDATE**, CloudFormation **không đụng vào** `desiredCount`. Đã thử: đưa service về 0,
  update stack đổi `TaskMemory` → task definition lên revision mới mà `desiredCount` vẫn nguyên 0.

Tính chất thứ hai là thứ khiến deploy an toàn ở bất kỳ giờ nào: push lúc 22:00 chỉ đăng ký task
definition mới và để service nằm im ở 0; sáng hôm sau lịch bật lên với image mới.

Tương tự với chính scalable target: CloudFormation áp lại `MinCapacity`/`MaxCapacity` mỗi lần
deploy, nhưng không giá trị nào tự ép thay đổi (hạ minimum không scale-in, nâng maximum không
scale-out). Deploy giữa trưa để service đang chạy vẫn chạy; deploy nửa đêm để service đang tắt
vẫn tắt.

### Đổi giờ, hoặc tắt hẳn lịch

Sửa default trong `pdftool-service.yaml` rồi commit (xem lưu ý ở mục 2). Muốn thử nhanh một lần:

```powershell
# Đổi khung giờ
aws cloudformation deploy --stack-name pdftool-service `
  --template-file deploy/aws/pdftool-service.yaml `
  --parameter-overrides ImageTag=<tag-dang-chay> `
    "ScaleUpSchedule=cron(30 6 ? * MON-SAT *)" "ScaleDownSchedule=cron(0 21 ? * MON-SAT *)"

# Bỏ lịch, chạy 24/7
aws cloudformation deploy --stack-name pdftool-service `
  --template-file deploy/aws/pdftool-service.yaml `
  --parameter-overrides ImageTag=<tag-dang-chay> ScheduleState=DISABLED
```

`ScheduleState=DISABLED` gỡ hai scheduled action và ghim scalable target ở `TaskCount`, tức là
chạy liên tục.

### Bật tay ngoài giờ

```powershell
aws ecs update-service --cluster pdftool-cluster --service pdftool --desired-count 1
```

Chạy được vì `MinCapacity` của scalable target là 0 (chỉ là sàn, không phải mục tiêu) và
`MaxCapacity` là 1. Task lên sau ~90 giây và ở đó cho tới lần scheduled action kế tiếp.

---

## 4. Chi phí

Ước tính cho `ap-southeast-1`, 0.25 vCPU / 0.5 GB, Fargate on-demand:

| Khoản | Ước tính / tháng |
|---|---|
| Fargate on-demand, lịch 07:00–20:00 mọi ngày (~395 h) | ~6 USD |
| — nếu `ScheduleState=DISABLED` (24/7, 730 h) | ~11 USD |
| — nếu đổi sang `CapacityProvider=FARGATE_SPOT` | rẻ hơn ~70%, nhưng xem cảnh báo dưới |
| ECR storage (10 image) | ~0,2 USD |
| CloudWatch Logs (`/ecs/pdftool`, giữ 14 ngày) | dưới 0,5 USD |
| CodeBuild MEDIUM, ~20 phút/lần build | ~0,2 USD mỗi lần deploy |

So với bản cũ: scale-to-zero từng đưa Fargate xuống dưới 1 USD, nhưng Route 53 Resolver query log
(ghi **mọi** truy vấn DNS trong VPC, không lọc được ở nguồn) ăn lại 0,3–1 USD. Chênh lệch thật
giữa hai kiến trúc chỉ khoảng 4–5 USD/tháng, đổi lấy việc mỗi lần vào site đều hỏng ở lần bấm đầu.

**Về `FARGATE_SPOT`:** rẻ hơn nhiều nhưng AWS thu hồi task với 2 phút báo trước, và trên service
1 task đó là ~90 giây gián đoạn vào một thời điểm không đoán trước — đúng kiểu chờ mà cả thiết kế
này sinh ra để tránh. Chỉ chọn Spot nếu đồng thời nâng `TaskCount` lên 2 trở lên.

---

## 5. Vận hành

```powershell
# Đang chạy mấy task, image nào
aws ecs describe-services --cluster pdftool-cluster --services pdftool `
  --query 'services[0].{desired:desiredCount,running:runningCount,taskdef:taskDefinition}'

# Lịch hiện hành
aws application-autoscaling describe-scheduled-actions --service-namespace ecs `
  --resource-id service/pdftool-cluster/pdftool `
  --query 'ScheduledActions[].{name:ScheduledActionName,cron:Schedule,tz:Timezone,min:ScalableTargetAction.MinCapacity,max:ScalableTargetAction.MaxCapacity}' `
  --output table

# Bật ngay ngoài giờ / tắt ngay
aws ecs update-service --cluster pdftool-cluster --service pdftool --desired-count 1
aws ecs update-service --cluster pdftool-cluster --service pdftool --desired-count 0

# Log của container
aws logs tail /ecs/pdftool --follow

# Trạng thái pipeline
aws codepipeline get-pipeline-state --name pdftool-pipeline `
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table

# Rollback về một commit cũ: deploy lại stack service với tag cũ (ECR giữ 10 bản)
aws cloudformation deploy --stack-name pdftool-service `
  --template-file deploy/aws/pdftool-service.yaml `
  --parameter-overrides ImageTag=<git-short-sha-cu>
```

---

## 6. Chuyển từ kiến trúc 7 stack sang 2 stack

Không update tại chỗ được: gần như mọi tài nguyên đều có tên cố định (`pdftool-execution-role`,
`pdftool-task-sg`, cluster `pdftool-cluster`, ECR repo…). Stack mới tạo lại đúng những cái tên đó
và CloudFormation sẽ báo `already exists` khi stack cũ còn giữ chúng.

```powershell
cd deploy\aws

# 1. Xem trước sẽ xoá những gì
.\teardown-legacy-stacks.ps1 -WhatIf

# 2. Xoá thật (hỏi xác nhận)
.\teardown-legacy-stacks.ps1

# 3. Dựng lại
.\bootstrap.ps1
```

Script teardown làm ba việc CloudFormation không tự làm được: đưa ECS service về 0 trước khi xoá
(nếu không bước xoá treo rất lâu), dọn sạch S3 artifact bucket (bucket còn object thì
`DELETE_FAILED`), và xoá ECR repo `pdftool-ecr-repo` + log group `/ecs/pdftool` — hai thứ có
`DeletionPolicy: Retain` nên sống sót sau khi stack biến mất rồi va tên với stack mới.

**Mất gì:** toàn bộ image trong ECR (pipeline build lại), log container cũ, và site ngừng phục vụ
cho tới khi pipeline chạy xong (~15–25 phút).

---

## 7. Những cái bẫy đã gặp, đừng mắc lại

- **Template phải thuần ASCII.** AWS CLI trên Windows đọc `file://` theo codepage hệ thống. Thêm
  một dòng tiếng Việt vào `.yaml` là lỗi `text contents could not be decoded` quay lại ngay —
  trừ khi nhớ đặt `AWS_CLI_FILE_ENCODING=UTF-8` (hai script `.ps1` đã tự đặt).
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
- **Đừng khai báo `DesiredCount` trên ECS service.** Scalable target sở hữu con số đó. Khai báo
  cả hai nơi là mỗi lần deploy CloudFormation lại kéo service về `DesiredCount` của template,
  ghi đè lịch — và triệu chứng chỉ hiện ra khi deploy trúng lúc ngoài giờ.
- **`CfnDeployRole` giữ `iam:CreateServiceLinkedRole` dù hiện không cần.** Scalable target ECS
  đầu tiên trong một tài khoản tạo ra `AWSServiceRoleForApplicationAutoScaling_ECSService`. Trong
  `474082330515` role đó đã có sẵn (`aev-prod-ecs-service-adminsite`, `-api`, `-chat-service` và
  `ad-manager-service` đều đang dùng auto scaling), nên câu lệnh đó là no-op. Giữ lại để template
  còn chạy được ở tài khoản trắng, thay vì hỏng ngay deploy đầu tiên với `AccessDenied` ở một lời
  gọi không ai ngờ tới.
- **Health check không còn ràng buộc với gì cả.** Ở bản cũ, `wget` vào `127.0.0.1` mỗi 30 giây
  tự sinh access log và làm hỏng tín hiệu idle — phải lọc `-"127.0.0.1"` ở metric filter. Lịch
  không đọc log, nên giờ health check chỉ là health check, sửa thoải mái.
