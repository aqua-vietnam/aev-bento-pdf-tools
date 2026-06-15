# Thiết kế: Đồng bộ `main` → `aev-custom` + chuẩn hóa branding (AEV PDF)

Ngày: 2026-06-15
Trạng thái: Chờ user review

## 1. Mục tiêu

1. Đưa các cập nhật mới của upstream `main` (tool, feature, i18n, bugfix) vào branch `aev-custom`.
2. Giữ + **sửa đúng** các customization của fork: tên thương hiệu, domain, UI, logo, file deploy.
3. **Thiết kế để các lần nâng cấp sau dễ hơn**: tối đa hóa config-driven, có script tái-brand tái sử dụng, có tài liệu quy trình.

## 2. Giá trị brand chốt (single source of truth)

| Thuộc tính | Giá trị |
|---|---|
| Brand name (hiển thị) | `AEV PDF` |
| Domain | `pdf-tools.aquavietnam.com.vn` (không có `www.`) |
| Twitter handle | `@aquavietnam` |
| Logo | `aqua-logo.png` (file đã có trong `public/images/`) |
| Footer text | `© 2026 AEV PDF. All rights reserved.` |
| GitHub links | **Gỡ bỏ** (navbar/footer + nút star) |

## 3. Vấn đề của branch `aev-custom` hiện tại (PHẢI sửa)

Branch hiện tại được tạo bằng find-replace mù `bentopdf`→`AEV-PDF`, làm hỏng các tham chiếu **không phải brand**:

| Bị hỏng | Hiện tại (sai) | Phải là |
|---|---|---|
| NPM scope WASM | `@AEV-PDF/pymupdf-wasm`, `@AEV-PDF/gs-wasm` | `@bentopdf/...` (package thật → đổi = vỡ tính năng PDF) |
| Cloudflare worker | `AEV-PDF.workers.dev`, `AEV-PDF-cors-proxy` | `bentopdf.workers.dev`, `bentopdf-cors-proxy` |
| Domain | `www.AEV-PDF.com` | `pdf-tools.aquavietnam.com.vn` |
| GitHub repo | `alam00000/AEV-PDF` | (gỡ link) |
| Logo config lệch | `.env` ghi `aev-logo.png` ≠ file `aqua-logo.png` | thống nhất `aqua-logo.png` |

## 4. Phân loại customization & cách xử lý

| Nhóm | File | Cách xử lý |
|---|---|---|
| A. Config-driven | `.env.example` (VITE_BRAND_NAME/LOGO/FOOTER_TEXT) | Set giá trị đúng; là nguồn brand runtime của navbar/footer |
| B. UI thủ công | `navbar.html`, `navbar-simple.html`, `footer.html`, `footer-simple.html`, `src/css/styles.css` | Git 3-way merge tự hòa giải; resolve tay phần xung đột; giữ design custom (theme sáng, gỡ nav links/github) |
| C. SEO/meta hardcode | ~150 trang `src/pages/*.html` + html gốc + `public/site.webmanifest`, `robots.txt`, sitemap | **Script `apply-branding.mjs`** xử lý đồng loạt, idempotent, case-safe |
| D. File deploy | `.nvmrc`, `.node-version`, `nixpacks.toml`, `package.json` engines, `vite.config.ts` (port + loadEnv) | Giữ nguyên từ aev-custom (merge mang sang) |

## 5. Single source of truth: `branding.config.json`

File mới ở root, là nguồn duy nhất cho mọi giá trị brand. Cả script lẫn `.env` đều bám theo file này.

```jsonc
{
  "brandName": "AEV PDF",
  "domain": "pdf-tools.aquavietnam.com.vn",
  "twitterHandle": "@aquavietnam",
  "logo": "aqua-logo.png",
  "footerText": "© 2026 AEV PDF. All rights reserved.",
  "removeGithubLinks": true,
  "upstream": {
    "brandNames": ["BentoPDF", "Bento PDF"],
    "domains": ["www.bentopdf.com", "bentopdf.com"],
    "twitterHandle": "@BentoPDF",
    "githubRepo": "alam00000/bentopdf"
  },
  "preserveTokens": ["@bentopdf", "bentopdf.workers.dev", "bentopdf-cors", "cdn.jsdelivr.net/npm/@bentopdf"]
}
```

