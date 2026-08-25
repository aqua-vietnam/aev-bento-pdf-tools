# Nâng cấp AEV PDF từ upstream BentoPDF

Tài liệu quy trình đồng bộ code mới từ upstream (`alam00000/bentopdf`) vào fork
`aev-custom` mà vẫn giữ branding AEV PDF. Thiết kế để **lần sau nâng cấp dễ hơn**:
phần lớn branding là config-driven + một script tái-brand idempotent.

## 1. Giá trị brand (single source of truth)

Mọi giá trị brand nằm ở **`branding.config.json`** (root). Sửa ở đó, KHÔNG sửa rải rác.

| Thuộc tính   | Giá trị hiện tại               |
| ------------ | ------------------------------ |
| Brand name   | `AEV PDF`                      |
| Domain       | `pdf-tools.aquavietnam.com.vn` |
| Twitter      | `@aquavietnam`                 |
| Logo         | `public/images/aqua-logo.png`  |
| GitHub links | đã gỡ khỏi navbar/footer       |

Branding được áp theo 3 cơ chế:

1. **Runtime config** (`.env` → `VITE_BRAND_NAME`, `VITE_BRAND_LOGO`, `VITE_FOOTER_TEXT`):
   navbar/footer/logo lấy từ đây qua Handlebars. Xem `.env.example`.
2. **Build-time domain** (`SITE_URL`): sitemap, canonical/hreflang, SEO audit.
   Set trong `nixpacks.toml [variables]` (deploy) và `.env.production` (local).
3. **Script tái-brand** (`scripts/apply-branding.mjs`): thay chuỗi brand/domain
   **hardcode** trong meta/SEO/structured-data của ~250 file HTML + locales, đồng
   thời **khôi phục** token hạ tầng upstream (npm `@bentopdf`, cloudflare worker)
   mà rebrand mù dễ làm hỏng.

## 2. Quy trình nâng cấp (chuẩn)

> **Dùng đúng Node 22.14.0** (`.nvmrc`). Node mới hơn sẽ làm test fail giả — xem mục 7.

```bash
# 0. Chốt Node version TRƯỚC khi làm gì khác
nvm use                                 # đọc .nvmrc -> 22.14.0
node -v                                 # phải in v22.14.0

# 1. Lấy code mới từ upstream
git fetch upstream
git checkout aev-custom
git merge upstream/main        # hoặc: git merge origin/main

# 2. Resolve conflict (xem mục 3). Với các trang src/pages/*.html chỉ khác branding:
#    git checkout --theirs -- <file>   (lấy bản upstream, script sẽ brand lại)
#    Nhớ: git add <file> sau khi resolve.

# 3. Chuẩn hóa branding (idempotent, an toàn chạy lại nhiều lần)
node scripts/apply-branding.mjs        # hoặc --dry-run để xem trước

# 4. Script sửa file trong working tree, KHÔNG tự stage.
#    Bỏ bước này = commit thiếu branding (xem mục 7).
git add -u

# 5. Script thay chuỗi làm lệch line-wrap -> phải format lại, nếu không
#    pre-commit hook (lint-staged) sẽ sửa file giữa lúc commit.
#    Loại 3 file dirty sẵn ở upstream ra (xem mục 7.2).
git diff --cached --name-only \
  | grep -E '\.(html|json|css|md|ts|js|mjs|cjs)$' \
  | grep -vxE 'README\.md|signatures/cla\.json|src/js/logic/scan-to-pdf\.ts' \
  | tr '\n' '\0' | xargs -0 npx prettier --write
git add -u

# 6. Verify
npm ci
cp .env.example .env.production         # đảm bảo SITE_URL đúng
npm run build                           # phải PASS, SEO audit clean
npm run test:run                        # phải PASS

# 7. Commit & push (KHÔNG dùng --no-verify)
git commit
git push origin aev-custom
```

## 3. Xử lý conflict theo loại file

| Loại                       | File                                                                        | Cách resolve                                                                                         |
| -------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Trang SEO/meta             | `src/pages/*.html`, root `*.html`                                           | `--theirs` (lấy upstream) → `apply-branding.mjs` brand lại                                           |
| UI thủ công                | `src/partials/navbar.html`, `footer.html`, `*-simple`, `src/css/styles.css` | Reconcile tay: giữ thiết kế AEV (theme sáng, đã gỡ nav/github), nhận thay đổi chức năng của upstream |
| Locales                    | `public/locales/**/*.json`                                                  | `--theirs` → `apply-branding.mjs` brand lại                                                          |
| Build scripts, docs, infra | `scripts/`, `docs/`, `.github/`, `Dockerfile*`, `chart/`, `cloudflare/`     | `--theirs` (giữ upstream sạch — KHÔNG brand, tránh phá lệnh/hạ tầng thật)                            |
| Config fork                | `vite.config.ts`, `package.json`, `.env.example`, `nixpacks.toml`           | Reconcile tay, giữ phần custom (port 5557, loadEnv, engines, SITE_URL...)                            |

