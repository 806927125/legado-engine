# 端到端 fixture（离线）

> **快照日期**：2026-10-23 · **来源**：<https://www.52dzxy.com>（书源「过期杂志」）
> **书源 JSON**：`source-52dzxy.json` —— 从 125 源包原样截取，**规则一个字没改**

## 三个页面

| 文件 | 字节 | 对应 URL | 用途 |
|---|---|---|---|
| `list.html` | 15,175 | `https://www.52dzxy.com/bkzs/all.html` | 发现页（`ruleExplore.bookList = .magazine-grid .magazine-item` ⇒ 60 本） |
| `detail.html` | 10,234 | `https://www.52dzxy.com/2026/bkzs/202614/index.html` | 详情页（**也是目录页** —— 该源 `ruleBookInfo.tocUrl` 为空 ⇒ 目录规则在详情页上跑） |
| `chapter.html` | 15,415 | `…/2026/bkzs/202614/articles/yizhiguanhuanweiyifashouzhuqingkong.html` | 正文页（`ruleContent.content = tag.p@html##我爱读者校园网`） |

## 为什么是快照

⚠️ **快照是固定的** ⇒ 站方改版**不会**让门禁变红（门禁验的是**引擎能力**，不是站方存活）。
⇒ 想验「站方现在还活着吗」⇒ 跑 `bash tools/fetch-fixtures.sh` 重新抓。

## 覆盖的流水线

```
categories()  分类  ← exploreUrl 是老式「标题::URL」多行 ⇒ 23 个分类
explore()     发现  ← list.html   ⇒ ruleExplore.bookList 命中 ⇒ 60 本
bookInfo()    详情  ← detail.html ⇒ 详情字段
toc()         目录  ← detail.html ⇒ ruleToc.chapterList 命中 ⇒ 10 卷标题 + 16 章节
content()     正文  ← chapter.html ⇒ ruleContent.content 命中 ⇒ 正文
```

## 这个 fixture 抓出来的四个引擎缺口

⭐ 这四个都是**站方规则逐字**暴露的，不是猜的：

1. **逗号被当兜底链** ⇒ 目录只出 10 个卷标题、16 个章节全丢
2. **尾部 `##正则##`（无替换）⇒ 整条规则返回空** ⇒ 正文全空
3. **「整条规则 = 取值模式」不支持** ⇒ `"chapterName": "text"` / `"chapterUrl": "href"` 永远查不到
4. **换行多规则只跑第一行**（轻阅同款债）

⇒ 对应的规格条目：§S-FBK-03 / §S-FBK-04 / §S-FBK-05 / §S-VAL-01 / §S-VAL-02

## 重新抓

```bash
bash tools/fetch-fixtures.sh
```
