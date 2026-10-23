# 双实现对拍报告

> Swift 侧 = **自研实现**（照 `docs/legado-semantics.md` 写的）
> JS 侧 = **轻阅现有引擎**（`reference/js/`，只读参考，不改）
> 同一份 fixture ⇒ **差异 = 待查的债**（可能是轻阅的 bug，也可能是规格写错了 —— 两边都要人看一眼）

| 指标 | 值 |
|---|---|
| 用例总数 | 127 |
| 两边一致 | **90** |
| 存在差异 | **37** |

## 差异明细

| 用例 | 规格期望 | Swift（自研） | JS（轻阅参考） | 判定 |
|---|---|---|---|---|
| `chain-01` | `sub` | `sub` | `attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-02` | `sub` | `sub` | `attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-03` | `sub,attr` | `sub,attr` | `attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-04` | `sub,attr` | `sub,attr` | `attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-05` | `sub,attr` | `sub,attr` | `attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-06` | `sub` | `sub` | `attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-20` | `sub,attr` | `sub,attr` | `attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-22` | `sub,attr` | `sub,attr` | `attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-30` | `sub,sub,attr` | `sub,sub,attr` | `attr,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `diag-01` | `{"conclusion":"unsupported","hard":"1"}` | `{"conclusion":"unsupported","hard":"1"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `diag-02` | `{"conclusion":"unsupported","hard":"1"}` | `{"conclusion":"unsupported","hard":"1"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `diag-03` | `{"conclusion":"rule-not-matched","hard":"0"}` | `{"conclusion":"rule-not-matched","hard":"0"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `diag-04` | `{"conclusion":"unsupported","hard":"1"}` | `{"conclusion":"unsupported","hard":"1"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `diag-05` | `{"conclusion":"unsupported","hard":"1"}` | `{"conclusion":"unsupported","hard":"1"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `dom-01` | `{"count":2,"texts":["第一章 风起","第二章 云涌"]}` | `{"count":2,"texts":["第一章 风起","第二章 云涌"]}` | `{"count":1,"texts":["第一章 风起第二章 云涌"]}` | **轻阅的 bug**（自研已按规格修对） |
| `dom-05` | `{"count":1,"texts":["第二章 云涌"]}` | `{"count":1,"texts":["第二章 云涌"]}` | `{"count":1,"texts":["第一章 风起第二章 云涌"]}` | **轻阅的 bug**（自研已按规格修对） |
| `dom-06` | `{"count":0,"texts":[]}` | `{"count":0,"texts":[]}` | `{"count":1,"texts":["第一章 风起第二章 云涌"]}` | **轻阅的 bug**（自研已按规格修对） |
| `fbk-04` | `{"count":2}` | `{"count":2}` | `{"count":1}` | **轻阅的 bug**（自研已按规格修对） |
| `json-03` | `{"values":["{\"title\":\"章节名\",\"url\":\"u1\"}"]}` | `{"values":["{\"title\":\"章节名\",\"url\":\"u1\"}"]}` | `{"values":["\tu1"]}` | **轻阅的 bug**（自研已按规格修对） |
| `json-04` | `{"value":"{\"title\":\"章节名\",\"url\":\"u1\"}"}` | `{"value":"{\"title\":\"章节名\",\"url\":\"u1\"}"}` | `{"value":"\tu1"}` | **轻阅的 bug**（自研已按规格修对） |
| `put-01` | `{"value":"https://x.example/read/XID-001/1.html"}` | `{"value":"https://x.example/read/XID-001/1.html"}` | `{"value":"https://x.example/read//1.html"}` | **轻阅的 bug**（自研已按规格修对） |
| `sel-08b` | `{"count":1}` | `{"count":1}` | `{"count":2}` | **轻阅的 bug**（自研已按规格修对） |
| `sel-10` | `{"count":2}` | `{"count":2}` | `{"count":0}` | **轻阅的 bug**（自研已按规格修对） |
| `sel-14` | `{"count":2}` | `{"count":2}` | `{"count":0}` | **轻阅的 bug**（自研已按规格修对） |
| `url-01` | `method="GET",body="",url="https://x.com/s?q=%E6%90%9C%E7%B4%A2%E8%AF%8D"` | `method="GET",body="",url="https://x.com/s?q=%E6%90%9C%E7%B4%A2%E8%AF%8D"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-02` | `method="GET",body="",url="https://x.com/s?id=MTgzNTEy%2Bq"` | `method="GET",body="",url="https://x.com/s?id=MTgzNTEy%2Bq"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-03` | `method="GET",body="",url="https://x.com/s?q=a%20b"` | `method="GET",body="",url="https://x.com/s?q=a%20b"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-04` | `method="POST",body="{\"a\":1}",url="https://x.com/api",ct="application/json; charset=utf-8"` | `method="POST",body="{\"a\":1}",url="https://x.com/api",ct="application/json; charset=utf-8"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-05` | `method="POST",body="a=1&b=2",url="https://x.com/api",ct="application/x-www-form-urlencoded; charset=utf-8"` | `method="POST",body="a=1&b=2",url="https://x.com/api",ct="application/x-www-form-urlencoded; charset=utf-8"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-06` | `method="POST",body="x=1",url="https://x.com/api",ct="text/plain"` | `method="POST",body="x=1",url="https://x.com/api",ct="text/plain"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-07` | `method="GET",body="",url="data:;base64,eyJ0YWI6Im5vdmVsIn0+,{\"type\":\"qingtian\"}"` | `method="GET",body="",url="data:;base64,eyJ0YWI6Im5vdmVsIn0+,{\"type\":\"qingtian\"}"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-08` | `method="GET",body="",url="https://book.example.com/api/book/1"` | `method="GET",body="",url="https://book.example.com/api/book/1"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-09` | `method="GET",body="",url="https://cdn.example.com/a.png"` | `method="GET",body="",url="https://cdn.example.com/a.png"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-10` | `method="GET",body="",url="https://x.com/api"` | `method="GET",body="",url="https://x.com/api"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-11` | `method="GET",body="",url="https://x.com/d?book_id=x&source=%E7%95%AA%E8%8C%84&variable=%7B%22custom%22%3A%22%22%7D"` | `method="GET",body="",url="https://x.com/d?book_id=x&source=%E7%95%AA%E8%8C%84&variable=%7B%22custom%22%3A%22%22%7D"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `url-12` | `method="GET",body="",url="https://x.com/a,b"` | `method="GET",body="",url="https://x.com/a,b"` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |
| `val-01` | `{"value":"主标题"}` | `{"value":"主标题"}` | `SKIPPED` | **轻阅的 bug**（自研已按规格修对） |

## 说明

- **Swift 侧不符**（0 条）⇒ 自研实现还没写完 / 写错了。
- **JS 侧不符**（19 条）⇒ 轻阅现有实现与规格不一致（多数是**已知债**）。
- 两边都跑不了的用例（`SKIPPED`）⇒ 属于后续切片（需要 DOM / JS 后端）。
