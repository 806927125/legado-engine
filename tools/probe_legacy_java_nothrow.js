#!/usr/bin/env node
/**
 * ⭐⭐⭐ **实测「老引擎上调用不抛异常」的 java.* API** ⇒ 写 `conformance/fixtures/legacy-java-nothrow.json`
 *
 * **为什么**（2026-10-25 真机：`java.longToast is not a function`）：
 *   宿主没实现 ⇒ 包装函数抛 TypeError ⇒ **站方 JS 第一句就炸** ⇒ 整条规则死定 ⭐⭐⭐
 *   ⇒ 「宿主未实现 ⇒ 抛 TypeError」这条对「老引擎上压根没这个方法」是对的
 *     （站方 try/catch 探测平台 ⇒ 抛了才走对分支），
 *     但对「老引擎上**有**这个方法、只是宿主 op 缺失」的 ⇒ 老引擎**不抛**
 *     （`nativeCall` 只 resolve `{ok:false}`）⇒ 新引擎也不许抛 ⭐⭐⭐
 *
 * ⇒ 名单**实测**得出（不是猜）：真跑老引擎 + **忠实**的宿主 mock。
 *
 * 跑法（需要 jsdom；沙盒里在兄弟仓库 qireaderlite 的 node_modules）：
 *   HOST_OPS 自动从宿主 Swift 源码扫 ⇒ **不手写** ⭐
 *   node tools/probe_legacy_java_nothrow.js > conformance/fixtures/legacy-java-nothrow.json
 */
const { JSDOM } = require('jsdom');
const fs = require('fs'), path = require('path'), vm = require('vm');

const ROOT = path.join(__dirname, '..');
const ENGINE_DIR = process.env.LEGADO_ENGINE_DIR || path.join(ROOT, 'reference/js');
const APP_DIR = process.env.APP_DIR || path.join(ROOT, '..', 'qireaderlite');
const FILES = ['jsoup-compat.js','sextant-filter.js','jsonpath.js','org-jsoup.js','sha1.js','java-api.js',
               'packages-native.js','packages_stub.js','source-api.js','rule-analyzer.js','engine.js'];

// ── 宿主真实实现的 op（从 Swift 源码扫 `case "op"` ⇒ **不手写**）────────────
function scanHostOps() {
  const ops = new Set();
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.swift')) {
        const s = fs.readFileSync(p, 'utf8');
        for (const m of s.matchAll(/case\s+"(\w+)"/g)) ops.add(m[1]);
      }
    }
  };
  walk(path.join(APP_DIR, 'QiReaderLite'));
  return [...ops].sort();
}
const HOST_OPS = scanHostOps();

// ── 老引擎沙盒 ──────────────────────────────────────────────────────────
const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>',
  { url:'https://book.example.com/', runScripts:'outside-only', pretendToBeVisual:true });
const win = dom.window, ctx = dom.getInternalVMContext();
const seen = [];
// ⭐ 忠实模拟轻阅宿主：postMessage({id, fn, args}) ⇒ 宿主回 __qrResolve(id, {ok:true,value})
//   宿主**没有**的 op ⇒ 回 {ok:false,error} ⇒ 老引擎的 nativeCall **不 reject** ⇒ **不抛异常** ⭐
win.webkit = { messageHandlers: { qr: { postMessage(msg) {
  seen.push(msg.fn);
  const ok = HOST_OPS.indexOf(msg.fn) >= 0;
  setTimeout(() => {
    try { win.__qrResolve(msg.id, ok ? { ok:true, value:'' } : { ok:false, error:'宿主没有这个 op: ' + msg.fn }); }
    catch (e) {}
  }, 0);
} } } };
win.__nativeCalls = [];
win.eval('window.__qrSeq=0;window.__qrPending={};window.__qrResolve=function(id,value){var r=window.__qrPending[id];if(!r)return;delete window.__qrPending[id];value&&value.ok===false?r.reject(new Error(value.error||"engine error")):r.resolve(value&&"value" in value?value.value:value);};');
for (const f of FILES) {
  const p = path.join(ENGINE_DIR, f);
  if (!fs.existsSync(p)) continue;
  try { vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename:f }); }
  catch (e) { console.error('load fail', f, e.message); }
}
const QR = win.QR;
const legacy = JSON.parse(fs.readFileSync(path.join(ROOT, 'conformance/fixtures/legacy-host-api.json'), 'utf8'));

(async () => {
  const noThrow = [], throws = [];
  for (const m of legacy.java) {
    const fn = QR.java && QR.java[m];
    if (typeof fn !== 'function') { throws.push({ m, why:'方法不存在' }); continue; }
    try {
      let done = false;
      const p = Promise.resolve().then(() => fn.call(QR.java, 'https://x.example/')).then(() => { done = true; });
      const to = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), 300));
      await Promise.race([p, to]);
      noThrow.push(m);
    } catch (e) { throws.push({ m, why:String(e.message || e).slice(0, 80) }); }
  }
  const out = {
    note: '⭐ 老引擎(轻阅 reference/js)上**调用不抛异常**的 java.* 方法 —— 权威清单：'
        + 'Node 真跑老引擎 + 忠实宿主 mock 实测得出。'
        + ' ⇒ 这批方法在新引擎上**必须也不抛**（宿主没实现 ⇒ 静默返回 undefined）'
        + ' ⇒ 新引擎抛 TypeError = 回归（站方 JS 直接死）⭐⭐⭐',
    hostOps: HOST_OPS,
    noThrow: noThrow.sort(),
    throws: throws.map(t => t.m + ' => ' + t.why),
  };
  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
  process.stderr.write('宿主 op ' + HOST_OPS.length + ' 个 ｜ 不抛 ' + noThrow.length + ' ｜ 抛 ' + throws.length + '\n');
})();
