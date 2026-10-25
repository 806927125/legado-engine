#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **Node 驱动的 JS 执行器（长驻进程）** —— 让 Linux 沙盒能「真跑站方 JS」
 *
 * **为什么需要它**（2026-10-25 真机 JM小说 实证）：
 * · 站方 JS 里有**自定义加密**（`hjmDec` = base64 + 字节反转 + 二次解码）
 *   ⇒ **必须真跑 JS** 才能验 ⇒ 手写 stub 会「假定 result 是页原文」⇒ **测不出真机的问题** ⭐⭐⭐
 * · Linux 沙盒**没有 JSC** ⇒ 真机行为没法复现 ⇒ 只能一轮轮出包试 ⇒ 用户受挫 ⭐⭐⭐
 * ⇒ 本脚本用 **Node 的 `vm`**（语义与 JSC 的 `eval` 完成值一致）⇒ 把「贵平台」搬到便宜平台 ⭐⭐⭐
 *
 * **协议**（一行一个 JSON，靠 stdout 回一行 JSON）：
 * - `{"cmd":"loadGlobal","code":"..."}`  ⇒ 间接 eval（全局作用域）⇒ 站方 jsLib 用
 * - `{"cmd":"run","code":"...","result":"...","baseUrl":"","key":"","page":1,"vars":{}}`
 *   ⇒ 复刻引擎的包装：`scope + "(function(){ return eval(<codeLiteral>); })()"`
 * - `{"cmd":"ping"}` ⇒ 存活探测
 *
 * ⚠️ **必须复刻引擎的包装**（不是直接 eval 站方代码）：
 *   引擎是 `eval(codeLiteral)`（代码是**字符串字面量**）⇒ 完成值 = eval 的值 ⭐⭐⭐
 *   ⇒ 直接 `eval(code)` 语义**不同**（`var` 会进 eval 的作用域）⇒ 会造成假绿/假红 ⭐⭐⭐
 */
'use strict';
const vm = require('vm');
const readline = require('readline');

const ctx = vm.createContext({ console });

/** ⭐ JSON 字面量（与引擎的 `JSScopeBuilder.jsonLiteral` 同口径） */
function jsonLiteral(v) {
  return JSON.stringify(v);
}

/** ⭐⭐⭐ 复刻引擎的 scope + eval 包装 */
function buildSource(code, req) {
  const scope = [];
  // ⭐⭐⭐⭐⭐ **result 用【字面量】**（与引擎的 JSScopeBuilder 同口径）
  //   ⇒ 传 JSON 值会丢结构（对象 ⇒ `RuleValue.text` 是空串）⇒ 假失败 ⭐⭐⭐
  scope.push('var result = ' + (req.resultLiteral !== undefined
    ? req.resultLiteral
    : jsonLiteral(req.result === undefined ? '' : req.result)) + ';');
  scope.push('var baseUrl = ' + jsonLiteral(req.baseUrl || '') + ';');
  scope.push('var key = ' + jsonLiteral(req.key || '') + ';');
  scope.push('var page = ' + (req.page || 1) + ';');
  if (req.vars && Object.keys(req.vars).length) {
    scope.push('var variables = ' + JSON.stringify(req.vars) + ';');
  }
  for (const [k, v] of Object.entries(req.extra || {})) {
    scope.push('var ' + k + ' = ' + jsonLiteral(v) + ';');
  }
  return scope.join('\n') + '\n' +
         '(function(){ return eval(' + jsonLiteral(code) + '); })()';
}

const rl = readline.createInterface({ input: process.stdin });

rl.on('line', (line) => {
  let req;
  try { req = JSON.parse(line); }
  catch (e) { process.stdout.write(JSON.stringify({ ok: false, error: 'bad json: ' + e.message }) + '\n'); return; }

  try {
    if (req.cmd === 'ping') {
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
      return;
    }
    if (req.cmd === 'loadGlobal') {
      // ⭐ 间接 eval ⇒ 全局作用域（站方 jsLib 的 var/function 要留在全局）
      vm.runInContext('(0, eval)(' + jsonLiteral(req.code) + ')', ctx);
      process.stdout.write(JSON.stringify({ ok: true }) + '\n');
      return;
    }
    if (req.cmd === 'run') {
      const src = buildSource(req.code, req);
      const out = vm.runInContext(src, ctx);
      process.stdout.write(JSON.stringify({ ok: true, value: out === undefined ? null : out }) + '\n');
      return;
    }
    process.stdout.write(JSON.stringify({ ok: false, error: 'unknown cmd: ' + req.cmd }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(e && e.message || e) }) + '\n');
  }
});
