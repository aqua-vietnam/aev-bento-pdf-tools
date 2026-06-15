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

```bash
# 1. Lấy code mới từ upstream
git fetch upstream
git checkout aev-custom
git merge upstream/main        # hoặc: git merge origin/main

# 2. Resolve conflict (xem mục 3). Với các trang src/pages/*.html chỉ khác branding:
#    git checkout --theirs -- <file>   (lấy bản upstream, script sẽ brand lại)

# 3. Chuẩn hóa branding (idempotent, an toàn chạy lại nhiều lần)
node scripts/apply-branding.mjs        # hoặc --dry-run để xem trước

# 4. Verify
npm ci
cp .env.example .env.production         # đảm bảo SITE_URL đúng
npm run build                           # phải PASS, SEO audit clean
npm run test:run                        # phải PASS

# 5. Commit & push
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

- [ ] `npm run build` PASS, log "SEO audit: ... passed, sitemap clean"
- [ ] Sitemap/canonical hiện `pdf-tools.aquavietnam.com.vn` (không `bentopdf.com`)
- [ ] `npm run test:run` PASS
- [ ] `git grep -nE "AEV-PDF\.com|@AEV-PDF/|AEV-PDF\.workers"` → rỗng
- [ ] `git grep -n "cdn.jsdelivr.net/npm/@bentopdf"` → còn (WASM không vỡ)
- [ ] `node scripts/apply-branding.mjs` báo "0 file đổi" (idempotent)
