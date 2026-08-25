---
name: aev-upgrade
description: Use when syncing/upgrading the aev-custom branch from upstream BentoPDF (alam00000/bentopdf) while keeping AEV PDF branding. Covers merging upstream, resolving conflicts by file type, and running the idempotent re-brand script.
---

# Nâng cấp aev-custom từ upstream BentoPDF

Quy trình đầy đủ ở `docs/UPGRADE-FROM-UPSTREAM.md`. Giá trị brand ở `branding.config.json`.

## Các bước

0. `nvm use` → `node -v` phải là `v22.14.0`. Node mới hơn làm 12 test fail giả (xem Bẫy 3).
1. `git fetch upstream && git checkout aev-custom && git merge upstream/main`
2. Resolve conflict theo loại file:
   - `src/pages/*.html`, root `*.html`, `public/locales/**` → `git checkout --theirs -- <file>` (brand lại sau).
   - `src/partials/navbar.html`, `footer.html`, `*-simple`, `src/css/styles.css` → reconcile tay, giữ design AEV (theme sáng, đã gỡ nav/github links).
   - `scripts/`, `docs/`, `.github/`, `Dockerfile*`, `chart/`, `cloudflare/` → `--theirs` (giữ upstream sạch, KHÔNG brand).
   - `vite.config.ts`, `package.json`, `nixpacks.toml`, `.env.example` → reconcile tay, giữ custom (port 5557, loadEnv, engines, SITE_URL).
3. `node scripts/apply-branding.mjs` (idempotent; `--dry-run` để xem trước).
4. `git add -u` — script KHÔNG tự stage (xem Bẫy 1).
5. `npx prettier --write` trên các file vừa stage, rồi `git add -u` (xem Bẫy 2).
6. Verify: `npm ci && cp .env.example .env.production && npm run build && npm run test:run`.
7. Commit (KHÔNG `--no-verify`) + `git push origin aev-custom`.

## Bất biến (KHÔNG được phá)

- Giữ token hạ tầng: `@bentopdf/...` (npm WASM), `bentopdf.workers.dev`, `bentopdf-cors`.
  Script đã case-sensitive để không đụng `@bentopdf` chữ thường.
- Sau cùng: `git grep -nE "AEV-PDF\.com|@AEV-PDF/"` rỗng; `git grep "npm/@bentopdf"` còn nguyên.
- `apply-branding.mjs` chạy lần 2 phải báo "0 file đổi".
- `git diff HEAD` rỗng, và `git grep "BentoPDF" -- '*.html' 'public/locales/**' 'src/js/**'` rỗng.
- `git diff origin/aev-custom HEAD --stat -- src/partials/ src/css/styles.css .env.example` rỗng.

## Ba cái bẫy (đã mắc thật, chi tiết ở mục 7 của doc)

1. **Script không tự `git add`.** Commit sẽ thiếu branding trên các file auto-merge
   (vd `about.html`) mà `npm run build` vẫn PASS vì build đọc working tree. Luôn
   `git add -u` sau script và check `git diff HEAD` rỗng.
2. **Script làm lệch prettier** (~89 file, vì đổi độ dài dòng). Format lại, nhưng
   KHÔNG format `README.md`, `signatures/cla.json`, `src/js/logic/scan-to-pdf.ts` —
   3 file này dirty sẵn ở upstream, format sẽ gây conflict mọi lần merge sau.
3. **Node > 22.14.0**: global `localStorage` che jsdom → 12 test fail ở
   `i18n.test.ts` + `xss-replay.test.ts`. Không phải lỗi merge.

## Đổi brand/domain mới

Sửa `branding.config.json` + `.env.example` + `nixpacks.toml` (SITE_URL) → chạy lại script → build → test.
