#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **老引擎（JS 参考实现）跑「发现页（exploreKinds）」**（离线 · 假服务器）
 *
 * ⚠️ **为什么单独加这一条链**（2026-10-25 真机实证）：
 *   真机上「发现」点进去**全空**，而日志里只有一句：
 *     `站方 JS 抛异常：TypeError: java.longToast is not a function`
 *   ⇒ 根因链（已坐实）：
 *     ① 站方 exploreUrl 的 `catch (e) { java.longToast("番茄登录过期…") }`
 *     ② `java.longToast` 抛 ⇒ ⚠️ **catch 块里抛的异常不会被同一个 catch 捕获**
 *     ③ ⇒ 异常**逃出 catch** ⇒ **整条 exploreUrl 死** ⇒ **发现页全空** ⭐⭐⭐⭐⭐
 *   ⇒ 所以「发现页」这条链必须**单独对拍**，否则只在真机上撞 ⭐⭐⭐
 *
 * 用法：node conformance/chain/old-engine-explore.js
 * 输出：conformance/chain/chain-expected-explore.json（老引擎的分类/筛选栏）⇒ 给新引擎当门禁基准
 *
 * ⭐ **全程离线**：原生请求走 `nativeMock` 的假服务器（按路径路由）⇒ 不碰真网络
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('../js-harness');

const DIR = __dirname;
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const readJSON = (f) => JSON.parse(read(f));

// ⭐ **完整源**（带 exploreUrl + ruleExplore + jsLib）—— 就是用户真机测的那个
const raw = readJSON('chain-source-full.json');
const src = Array.isArray(raw) ? raw[0] : raw;
const DISCOVESTYLE = read('server-discovestyle.json');

// ── 假服务器：按路径路由 ────────────────────────────────────────────────
const requests = [];
function serve(url) {
  requests.push(String(url));
  if (/\/discovestyle(\?|$)/.test(url)) return DISCOVESTYLE;
  return null;
}

const { win: window } = createSandbox({
  origin: 'https://book.example.com/',
  nativeMock: async (fn, args) => {
    if (fn === 'request') {
      const url = String(args.url || '');
      const body = serve(url);
      if (body === null) return { ok: false, error: '假服务器没有这条路由: ' + url };
      return {
        ok: true, code: 200, url, redirectUrl: url,
        headers: { 'content-type': 'application/json' },
        body, bytes: body.length,
      };
    }
    if (fn === 'deviceID') return { ok: true, value: 'GT-DEVICE' };
    if (fn === 'getCookie' || fn === 'getString' || fn === 'getWebViewUA') {
      return { ok: true, value: fn === 'getWebViewUA' ? 'UA/1.0' : '' };
    }
    return { ok: true, value: '' };
  },
});

const invoke = async (op, payload) => {
  try {
    const r = await window.__qrInvoke(op, payload);
    if (r && r.error) return { error: String(r.error) };
    return r || {};
  } catch (e) {
    return { error: String((e && e.message) || e) };
  }
};

(async () => {
  const out = { source: src.bookSourceName, steps: {}, requests: [] };

  // ① 发现页的分类 + 筛选栏
  const ek = await invoke('exploreKinds', { source: src });
  const kinds = (ek && ek.kinds) || [];
  const filters = (ek && ek.filters) || [];
  out.steps.exploreKinds = ek.error
    ? { error: ek.error }
    : {
        kindCount: kinds.length,
        // ⭐ **分类逐字**（标题 + url）⇒ 不比数量（数量相同但内容不同也要抓到）
        kinds: kinds.map((k) => ({ title: k.title || '', url: k.url || '' })),
        // ⭐ **筛选栏**（站方的大灰狼把「平台/模式/频道」也放这儿 ⇒ 站方写 `type:"select"`）
        filterCount: filters.length,
        filters: filters.map((f) => ({
          title: f.title || '',
          type: f.type || '',
          chars: Array.isArray(f.chars) ? f.chars : [],
          paramKey: f.paramKey || '',
        })),
      };

  out.requests = requests;
  fs.writeFileSync(path.join(DIR, 'chain-expected-explore.json'),
                   JSON.stringify({ source: out.source, ...out.steps }, null, 1));
  process.stderr.write('老引擎 exploreKinds：' +
    (out.steps.exploreKinds.error
      ? ('失败：' + out.steps.exploreKinds.error)
      : ('分类 ' + out.steps.exploreKinds.kindCount + ' 条 / 筛选栏 ' +
         out.steps.exploreKinds.filterCount + ' 条')) + '\n');
})();
