import Foundation

/// ⭐⭐⭐⭐⭐ **`org.jsoup` 兼容层**（纯 JS · 无依赖 · JSC / Node 共用同一份）
///
/// ⚠️⚠️ **本文件是【产物】** —— 源是 `Resources/org-jsoup.js`
/// ⇒ 改 JS 请改**那个文件**，然后跑 `python3 Scripts/embed_js.py` 重新生成
/// ⇒ 门禁 `OrgJsoupCompatTests` 会**逐字比对** ⇒ 产物过期就红 ⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **为什么要「纯 JS」而不是「Swift 解析 + 桥回 JS」**（2026-10-26 实证）
/// ──────────────────────────────────────────────────────────────
///   · **JSC（真机）没有 DOM**；**Node（沙盒）也没有 DOM**
///   · 而 **Node 后端不回调 Swift**（`__hostJSON` 是纯 JS 实现 + 预置缓存）
///   ⇒ ⇒ 任何能力只要「**沙盒能验**」⇒ 就必须写在 **JS** 里
///   ⇒ ⇒ **一份 JS ⇒ 两端一模一样** ⇒ 沙盒绿 = 真机绿（不是「沙盒绿、真机错」）⭐⭐⭐
///
/// ──────────────────────────────────────────────────────────────
/// **语义照抄老引擎**（轻阅 `reference/js/org-jsoup.js`）—— 老实现是事实标准
/// ──────────────────────────────────────────────────────────────
///   · 老实现建在 **WKWebView 的 DOM** 上 ⇒ 这里改成「**自带的迷你 DOM**」
///   · 对外 API 面保持一致：`Jsoup.parse` / `Document.select` / `Document.body`
///     / `Element.text|ownText|html|outerHtml|attr|remove|select|children|parent`
///     / `Elements`（**真数组** + `size/first/last/each/attr/text/html/select`…）
///   · `Elements` 必须是**真数组** ⇒ 站方的 `Array.from(els).reverse()` 才能用 ⭐⭐⭐
///
/// ⭐ **站方真实用量**（125 源语料，剥注释后统计）：
///   · `org.jsoup.Jsoup.parse` **43 处 / 7 个源**
///   · 选择器：`a` / `li` / `.articleHide` / `.muludiv` / `ul.stui-content__playlist`
///     / `li a` / `ul.nav.nav-pills li a` / `.noveldefaultimage` / `p.xs-show`
///     / `ul.topul > li` / `#jieqi_page_contents .c_row` / `#jieqi_page_contents tr`
///     / `:matchesOwn(内容未加载完成|关闭(阅读|小说)模式)`（**jsoup 专有** ⇒ 已支持）
///   · 方法：`text` 62 / `size` 43 / `attr` 21 / `first` 12 / `body` 10 / `remove` 9
///     / `html` 2 / `toString` 1 / `outerHtml` 1
public enum OrgJsoupCompat {
    /// ⭐ **JS 源码本体**（`#` 包裹的 raw string ⇒ 反斜杠不被当转义）
    public static let source: String = ##"""
/* org-jsoup 兼容层（纯 JS · 无依赖 · JSC / Node 共用这一份）
 *
 * 为什么是纯 JS：
 *   · JSC（真机）没有 DOM；Node（沙盒）也没有 DOM
 *   · 而 Node 后端**不回调 Swift** ⇒ 任何能力只要「沙盒能验」⇒ 就必须写在 JS 里
 *   ⇒ ⇒ **一份 JS ⇒ 两端一模一样** ⇒ 沙盒绿 = 真机绿（不是「沙盒绿、真机错」）
 *
 * 语义照抄老引擎（轻阅 reference/js/org-jsoup.js）—— 老实现是事实标准。
 * 老实现建在 WKWebView 的 DOM 上；这里改成「自带的迷你 DOM」，对外 API 面保持一致。
 */
(function (g) {
  'use strict';

  /* ---------------- 实体 ---------------- */
  var ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
              middot: '·', hellip: '…', mdash: '—', ndash: '–', copy: '©' };
  function decodeEntities(s) {
    if (s.indexOf('&') < 0) return s;
    return s.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);/g, function (m, g1) {
      if (g1.charAt(0) === '#') {
        var hex = g1.charAt(1) === 'x' || g1.charAt(1) === 'X';
        var code = parseInt(hex ? g1.slice(2) : g1.slice(1), hex ? 16 : 10);
        if (!isFinite(code) || code < 0 || code > 0x10FFFF) return m;
        try { return String.fromCodePoint(code); } catch (e) { return m; }
      }
      var e = ENT[g1.toLowerCase()];
      return e === undefined ? m : e;
    });
  }

  /* ---------------- 迷你 DOM ---------------- */
  var VOID = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1,
               link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  var RAW = { script: 1, style: 1, textarea: 1, title: 1, xmp: 1, noembed: 1, noframes: 1 };
  // 隐式闭合：遇到这些标签时，栈上同名的开放标签要自动闭合
  var CLOSED_BY = {
    li: ['li'], p: ['p'], dt: ['dt', 'dd'], dd: ['dt', 'dd'],
    tr: ['tr', 'td', 'th'], td: ['td', 'th'], th: ['td', 'th'],
    option: ['option'], optgroup: ['optgroup', 'option'],
    thead: ['thead', 'tbody', 'tfoot'], tbody: ['thead', 'tbody', 'tfoot'],
    tfoot: ['thead', 'tbody']
  };

  function Node(tag, attrs) {
    this.tag = tag;            // 小写标签名
    this.attrs = attrs || {};  // 属性名（小写）→ 值
    this.children = [];        // 元素 / 文本节点
    this.parent = null;
  }
  function TextNode(text) { this.text = text; this.parent = null; }

  function appendChild(parent, child) {
    child.parent = parent;
    parent.children.push(child);
    return child;
  }
  function removeChild(parent, child) {
    var i = parent.children.indexOf(child);
    if (i >= 0) parent.children.splice(i, 1);
    child.parent = null;
    return child;
  }

  function parseAttrs(src) {
    var attrs = {};
    var re = /([^\s=/>"']+)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'`=<>]+)))?/g;
    var m;
    while ((m = re.exec(src)) !== null) {
      var name = m[1].toLowerCase();
      var value = (m[3] !== undefined) ? m[3] : (m[4] !== undefined) ? m[4]
                : (m[5] !== undefined) ? m[5] : '';
      attrs[name] = decodeEntities(value);
    }
    return attrs;
  }

  /** 把 HTML 解析成树（返回根元素，children 里装 body 之类的） */
  function parseHTML(html) {
    var src = String(html === null || html === undefined ? '' : html);
    var root = new Node('#root', {});
    var stack = [root];
    var i = 0;
    var n = src.length;
    function top() { return stack[stack.length - 1]; }
    function addText(t) {
      if (!t) return;
      appendChild(top(), new TextNode(decodeEntities(t)));
    }
    while (i < n) {
      var lt = src.indexOf('<', i);
      if (lt < 0) { addText(src.slice(i)); break; }
      if (lt > i) addText(src.slice(i, lt));
      // 注释
      if (src.substr(lt, 4) === '<!--') {
        var end = src.indexOf('-->', lt + 4);
        i = end < 0 ? n : end + 3;
        continue;
      }
      // doctype / CDATA / 处理指令
      if (src.substr(lt, 2) === '<!' || src.substr(lt, 2) === '<?') {
        var gt = src.indexOf('>', lt);
        i = gt < 0 ? n : gt + 1;
        continue;
      }
      // 闭合标签
      if (src.charAt(lt + 1) === '/') {
        var gt2 = src.indexOf('>', lt);
        if (gt2 < 0) { i = n; continue; }
        var closeName = src.slice(lt + 2, gt2).trim().toLowerCase();
        // 找到最近的同名开放标签并闭合（中间未闭合的一起闭合）
        for (var s = stack.length - 1; s > 0; s--) {
          if (stack[s].tag === closeName) { stack.length = s; break; }
        }
        i = gt2 + 1;
        continue;
      }
      // 开放标签
      var tagEnd = src.indexOf('>', lt);
      if (tagEnd < 0) { addText(src.slice(lt)); break; }
      var inner = src.slice(lt + 1, tagEnd);
      var selfClose = inner.charAt(inner.length - 1) === '/';
      if (selfClose) inner = inner.slice(0, -1);
      var sp = inner.search(/[\s/]/);
      var tagName = (sp < 0 ? inner : inner.slice(0, sp)).toLowerCase();
      var attrSrc = sp < 0 ? '' : inner.slice(sp);
      i = tagEnd + 1;
      if (!tagName) continue;

      // 隐式闭合
      var closers = CLOSED_BY[tagName];
      if (closers) {
        for (;;) {
          var t = top();
          if (t !== root && closers.indexOf(t.tag) >= 0) stack.pop();
          else break;
        }
      }
      var el = new Node(tagName, parseAttrs(attrSrc));
      appendChild(top(), el);
      if (VOID[tagName] || selfClose) continue;
      // 原始文本元素
      if (RAW[tagName]) {
        var closeIdx = src.toLowerCase().indexOf('</' + tagName, i);
        var raw = closeIdx < 0 ? src.slice(i) : src.slice(i, closeIdx);
        if (raw) appendChild(el, new TextNode(raw));
        if (closeIdx < 0) { i = n; continue; }
        var closeEnd = src.indexOf('>', closeIdx);
        i = closeEnd < 0 ? n : closeEnd + 1;
        continue;
      }
      stack.push(el);
    }
    return root;
  }

  /* ---------------- 文本与 HTML 序列化 ---------------- */
  function ownTextOf(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      if (c instanceof TextNode) out += c.text;
    }
    return out;
  }
  function wholeTextOf(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      if (c instanceof TextNode) out += c.text;
      else if (c.tag !== '#comment') out += wholeTextOf(c);
    }
    return out;
  }
  function normalise(s) {
    return String(s === null || s === undefined ? '' : s).replace(/[\s ]+/g, ' ').trim();
  }
  function escapeText(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function escapeAttr(s) {
    return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
  }
  function innerHtmlOf(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) out += outerHtmlOf(el.children[i]);
    return out;
  }
  function outerHtmlOf(node) {
    if (node instanceof TextNode) return escapeText(node.text);
    var name = node.tag;
    var out = '<' + name;
    for (var k in node.attrs) {
      if (!Object.prototype.hasOwnProperty.call(node.attrs, k)) continue;
      out += ' ' + k + '="' + escapeAttr(node.attrs[k]) + '"';
    }
    out += '>';
    if (VOID[name]) return out;
    out += innerHtmlOf(node);
    out += '</' + name + '>';
    return out;
  }

  /* ---------------- CSS 选择器 ---------------- */
  // 支持：标签 / .类 / #id / [attr] / [attr=v] / [attr^=v] / [attr$=v] / [attr*=v] / [attr!=v]
  //       组合器：后代（空格）· 子代（>）· 相邻（+）· 兄弟（~）
  //       伪类：:contains(text) · :matches(re) · :matchesOwn(re)（jsoup 专有）
  function parseCompound(text) {
    var c = { tag: null, id: null, classes: [], attrs: [], pseudos: [] };
    var re = /([#.]?)([A-Za-z0-9_ -￿-]+)|(\[[^\]]*\])|(:[A-Za-z-]+(?:\(([^)]*)\))?)/g;
    // 上面这个正则不好用 ⇒ 改成手写扫描
    var i = 0;
    while (i < text.length) {
      var ch = text.charAt(i);
      if (ch === '*') { i++; continue; }
      if (ch === '#') {
        var j = i + 1;
        while (j < text.length && /[^\s.#\[:>]/.test(text.charAt(j))) j++;
        c.id = text.slice(i + 1, j); i = j; continue;
      }
      if (ch === '.') {
        var j2 = i + 1;
        while (j2 < text.length && /[^\s.#\[:>]/.test(text.charAt(j2))) j2++;
        c.classes.push(text.slice(i + 1, j2)); i = j2; continue;
      }
      if (ch === '[') {
        var close = text.indexOf(']', i);
        if (close < 0) break;
        var body = text.slice(i + 1, close);
        var am = body.indexOf('=');
        if (am < 0) c.attrs.push({ name: body.trim().toLowerCase(), op: null, value: null });
        else {
          var name = body.slice(0, am).trim().toLowerCase();
          var op = '=';
          var rest = body.slice(am + 1).trim();
          if (rest.charAt(0) === '^' || rest.charAt(0) === '$' || rest.charAt(0) === '*' || rest.charAt(0) === '!') {
            op = rest.charAt(0); rest = rest.slice(1).trim();
          }
          var val = rest.replace(/^["']/, '').replace(/["']$/, '');
          c.attrs.push({ name: name, op: op, value: val });
        }
        i = close + 1; continue;
      }
      if (ch === ':') {
        var j3 = i + 1;
        while (j3 < text.length && /[A-Za-z-]/.test(text.charAt(j3))) j3++;
        var pname = text.slice(i + 1, j3).toLowerCase();
        var parg = null;
        if (text.charAt(j3) === '(') {
          // ⭐⭐⭐ 伪类参数里【可以有嵌套括号】（站方真写法：
          //   :matchesOwn(内容未加载完成|关闭(阅读|小说)模式) ⇒ 正则自带分组 ⭐⭐⭐）
          //   ⇒ 只找第一个 ')' ⇒ 参数被截断 ⇒ 正则语法错 ⇒ 静默不匹配 ⇒ 规则空 ⭐⭐⭐
          var depth = 0, pc = -1;
          for (var pk = j3; pk < text.length; pk++) {
            var pch = text.charAt(pk);
            if (pch === '(') depth++;
            else if (pch === ')') { depth--; if (depth === 0) { pc = pk; break; } }
          }
          if (pc > 0) { parg = text.slice(j3 + 1, pc); j3 = pc + 1; }
        }
        c.pseudos.push({ name: pname, arg: parg });
        i = j3; continue;
      }
      // 标签名
      var j4 = i;
      while (j4 < text.length && /[^\s.#\[:>]/.test(text.charAt(j4))) j4++;
      if (j4 === i) { i++; continue; }
      c.tag = text.slice(i, j4).toLowerCase();
      i = j4;
    }
    return c;
  }

  function parseSelector(sel) {
    var s = String(sel === null || sel === undefined ? '' : sel).trim();
    var groups = [];
    var parts = s.split(',');
    for (var p = 0; p < parts.length; p++) {
      var raw = parts[p].trim();
      if (!raw) continue;
      // 拆成 [组合符, 复合选择器] 序列
      var tokens = [];
      var buf = '';
      var comb = ' ';
      for (var i = 0; i < raw.length; i++) {
        var ch = raw.charAt(i);
        if (ch === '>' || ch === '+' || ch === '~') {
          if (buf) { tokens.push({ comb: comb, comp: parseCompound(buf) }); buf = ''; }
          comb = ch;
          continue;
        }
        if (/\s/.test(ch)) {
          if (buf) { tokens.push({ comb: comb, comp: parseCompound(buf) }); buf = ''; comb = ' '; }
          continue;
        }
        buf += ch;
      }
      if (buf) tokens.push({ comb: comb, comp: parseCompound(buf) });
      if (tokens.length) groups.push(tokens);
    }
    return groups;
  }

  function matchAttr(el, spec) {
    var v = el.attrs[spec.name];
    if (v === undefined) return spec.op === '!=';
    if (spec.op === null) return true;
    if (spec.op === '=') return v === spec.value;
    if (spec.op === '^=') return spec.value !== '' && v.indexOf(spec.value) === 0;
    if (spec.op === '$=') return spec.value !== '' && v.slice(-spec.value.length) === spec.value;
    if (spec.op === '*=') return spec.value !== '' && v.indexOf(spec.value) >= 0;
    if (spec.op === '!=') return v !== spec.value;
    return false;
  }
  function matchPseudo(el, ps) {
    if (ps.name === 'contains') return wholeTextOf(el).indexOf(ps.arg || '') >= 0;
    if (ps.name === 'matches') { try { return new RegExp(ps.arg || '').test(wholeTextOf(el)); } catch (e) { return false; } }
    if (ps.name === 'matchesown') { try { return new RegExp(ps.arg || '').test(ownTextOf(el)); } catch (e) { return false; } }
    if (ps.name === 'not') return !matchCompound(el, parseCompound(ps.arg || ''));
    return true;   // 其它伪类：不筛（宁可多给也别少给）
  }
  function matchCompound(el, c) {
    if (el.tag === '#root') return false;
    if (c.tag && c.tag !== '*' && el.tag !== c.tag) return false;
    if (c.id && el.attrs['id'] !== c.id) return false;
    for (var i = 0; i < c.classes.length; i++) {
      var cls = (el.attrs['class'] || '').split(/\s+/);
      if (cls.indexOf(c.classes[i]) < 0) return false;
    }
    for (var a = 0; a < c.attrs.length; a++) if (!matchAttr(el, c.attrs[a])) return false;
    for (var p = 0; p < c.pseudos.length; p++) if (!matchPseudo(el, c.pseudos[p])) return false;
    return true;
  }

  function elementChildren(el) {
    var out = [];
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      if (!(c instanceof TextNode)) out.push(c);
    }
    return out;
  }
  function prevElement(el) {
    if (!el.parent) return null;
    var kids = elementChildren(el.parent);
    var idx = kids.indexOf(el);
    return idx > 0 ? kids[idx - 1] : null;
  }
  function nextElement(el) {
    if (!el.parent) return null;
    var kids = elementChildren(el.parent);
    var idx = kids.indexOf(el);
    return idx >= 0 && idx + 1 < kids.length ? kids[idx + 1] : null;
  }

  // 从右往左匹配：tokens 的最后一个先匹配 el
  function matchTokens(tokens, idx, el) {
    if (idx < 0) return true;
    var tok = tokens[idx];
    if (!matchCompound(el, tok.comp)) return false;
    if (idx === 0) return true;
    var comb = tok.comb;
    if (comb === ' ') {
      var p = el.parent;
      while (p && p.tag !== '#root') {
        if (matchTokens(tokens, idx - 1, p)) return true;
        p = p.parent;
      }
      return false;
    }
    if (comb === '>') {
      var pp = el.parent;
      if (!pp || pp.tag === '#root') return false;
      return matchTokens(tokens, idx - 1, pp);
    }
    if (comb === '+') {
      var ps = prevElement(el);
      return ps ? matchTokens(tokens, idx - 1, ps) : false;
    }
    if (comb === '~') {
      var s = prevElement(el);
      while (s) {
        if (matchTokens(tokens, idx - 1, s)) return true;
        s = prevElement(s);
      }
      return false;
    }
    return false;
  }

  function selectAll(root, sel) {
    var groups = parseSelector(sel);
    var out = [];
    if (!groups.length) return out;
    (function walk(el) {
      var kids = elementChildren(el);
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i];
        for (var gi = 0; gi < groups.length; gi++) {
          if (matchTokens(groups[gi], groups[gi].length - 1, c)) { out.push(c); break; }
        }
        walk(c);
      }
    })(root);
    return out;
  }

  function cloneNode(node) {
    var c = new Node(node.tag, {});
    for (var k in node.attrs) {
      if (Object.prototype.hasOwnProperty.call(node.attrs, k)) c.attrs[k] = node.attrs[k];
    }
    for (var i = 0; i < node.children.length; i++) {
      var ch = node.children[i];
      if (ch instanceof TextNode) appendChild(c, new TextNode(ch.text));
      else appendChild(c, cloneNode(ch));
    }
    return c;
  }

  /** 插一段 HTML（只支持简单标签，够站方用） */
  function insertAdjacentHtml(el, where, html) {
    var tmp = new Node('#tmp', {});
    var frag = parseHTML(String(html));
    for (var i = 0; i < frag.children.length; i++) appendChild(tmp, frag.children[i]);
    var parent = el.parent;
    if (!parent) return el;
    var kids = parent.children;
    var idx = kids.indexOf(el);
    if (where === 'beforebegin' && idx >= 0) {
      for (var k = tmp.children.length - 1; k >= 0; k--) {
        var c = tmp.children[k];
        c.parent = parent;
        kids.splice(idx, 0, c);
      }
    } else if (where === 'afterbegin') {
      for (var k2 = tmp.children.length - 1; k2 >= 0; k2--) {
        var c2 = tmp.children[k2];
        c2.parent = el;
        el.children.splice(0, 0, c2);
      }
    } else if (where === 'beforeend') {
      for (var k3 = 0; k3 < tmp.children.length; k3++) appendChild(el, tmp.children[k3]);
    } else if (where === 'afterend' && idx >= 0) {
      for (var k4 = 0; k4 < tmp.children.length; k4++) {
        var c4 = tmp.children[k4];
        c4.parent = parent;
        kids.splice(idx + 1, 0, c4);
      }
    }
    return el;
  }

  /* ---------------- jsoup 风格 API ---------------- */
  function El(node, baseUrl) {
    this.n = node;
    this.baseUrl = baseUrl || '';
  }
  El.prototype.text = function () { return normalise(wholeTextOf(this.n)); };
  El.prototype.ownText = function () { return normalise(ownTextOf(this.n)); };
  El.prototype.hasText = function () { return this.text().length > 0; };
  El.prototype.html = function () { return innerHtmlOf(this.n); };
  El.prototype.outerHtml = function () { return outerHtmlOf(this.n); };
  El.prototype.toString = function () { return this.outerHtml(); };
  El.prototype.tagName = function () { return this.n.tag; };
  El.prototype.nodeName = function () { return this.n.tag; };
  El.prototype.attr = function (name, value) {
    if (arguments.length >= 2) { this.n.attrs[String(name).toLowerCase()] = String(value); return this; }
    var v = this.n.attrs[String(name).toLowerCase()];
    return v === undefined ? '' : v;
  };
  El.prototype.id = function () { return this.attr('id'); };
  El.prototype.className = function () { return this.attr('class'); };
  El.prototype.classNames = function () { return this.attr('class').split(/\s+/).filter(Boolean); };
  El.prototype.val = function () { return this.attr('value'); };
  El.prototype.absUrl = function (name) { return this.attr(name); };
  El.prototype.select = function (sel) { return wrapAll(selectAll(this.n, sel), this.baseUrl); };
  El.prototype.selectFirst = function (sel) {
    var all = selectAll(this.n, sel);
    return all.length ? new El(all[0], this.baseUrl) : null;
  };
  El.prototype.getElementsByTag = function (t) { return this.select('tag.' + t); };
  El.prototype.getElementById = function (i) {
    var all = selectAll(this.n, '#' + i);
    return all.length ? new El(all[0], this.baseUrl) : null;
  };
  El.prototype.children = function () {
    return wrapAll(elementChildren(this.n), this.baseUrl);
  };
  El.prototype.parent = function () {
    return (this.n.parent && this.n.parent.tag !== '#root') ? new El(this.n.parent, this.baseUrl) : null;
  };
  El.prototype.nextElementSibling = function () {
    var e = nextElement(this.n);
    return e ? new El(e, this.baseUrl) : null;
  };
  El.prototype.prevElementSibling = function () {
    var e = prevElement(this.n);
    return e ? new El(e, this.baseUrl) : null;
  };
  El.prototype.remove = function () {
    if (this.n && this.n.parent) removeChild(this.n.parent, this.n);
    return this;
  };
  El.prototype.raw = function () { return this.n; };
  // ── 以下一批照抄老引擎（El.prototype.*）—— 老实现是事实标准，缺一个站方就可能炸 ⭐⭐⭐
  El.prototype.attributes = function () { return this.n.attrs; };
  El.prototype.hasAttr = function (name) { return this.n.attrs[String(name).toLowerCase()] !== undefined; };
  El.prototype.removeAttr = function (name) { delete this.n.attrs[String(name).toLowerCase()]; return this; };
  El.prototype.hasClass = function (c) {
    return this.classNames().indexOf(String(c)) >= 0;
  };
  El.prototype.addClass = function (c) {
    var cs = this.classNames();
    if (cs.indexOf(String(c)) < 0) cs.push(String(c));
    this.attr('class', cs.join(' '));
    return this;
  };
  El.prototype.removeClass = function (c) {
    var cs = this.classNames().filter(function (x) { return x !== String(c); });
    this.attr('class', cs.join(' '));
    return this;
  };
  El.prototype.childrenSize = function () { return elementChildren(this.n).length; };
  El.prototype.child = function (i) {
    var kids = elementChildren(this.n);
    var idx = Number(i) || 0;
    return (idx >= 0 && idx < kids.length) ? new El(kids[idx], this.baseUrl) : null;
  };
  El.prototype.textNodes = function () {
    var out = [];
    for (var i = 0; i < this.n.children.length; i++) {
      if (this.n.children[i] instanceof TextNode) out.push(this.n.children[i].text);
    }
    return out;
  };
  El.prototype.data = function () { return this.n.attrs['data'] || ''; };
  El.prototype.normalName = function () { return this.n.tag; };
  El.prototype.sel = function () { return this.n.tag; };
  El.prototype.selN = function () { return this.n.tag; };
  El.prototype.clone = function () { return new El(cloneNode(this.n), this.baseUrl); };
  El.prototype.getElementsByClass = function (c) { return this.select('.' + c); };
  El.prototype.getElementsByAttribute = function (key, value) {
    var spec = '[' + key + (value === undefined ? '' : '="' + value + '"') + ']';
    return this.select(spec);
  };
  El.prototype.insertAdjacent = function (html, where) { return insertAdjacentHtml(this.n, where, html); };
  El.prototype.before = function (html) { return this.insertAdjacent(html, 'beforebegin'); };
  El.prototype.after = function (html) { return this.insertAdjacent(html, 'afterend'); };
  El.prototype.prepend = function (html) { return this.insertAdjacent(html, 'afterbegin'); };
  El.prototype.append = function (html) { return this.insertAdjacent(html, 'beforeend'); };
  El.prototype.empty = function () { this.n.children = []; return this; };
  El.prototype.toJSON = function () { return this.outerHtml(); };
  El.prototype.previousElementSibling = function () { return this.prevElementSibling(); };
  El.prototype.xpath = function () { return []; };

  function Doc(node, baseUrl) {
    this.n = node;
    this.baseUrl = baseUrl || '';
  }
  Doc.prototype.select = function (sel) { return wrapAll(selectAll(this.n, sel), this.baseUrl); };
  Doc.prototype.selectFirst = function (sel) {
    var all = selectAll(this.n, sel);
    return all.length ? new El(all[0], this.baseUrl) : null;
  };
  Doc.prototype.body = function () {
    var b = selectAll(this.n, 'body');
    if (b.length) return new El(b[0], this.baseUrl);
    return new El(this.n, this.baseUrl);
  };
  Doc.prototype.text = function () { return normalise(wholeTextOf(this.n)); };
  Doc.prototype.html = function () { return innerHtmlOf(this.n); };
  Doc.prototype.outerHtml = function () { return outerHtmlOf(this.n); };
  Doc.prototype.toString = function () { return this.outerHtml(); };
  Doc.prototype.attr = function (name) { return ''; };
  // ── 以下一批照抄老引擎（Doc.prototype.*）—— 老实现是事实标准 ⭐⭐⭐
  Doc.prototype.getElementById = function (i) {
    var all = selectAll(this.n, '#' + i);
    return all.length ? new El(all[0], this.baseUrl) : null;
  };
  Doc.prototype.getElementsByTag = function (t) { return this.select('tag.' + t); };
  Doc.prototype.getElementsByClass = function (c) {
    return this.select('.' + String(c).split(/\s+/).join('.'));
  };
  Doc.prototype.getElementsByAttribute = function (key, value) {
    var spec = '[' + key + (value === undefined ? '' : '="' + value + '"') + ']';
    return this.select(spec);
  };
  Doc.prototype.baseUri = function () { return this.baseUrl; };
  Doc.prototype.location = function () { return this.baseUrl; };
  Doc.prototype.head = function () {
    var h = selectAll(this.n, 'head');
    return h.length ? new El(h[0], this.baseUrl) : null;
  };
  Doc.prototype.children = function () { return wrapAll(elementChildren(this.n), this.baseUrl); };
  Doc.prototype.child = function (sel) { return this.select(sel).first(); };
  Doc.prototype.ownerDocument = function () { return this; };
  Doc.prototype.toJSON = function () { return this.html(); };
  Doc.prototype.xpath = function () { return []; };
  Doc.prototype.sel = function () { return null; };
  Doc.prototype.appendElement = function (tag) {
    var el = new Node(String(tag || 'div').toLowerCase(), {});
    appendChild(this.n, el);
    return new El(el, this.baseUrl);
  };
  Doc.prototype.appendChild = function (child) {
    if (child && child.n) { appendChild(this.n, child.n); return child; }
    var el = new Node('div', {});
    appendChild(this.n, el);
    return new El(el, this.baseUrl);
  };
  Doc.prototype.title = function () {
    var t = selectAll(this.n, 'title');
    return t.length ? normalise(wholeTextOf(t[0])) : '';
  };

  /** 裸节点数组 ⇒ El 数组（老引擎的 makeElements 收的是【已包装】的元素） */
  function wrapAll(nodes, baseUrl) {
    return makeElements(nodes.map(function (n) { return new El(n, baseUrl); }), baseUrl);
  }

  /** Elements = **真数组** + 额外方法（老引擎同款 ⇒ Array.from(els) 能用） */
  function makeElements(arr, baseUrl) {
    var e = arr.slice();
    e.size = function () { return e.length; };
    e.get = function (i) { return e[Number(i) || 0]; };
    e.isEmpty = function () { return e.length === 0; };
    e.first = function () { return e[0] || null; };
    e.last = function () { return e.length ? e[e.length - 1] : null; };
    e.each = function (fn) { e.forEach(function (x, i) { fn.call(x, x, i); }); return e; };
    e.toArray = function () { return e.slice(); };
    e.attr = function (n) { return e[0] ? e[0].attr(n) : ''; };
    e.text = function () { return e[0] ? e[0].text() : ''; };
    e.html = function () { return e[0] ? e[0].html() : ''; };
    e.ownText = function () { return e[0] ? e[0].ownText() : ''; };
    e.tagName = function () { return e[0] ? e[0].tagName() : ''; };
    e.select = function (s) { return e[0] ? e[0].select(s) : makeElements([], baseUrl); };
    e.eachAttr = function (n, fn) { e.forEach(function (x) { fn(x.attr(n), x); }); return e; };
    e.attrList = function (n) { return e.map(function (x) { return x.attr(n); }); };
    e.iterator = function () {
      var i = 0;
      return { hasNext: function () { return i < e.length; }, next: function () { return e[i++]; } };
    };
    e.toString = function () { return '[' + e.map(String).join(', ') + ']'; };
    // ── 以下一批照抄老引擎的 patchElements —— 站方真在用（remove() 净化正文广告）⭐⭐⭐
    e.eq = function (i) { return e[Number(i) || 0] || null; };
    e.map = function (fn) { return Array.prototype.map.call(e, fn); };
    e.filter = function (fn) { return makeElements(Array.prototype.filter.call(e, fn), baseUrl); };
    e.not = function (s) { return makeElements(e.filter(function (x) { return !(x.hasClass && x.hasClass(s)); }), baseUrl); };
    e.eachText = function (fn) { e.forEach(function (x, i) { fn(x.text(), i); }); return e; };
    e.subList = function (from, to) { return makeElements(e.slice(from, to), baseUrl); };
    e.outerHtml = function () { return e[0] ? e[0].outerHtml() : ''; };
    e.hasAttr = function (n) { return e[0] ? e[0].hasAttr(n) : false; };
    e.eachHtml = function (fn) { e.forEach(function (x, i) { fn(x.html(), i); }); return e; };
    e.eachTag = function (fn) { e.forEach(function (x, i) { fn(x.tagName(), i); }); return e; };
    e.remove = function () { e.forEach(function (x) { x.remove(); }); return e; };
    e.before = function (h) { e.forEach(function (x) { x.before(h); }); return e; };
    e.after = function (h) { e.forEach(function (x) { x.after(h); }); return e; };
    e.append = function (h) { e.forEach(function (x) { x.append(h); }); return e; };
    e.prepend = function (h) { e.forEach(function (x) { x.prepend(h); }); return e; };
    e.empty = function () { e.forEach(function (x) { x.empty(); }); return e; };
    e.addClass = function (c) { e.forEach(function (x) { x.addClass(c); }); return e; };
    e.removeClass = function (c) { e.forEach(function (x) { x.removeClass(c); }); return e; };
    e.hasClass = function (c) { return e.length > 0 && e.every(function (x) { return x.hasClass(c); }); };
    e.xpath = function () { return []; };
    e.selN = e.xpath;
    e.sel = function (x) { return e[0] ? e[0].sel(x) : null; };
    e.selectFirst = function (s) { return e[0] ? e[0].selectFirst(s) : null; };
    return e;
  }

  /* ---------------- 挂到全局 ---------------- */
  var Jsoup = {
    parse: function (html, baseUrl) { return new Doc(parseHTML(html), baseUrl || ''); },
    parseBodyFragment: function (html, baseUrl) { return new Doc(parseHTML(html), baseUrl || ''); },
    clean: function (html) { return normalise(wholeTextOf(parseHTML(html))); },
    isBlank: function (s) { return s == null || !String(s).trim(); },
    Selector: { select: function (sel) { return { selector: sel }; } },
    Method: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE', HEAD: 'HEAD' }
  };

  var org = g.org = g.org || {};
  org.jsoup = org.jsoup || {};
  org.jsoup.Jsoup = Jsoup;
  org.jsoup.nodes = { Document: Doc, Element: El, TextNode: TextNode, Attributes: function () { return {}; } };
  org.jsoup.select = { Elements: makeElements, Selector: Jsoup.Selector, Evaluator: function () { return {}; } };
  org.jsoup.parser = { Parser: { parseHTML: function (h) { return Jsoup.parse(h); } } };
  if (!org.jsoup.Connection) {
    org.jsoup.Connection = function (url) {
      return { url: function () { return url; }, data: function () { return this; },
               header: function () { return this; }, method: function () { return this; },
               execute: function () { return { statusCode: 0, body: '' }; } };
    };
  }

  g.__qrOrgJsoup = { parseHTML: parseHTML, selectAll: selectAll, El: El, Doc: Doc, Elements: makeElements };
})(typeof globalThis !== 'undefined' ? globalThis : self);

"""##
}
