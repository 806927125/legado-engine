# 端到端 fixture（离线）

> **快照日期**：2026-10-23 · **来源**：<https://www.52dzxy.com>（书源「过期杂志」）
> **书源 JSON**：`source-52dzxy.json` —— 从 125 源包原样截取，**规则一个字没改**

## 三个页面

| 文件 | 字节 | 对应 URL | 用途 |
|---|---|---|---|
| `list.html` | 15,175 | `https://www.52dzxy.com/bkzs/all.html` | 发现页（`ruleExplore.bookList = .magazine-grid .magazine-item` ⇒ 60 本） |
| `detail.html` | 10,234 | `https://www.52dzxy.com/2026/bkzs/202614/index.html` | 详情页（**也是目录页** —— 该源 `ruleBookInfo.tocUrl` 为空 ⇒ 目录规则在详情页上跑） |
| `search.html` | 76,045 | `https://book.eayue.com/ta/search.m?word=仙逍` | 搜索页（书源「神魔」，`ruleSearch` 全套语义） |
| `chapter.html` | 15,415 | `…/2026/bkzs/202614/articles/yizhiguanhuanweiyifashouzhuqingkong.html` | 正文页（`ruleContent.content = tag.p@html##我爱读者校园网`） |

## 为什么是快照

⚠️ **快照是固定的** ⇒ 站方改版**不会**让门禁变红（门禁验的是**引擎能力**，不是站方存活）。
⇒ 想验「站方现在还活着吗」⇒ 跑 `bash tools/fetch-fixtures.sh` 重新抓。

### 搜索 fixture（书源「神魔」`source-eayue.json`）

| 文件 | 对应 URL | 用途 |
|---|---|---|
| `source-eayue.json` | — | 真书源（125 源包原样截取，**规则一字未改**） |
| `search.html` | `https://book.eayue.com/ta/search.m?word=仙逍` | 搜索结果页（`.show > ul > li` × 20） |

⚠️ 这个源一条规则覆盖了搜索路径的**全套语义**：
`bookList: ".show@li"`（CSS + 相对求值）· `name: ".title@text"`（取值模式）·
`bookUrl: "tag.li@onclick##clickChargeBook\('(.*?)',(.*?)\)##novel.m?gid=$1&nid=$2"`
（**尾部正则 + 捕获组替换 + 相对地址绝对化**）· `exploreUrl` 是**新版 JSON 数组** ·
`ruleBookInfo.tocUrl` 是「**尾部正则 + 换行 + `<js>` 块**」的复合形态。

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