## 6. Script `scripts/apply-branding.mjs`

Quét file web-facing và thay theo thứ tự an toàn (case-sensitive):

1. Bảo vệ `preserveTokens` (npm scope, worker, cdn) — không bao giờ đụng.
2. `www.bentopdf.com` → domain → `bentopdf.com` → domain.
3. `@BentoPDF` → `@aquavietnam` (case-sensitive, không trùng `@bentopdf` npm).
4. `Bento PDF` → `AEV PDF`; `BentoPDF` → `AEV PDF`.
5. GitHub: gỡ block link trong template (xử lý ở nhóm B), trong text giữ nguyên/hoặc bỏ link.

**Phạm vi quét (mặc định):** `index.html`, `*.html` root, `src/pages/**/*.html`, `src/partials/**/*.html`, `public/site.webmanifest`, `public/robots.txt`, structured-data trong HTML.
**KHÔNG quét mặc định:** `docs/**`, `README.md`, `.github/**`, `Dockerfile*`, `scripts/prepare-airgap.sh` (chứa lệnh/tham chiếu hạ tầng thật, rebrand sẽ phá copy-paste). Có flag `--include-docs` để chạy mở rộng nếu cần sau.

Tính chất: **idempotent** (chạy nhiều lần ra cùng kết quả), case-sensitive, in danh sách file đã đổi.

## 7. Các bước thực hiện

1. Tạo local `aev-custom` ← `origin/aev-custom`.
2. `git merge main`. Resolve conflict:
   - Trang HTML (nhóm C): ưu tiên bản `main` (theirs) — sẽ re-brand lại bằng script.
   - navbar/footer/styles (nhóm B): reconcile tay, giữ design custom + nhận thay đổi chức năng của main.
3. Thêm `branding.config.json`, `scripts/apply-branding.mjs`.
4. Chạy script → chuẩn hóa toàn bộ branding (sửa hết bug ở mục 3).
5. Sửa `.env.example` (brand=AEV PDF, logo=aqua-logo.png, footer text đúng); khôi phục `@bentopdf` WASM URL + worker host trong `.env.example`/`vite.config.ts`.
6. Gỡ GitHub links trong `navbar.html`/`footer.html` (+ simple).
7. Viết tài liệu nâng cấp (mục 8).
8. `npm install` + `npm run build` + chạy test → verify không vỡ.
9. Commit; **chưa push** cho tới khi user duyệt.

## 8. Tài liệu nâng cấp (để lần sau dễ)

`docs/UPGRADE-FROM-UPSTREAM.md` — quy trình chuẩn:

```
git fetch upstream && git merge upstream/main   # hoặc origin/main
# resolve conflict navbar/footer/styles nếu có (chỉ vài file)
node scripts/apply-branding.mjs                 # chuẩn hóa lại brand
npm run build                                    # verify
```

Kèm: bảng giá trị brand, danh sách file UI thủ công cần để ý, các token phải giữ. Tùy chọn: tạo skill `.claude/skills/aev-rebrand/` gói gọn quy trình này.

## 9. Verify (bằng chứng trước khi tuyên bố xong)

- `npm run build` thành công.
- `git grep -nE "AEV-PDF\.com|@AEV-PDF/|AEV-PDF\.workers"` → rỗng (đã sửa hết bug).
- `git grep -n "cdn.jsdelivr.net/npm/@bentopdf"` → còn nguyên (WASM không vỡ).
- Test suite hiện có chạy pass.

## 10. Ngoài phạm vi (YAGNI)

- Không rebrand docs/README/workflow (giữ tham chiếu hạ tầng upstream) trừ khi user yêu cầu (`--include-docs`).
- Không đổi npm package name của chính dự án.
- Không thiết lập CI/CD mới.
