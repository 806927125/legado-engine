#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **老引擎（JS 参考实现）跑【详情 → 目录 → 正文】整条链**（离线 · 假服务器）
 *
 * ⚠️ 为什么要有它：
 *   规则级 fixture 对拍验的是「零件」；
 *   而「老引擎有的、新引擎没有的语义」往往藏在**整条链**里（详情 → 目录 → 正文）
 *   ⇒ 同一个源、同一套规则、同一份假服务器响应，两边各跑一遍 ⇒ **不一样的地方 = 待搬的清单**⭐
 *
 * 用法：node conformance/chain/old-engine-chain.js
 * 输出：一行 JSON（老引擎在这条链上的行为）⇒ 存成 `chain-expected.json` 给新引擎当门禁基准
 *
 * ⭐ **全程离线**：原生请求走 `nativeMock` 的假服务器（按路径路由）⇒ 不碰真网络、不依赖站方存活
 */

const fs = require('fs');
const path = require('path');
const { createSandbox } = require('../js-harness');

const DIR = __dirname;
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const readJSON = (f) => JSON.parse(read(f));

const src = readJSON('chain-source.json');
const bookUrl = read('chain-bookurl.txt').trim();
const DETAIL = read('server-detail.json');
const CATALOG = read('server-catalog.json');
const CONTENT = read('server-content.json');
const AVATAR = read('server-avatar.json');

// ── 假服务器：按路径路由（站方大灰狼的三个接口）────────────────────────
const requests = [];
function serve(url) {
  requests.push(String(url));
  if (/\/detail(\?|$)/.test(url)) return DETAIL;
  if (/\/catalog(\?|$)/.test(url)) return CATALOG;
  if (/\/content(\?|$)/.test(url)) return CONTENT;
  if (/\/get_avatar(\?|,|$)/.test(url)) return AVATAR;
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

// ── 跑整条链 ───────────────────────────────────────────────────────────
(async () => {
  const out = { source: src.bookSourceName, steps: {}, requests: [] };
  // ⭐⭐⭐ **归一化「数据更新于 <当前时间>」**（那是**时钟**，不是语义）
  //   ⇒ 每次跑都不一样 ⇒ 不归一化的话门禁永远红 ⭐
  const normalizeStamp = (t) => String(t || '').replace(
    /数据更新于\s*[^\n]*/g, '数据更新于 <时间戳>');

  // ① 详情
  const bi = await invoke('bookInfo', { source: src, bookUrl, book: { bookUrl, name: '测试书名' } });
  const book = (bi && bi.book) || {};
  const fullIntro = book.intro || '';
  const introNorm = normalizeStamp(fullIntro);
  out.steps.bookInfo = bi.error
    ? { error: bi.error }
    : {
        name: book.name || '',
        author: book.author || '',
        introLen: normalizeStamp(book.intro || '').length,
        // ⭐ **简介全文**（逐字比；**别比长度** ⇒ JS 的 .length 数 UTF-16 码元、Swift 的 count 数字素簇 ⇒ 口径不同）
        intro: normalizeStamp(book.intro || ''),
        tocUrl: book.tocUrl || '',
        coverUrl: book.coverUrl || '',
      };

  // ② 目录（用详情算出来的 tocUrl ⇒ 走的是同一条真路径）
  const toc = await invoke('toc', {
    source: src, tocUrl: book.tocUrl || '', bookUrl, book,
  });
  const chapters = (toc && toc.chapters) || [];
  out.steps.toc = toc.error
    ? { error: toc.error }
    : {
        count: chapters.length,
        chapters: chapters.map((c) => ({
          title: c.title || '',
          url: c.url || '',
          isVolume: !!c.isVolume,
        })),
      };

  // ③ 正文（第一册非卷章节）
  const ch = chapters.find((c) => c.url && !c.isVolume);
  let fullContent = '';
  if (!ch) {
    out.steps.content = { error: '没有可用的章节' };
  } else {
    const ct = await invoke('content', {
      source: src, chapterUrl: ch.url, chapter: ch, book,
    });
    const text = (ct && ct.content) || '';
    fullContent = text;
    out.steps.content = ct.error
      ? { error: ct.error }
      : { len: text.length, head: text.slice(0, 60), text: text };
  }

  // ⭐ **期望值 = 老引擎的输出**（同样的形状给新引擎当门禁基准）
  //   ⇒ 只留可比的字段（requests / source 之类不参与比对）
  const comparable = {
    bookInfo: out.steps.bookInfo,
    toc: out.steps.toc,
    content: out.steps.content,
    // ⭐ 全文（差异时打出来定位用）
    full: { intro: introNorm, content: fullContent },
  };
  fs.writeFileSync(path.join(DIR, 'chain-expected.json'),
                   JSON.stringify(comparable, null, 1));
  // 诊断信息走 stderr（stdout 只留可比形状）
  console.error('[老引擎] 请求 ' + requests.length + ' 条：\n  ' + requests.join('\n  '));
  console.log(JSON.stringify(comparable));
})().catch((e) => {
  console.log(JSON.stringify({ fatal: String((e && e.stack) || e) }));
  process.exit(1);
});