## 4. Token PHẢI giữ nguyên (KHÔNG brand)

Đây là tham chiếu hạ tầng upstream thật — đổi = vỡ tính năng:

- `@bentopdf/pymupdf-wasm`, `@bentopdf/gs-wasm` (npm package WASM trên jsdelivr)
- `bentopdf.workers.dev`, `bentopdf-cors-proxy` (cloudflare worker)
- `bentopdf-pymupdf-wasm`, `bentopdf-airgap-bundle` (tên bundle airgap)

`apply-branding.mjs` đã **case-sensitive** để chỉ đổi `BentoPDF`/`@BentoPDF`/`bentopdf.com`
mà không đụng `@bentopdf` (npm, chữ thường). Danh sách bảo vệ: `branding.config.json → upstream.preserveTokens`.

## 5. Đổi giá trị brand trong tương lai

1. Sửa `branding.config.json` (brand/domain/social/logo).
2. Cập nhật tương ứng: `.env.example` (`VITE_BRAND_*`, `SITE_URL`) và `nixpacks.toml` (`SITE_URL`).
3. Chạy `node scripts/apply-branding.mjs`.
4. `npm run build && npm run test:run`.

> Lưu ý: `apply-branding.mjs` hiện thay từ token upstream/cũ → giá trị mới. Nếu đổi
> brand sang giá trị KHÁC "AEV PDF", cập nhật bảng `rules` trong script cho phù hợp,
> hoặc chạy trên cây đã ở trạng thái upstream (sau `--theirs`) để brand từ đầu.

## 6. Checklist verify trước khi push

- [ ] `node -v` = `v22.14.0`
- [ ] `npm run build` PASS, log "SEO audit: ... passed, sitemap clean"
- [ ] Sitemap/canonical hiện `pdf-tools.aquavietnam.com.vn` (không `bentopdf.com`)
- [ ] `npm run test:run` PASS
- [ ] `git grep -nE "AEV-PDF\.com|@AEV-PDF/|AEV-PDF\.workers"` → rỗng
- [ ] `git grep -n "cdn.jsdelivr.net/npm/@bentopdf"` → còn (WASM không vỡ)
- [ ] `node scripts/apply-branding.mjs` báo "0 file đổi" (idempotent)
- [ ] `git diff HEAD` → rỗng (commit khớp working tree, không sót thay đổi chưa stage)
- [ ] `git grep -n "BentoPDF" -- '*.html' 'public/locales/**' 'src/js/**'` → rỗng
- [ ] `git diff origin/aev-custom HEAD --stat -- src/partials/ src/css/styles.css .env.example`
      → rỗng (UI custom không bị merge đụng)

Verify deploy thật (khuyến nghị, bắt được lỗi build-arg mà `npm run build` không bắt):

```bash
docker compose build && docker compose up -d
curl -s localhost:5557/ | grep -c 'BentoPDF'        # phải là 0
curl -s localhost:5557/ | grep -o '<link rel="canonical"[^>]*>'
docker compose down
```

## 7. Ba cái bẫy đã mắc (đọc trước khi làm)

**7.1. `apply-branding.mjs` không tự `git add`.** Script sửa working tree. Nếu merge
xong bạn `git add` các file conflict rồi mới chạy script, thì thay đổi branding trên
**mọi** file (kể cả file tự auto-merge như `about.html`) sẽ nằm ngoài index. `git commit`
lúc đó tạo commit **vẫn còn chữ "BentoPDF"** dù working tree đã đúng, và `npm run build`
chạy trên working tree nên vẫn PASS — không có gì báo lỗi. Luôn `git add -u` sau script,
và check `git diff HEAD` phải rỗng.

**7.2. `apply-branding.mjs` làm lệch prettier.** Đổi `BentoPDF` → `AEV PDF` thay đổi độ
dài dòng nên prettier muốn wrap lại (~89 file). Bỏ qua thì pre-commit hook `lint-staged`
sẽ sửa file ngay giữa lúc commit. **Đừng** format 3 file đang dirty sẵn ở upstream —
`README.md`, `signatures/cla.json`, `src/js/logic/scan-to-pdf.ts` — format chúng tạo
divergence gây conflict ở mọi lần merge sau. Kiểm tra bằng cách chạy `prettier --check`
trên cây `origin/main` trước khi quyết định.

**7.3. Node mới hơn 22.14.0 làm 12 test fail giả.** Từ Node 24+ có global `localStorage`
che mất `localStorage` của jsdom, gây `TypeError: Cannot read properties of undefined
(reading 'clear')` ở `src/tests/i18n.test.ts` và `src/tests/xss-replay.test.ts`. Không
phải lỗi merge. `nvm use` trước khi test. (`Dockerfile` builder dùng `node:20-alpine`
trong khi `package.json` engines yêu cầu `>=22.12.0` — chỉ là warning `EBADENGINE` vì
không có `.npmrc`/`engine-strict`, build vẫn PASS. Không sửa `Dockerfile` vì nó thuộc
upstream.)
