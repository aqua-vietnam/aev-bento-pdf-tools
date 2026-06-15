---
name: aev-upgrade
description: Use when syncing/upgrading the aev-custom branch from upstream BentoPDF (alam00000/bentopdf) while keeping AEV PDF branding. Covers merging upstream, resolving conflicts by file type, and running the idempotent re-brand script.
---

# Nâng cấp aev-custom từ upstream BentoPDF

Quy trình đầy đủ ở `docs/UPGRADE-FROM-UPSTREAM.md`. Giá trị brand ở `branding.config.json`.

## Các bước

1. `git fetch upstream && git checkout aev-custom && git merge upstream/main`
2. Resolve conflict theo loại file:
   - `src/pages/*.html`, root `*.html`, `public/locales/**` → `git checkout --theirs -- <file>` (brand lại sau).
   - `src/partials/navbar.html`, `footer.html`, `*-simple`, `src/css/styles.css` → reconcile tay, giữ design AEV (theme sáng, đã gỡ nav/github links).
   - `scripts/`, `docs/`, `.github/`, `Dockerfile*`, `chart/`, `cloudflare/` → `--theirs` (giữ upstream sạch, KHÔNG brand).
   - `vite.config.ts`, `package.json`, `nixpacks.toml`, `.env.example` → reconcile tay, giữ custom (port 5557, loadEnv, engines, SITE_URL).
3. `node scripts/apply-branding.mjs` (idempotent; `--dry-run` để xem trước).
4. Verify: `npm ci && cp .env.example .env.production && npm run build && npm run test:run`.
5. Commit + `git push origin aev-custom`.

## Bất biến (KHÔNG được phá)

- Giữ token hạ tầng: `@bentopdf/...` (npm WASM), `bentopdf.workers.dev`, `bentopdf-cors`.
  Script đã case-sensitive để không đụng `@bentopdf` chữ thường.
- Sau cùng: `git grep -nE "AEV-PDF\.com|@AEV-PDF/"` rỗng; `git grep "npm/@bentopdf"` còn nguyên.
- `apply-branding.mjs` chạy lần 2 phải báo "0 file đổi".

## Đổi brand/domain mới

Sửa `branding.config.json` + `.env.example` + `nixpacks.toml` (SITE_URL) → chạy lại script → build → test.
