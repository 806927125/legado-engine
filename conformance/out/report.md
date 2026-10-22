# 双实现对拍报告

> Swift 侧 = **自研实现**（照 `docs/legado-semantics.md` 写的）
> JS 侧 = **轻阅现有引擎**（`reference/js/`，只读参考，不改）
> 同一份 fixture ⇒ **差异 = 待查的债**（可能是轻阅的 bug，也可能是规格写错了 —— 两边都要人看一眼）

| 指标 | 值 |
|---|---|
| 用例总数 | 79 |
| 两边一致 | **70** |
| 存在差异 | **9** |

## 差异明细

| 用例 | 规格期望 | Swift（自研） | JS（轻阅参考） | 判定 |
|---|---|---|---|---|
| `chain-01` | `sub,sub` | `sub,sub` | `sub,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-02` | `sub,sub` | `sub,sub` | `sub,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-03` | `sub,sub,attr` | `sub,sub,attr` | `sub,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-04` | `sub,sub,attr` | `sub,sub,attr` | `sub,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-05` | `sub,sub,attr` | `sub,sub,attr` | `sub,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-06` | `sub,sub` | `sub,sub` | `sub,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-20` | `sub,sub,attr` | `sub,sub,attr` | `sub,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-22` | `sub,sub,attr` | `sub,sub,attr` | `sub,attr,attr` | **轻阅的 bug**（自研已按规格修对） |
| `chain-30` | `sub,sub,sub,attr` | `sub,sub,sub,attr` | `sub,attr,attr,attr` | **轻阅的 bug**（自研已按规格修对） |

## 说明

- **Swift 侧不符**（0 条）⇒ 自研实现还没写完 / 写错了。
- **JS 侧不符**（60 条）⇒ 轻阅现有实现与规格不一致（多数是**已知债**）。
- 两边都跑不了的用例（`SKIPPED`）⇒ 属于后续切片（需要 DOM / JS 后端）。
