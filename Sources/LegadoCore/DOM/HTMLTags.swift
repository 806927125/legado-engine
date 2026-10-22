import Foundation

/// 常见 HTML 标签名集合。
///
/// ⚠️ **这份表是「语义定义」的一部分**，不是实现细节：
/// 它决定「链段里的裸名算不算子选择器」（规格 §S-SEL-06）。
/// ⇒ 改它 = 改语义 ⇒ 必须同步改 fixture + 跑对拍。
public let HTMLTagNames: Set<String> = [
    "a","abbr","address","area","article","aside","audio","b","base","bdi","bdo",
    "blockquote","body","br","button","canvas","caption","cite","code","col",
    "colgroup","data","datalist","dd","del","details","dfn","dialog","div","dl",
    "dt","em","embed","fieldset","figcaption","figure","footer","form","h1","h2",
    "h3","h4","h5","h6","head","header","hgroup","hr","html","i","iframe","img",
    "input","ins","kbd","label","legend","li","link","main","map","mark","menu",
    "meta","meter","nav","noscript","object","ol","optgroup","option","output",
    "p","param","picture","pre","progress","q","rp","rt","ruby","s","samp",
    "script","section","select","slot","small","source","span","strong","style",
    "sub","summary","sup","table","tbody","td","template","textarea","tfoot",
    "th","thead","time","tr","track","u","ul","var","video","wbr",
]
