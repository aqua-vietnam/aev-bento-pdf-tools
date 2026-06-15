#!/usr/bin/env node
/**
 * apply-branding.mjs — Chuẩn hóa branding của fork (AEV PDF) lên file web-facing.
 *
 * Dùng cho quy trình nâng cấp: sau khi `git merge upstream/main`, chạy script này
 * để (1) áp brand/domain/social của fork, (2) KHÔI PHỤC các token hạ tầng upstream
 * (npm scope @bentopdf, cloudflare worker...) mà các bản rebrand mù trước đây làm hỏng.
 *
 * Tính chất: idempotent, case-sensitive (không đụng @bentopdf npm / bentopdf.workers.dev).
 *
 * Usage:
 *   node scripts/apply-branding.mjs            # áp dụng
 *   node scripts/apply-branding.mjs --dry-run  # chỉ in file sẽ đổi, không ghi
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DRY = process.argv.includes('--dry-run');

const cfg = JSON.parse(
  readFileSync(join(ROOT, 'branding.config.json'), 'utf8')
);
const { brand, upstream } = cfg;
const DOMAIN = brand.domain;

// --- glob (minimatch-lite) ---------------------------------------------------
// Chuyển glob đơn giản (*, **, ?) sang RegExp. Đủ dùng cho scope khai báo.
function globToRe(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') i++;
        re += '(?:.*/)?';
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else if ('.+^${}()|[]\\'.includes(c)) re += '\\' + c;
    else if (c === '/') re += '/';
    else re += c;
  }
  return new RegExp('^' + re + '$');
}
const inScope = cfg.scope.map(globToRe);
const outScope = cfg.excludeFromScope.map(globToRe);
const matches = (path, list) => list.some((re) => re.test(path));

// --- danh sách thay thế, THỨ TỰ QUAN TRỌNG -----------------------------------
// 1) Khôi phục token hạ tầng upstream (ours đã làm hỏng). Phải chạy trước.
// 2) Domain (.com trước generic). 3) Social. 4) Brand hiển thị (cuối cùng).
function escRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
const rules = [
  // 1. Restore infra tokens broken bởi rebrand mù (@AEV-PDF -> @bentopdf, v.v.)
  ['@AEV-PDF/', '@bentopdf/'],
  ['/@AEV-PDF/', '/@bentopdf/'],
  ['AEV-PDF.workers.dev', 'bentopdf.workers.dev'],
  ['AEV-PDF-cors', 'bentopdf-cors'],
  ['AEV-PDF-pymupdf-wasm', 'bentopdf-pymupdf-wasm'],
  ['AEV-PDF-gs-wasm', 'bentopdf-gs-wasm'],
  ['AEV-PDF-airgap-bundle', 'bentopdf-airgap-bundle'],
  ['AEV-PDF-*.tgz', 'bentopdf-*.tgz'],
  [`alam00000/AEV-PDF`, upstream.githubRepo],

  // 2. Domain — biến thể www / .com trước, rồi generic
  ['https://www.AEV-PDF.com', `https://${DOMAIN}`],
  ['www.AEV-PDF.com', DOMAIN],
  ['AEV-PDF.com', DOMAIN],
  ['https://www.bentopdf.com', `https://${DOMAIN}`],
  ['www.bentopdf.com', DOMAIN],
  ['bentopdf.com', DOMAIN],

  // 3. Social (xử lý handle có @ TRƯỚC brand generic, nếu không '@AEV-PDF' sẽ thành '@AEV PDF')
  ['x.com/AEV-PDF', brand.twitterUrl],
  ['x.com/bentopdf', brand.twitterUrl],
  ['linkedin.com/company/AEV-PDF', brand.linkedinUrl],
  ['linkedin.com/company/bentopdf', brand.linkedinUrl],
  ['@AEV-PDF', brand.twitterHandle], // handle hỏng từ rebrand cũ
  [upstream.twitterHandle, brand.twitterHandle], // @BentoPDF -> @aquavietnam (case-sensitive, KHÔNG trùng @bentopdf)

  // 4. Brand hiển thị (cuối cùng, sau khi mọi token ghép đã xử lý)
  ['BentoPDF', brand.name],
  ['Bento PDF', brand.name],
  ['AEV-PDF', brand.name],
];
const compiled = rules.map(([from, to]) => [new RegExp(escRe(from), 'g'), to]);

// --- chạy --------------------------------------------------------------------
const tracked = execSync('git ls-files', { cwd: ROOT, encoding: 'utf8' })
  .split('\n')
  .filter(Boolean);

const targets = tracked.filter(
  (p) => matches(p, inScope) && !matches(p, outScope)
);

const LEFTOVER_RE =
  /AEV-PDF\.com|@AEV-PDF|@AEV PDF|AEV-PDF\.workers|alam00000\/AEV-PDF|BentoPDF|@BentoPDF/;

let changedCount = 0;
const changedFiles = [];
const leftovers = [];
for (const rel of targets) {
  const abs = join(ROOT, rel);
  if (!existsSync(abs)) continue;
  const before = readFileSync(abs, 'utf8');
  let after = before;
  for (const [re, to] of compiled) after = after.replace(re, to);
  if (after !== before) {
    changedFiles.push(rel);
    changedCount++;
    if (!DRY) writeFileSync(abs, after);
  }
  // Kiểm tra trên nội dung ĐÃ xử lý (in-memory) để dry-run cũng chính xác
  if (LEFTOVER_RE.test(after)) leftovers.push(rel);
}

console.log(
  `${DRY ? '[dry-run] ' : ''}apply-branding: ${changedCount} file đổi.`
);
for (const f of changedFiles) console.log('  ~ ' + f);
if (leftovers.length) {
  console.error('\n⚠ Còn token chưa xử lý ở:');
  for (const f of leftovers) console.error('  ! ' + f);
  process.exit(2);
}
console.log('✓ Không còn token brand/hỏng tồn đọng trong scope.');
