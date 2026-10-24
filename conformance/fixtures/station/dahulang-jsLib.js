var host = [
    'https://v5.langge.uk',
    'http://219.154.201.122:5006',
    'https://v4.langge.uk',
    'https://v2.langge.uk',
    'https://v7.langge.uk',
    'https://v8.langge.uk',
    'https://v9.langge.uk',
    'https://v10.langge.uk'
];

function getArguments(open_argument, key) {
    try {
        open_argument = JSON.parse(open_argument);
    } catch (e) {
        open_argument = {
            tab: "小说",
            tone_id: "默认音色",
            shuqi_tone_id: "multi_role",
            server: host[0],
            sources: "全部",
            source_type: "男频",
            fqpara: "on",
            fqcommunity: "on",
            pstyle: "0",
        };
    }
    // 旧版本没有保存 fqpara 字段；缺失时按“开启”处理。
    // 用户明确选择 off 时仍然保留关闭状态。
    if (open_argument.fqpara === undefined || open_argument.fqpara === null || open_argument.fqpara === '') {
        open_argument.fqpara = 'on';
    }
    if (!open_argument.shuqi_tone_id || open_argument.shuqi_tone_id === '默认音色') {
        open_argument.shuqi_tone_id = 'multi_role';
    }
    if (key) {
        return open_argument[key];
    } else {
        return open_argument;
    }
}

function setArguments(key, value) {
    const {
        source
    } = this;
    let open_argument = source.getVariable();
    open_argument = getArguments(open_argument, '');
    open_argument[key] = value;
    open_argument = JSON.stringify(open_argument);
    source.setVariable(open_argument);
    return open_argument;
}

function getFanqieCookie() {
    var cookieManager = null;
    try {
        cookieManager = this.cookie;
    } catch (e) {}
    if (!cookieManager) {
        try {
            if (typeof cookie !== 'undefined') cookieManager = cookie;
        } catch (e) {}
    }
    if (!cookieManager || typeof cookieManager.getCookie !== 'function') return '';

    var hosts = [
        'fanqienovel.com',
        'https://fanqienovel.com/',
        'https://fanqienovel.com',
        'https://api5-normal-sinfonlinec.fqnovel.com/'
    ];
    var fallback = '';
    for (var i = 0; i < hosts.length; i++) {
        try {
            var value = String(cookieManager.getCookie(hosts[i]) || '');
            if (!fallback && value) fallback = value;
            if (/(?:^|;\s*)sessionid(?:_ss)?=/.test(value)) return value;
        } catch (e) {}
    }
    return fallback;
}

function getSessionId(cookieValue) {
    var value = String(cookieValue || '');
    var match = value.match(/(?:^|;\s*)sessionid(?:_ss)?=([^;]+)/);
    if (!match) return '';
    try {
        return decodeURIComponent(match[1]);
    } catch (e) {
        return match[1];
    }
}

function escapeFanqieCommunityText(value) {
    return String(value || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function normalizeFanqieCommunityText(value) {
    return String(value || '').replace(/\s+/g, ' ').trim();
}

function shortenFanqieCommunityText(value, maxLength) {
    var text = normalizeFanqieCommunityText(value);
    if (!maxLength || text.length <= maxLength) return text;
    return text.substring(0, Math.max(1, maxLength - 1)) + '\u2026';
}

var FANQIE_EMOJI_PATHS = {
    "[微笑]": "/static/emoji/emoji_dr_1.png",
    "[偷笑]": "/static/emoji/emoji_dr_2.png",
    "[笑]": "/static/emoji/emoji_dr_3.png",
    "[什么]": "/static/emoji/emoji_dr_4.png",
    "[害羞]": "/static/emoji/emoji_dr_5.png",
    "[爱慕]": "/static/emoji/emoji_dr_6.png",
    "[飞吻]": "/static/emoji/emoji_dr_7.png",
    "[奸笑]": "/static/emoji/emoji_dr_8.png",
    "[尬笑]": "/static/emoji/emoji_dr_9.png",
    "[思考]": "/static/emoji/emoji_dr_10.png",
    "[撇嘴]": "/static/emoji/emoji_dr_11.png",
    "[做鬼脸]": "/static/emoji/emoji_dr_12.png",
    "[酷]": "/static/emoji/emoji_dr_13.png",
    "[翻白眼]": "/static/emoji/emoji_dr_14.png",
    "[惊呆]": "/static/emoji/emoji_dr_15.png",
    "[震惊]": "/static/emoji/emoji_dr_16.png",
    "[送心]": "/static/emoji/emoji_dr_17.png",
    "[委屈]": "/static/emoji/emoji_dr_18.png",
    "[快哭了]": "/static/emoji/emoji_dr_19.png",
    "[笑哭]": "/static/emoji/emoji_dr_20.png",
    "[哭]": "/static/emoji/emoji_dr_21.png",
    "[大笑]": "/static/emoji/emoji_dr_22.png",
    "[舔屏]": "/static/emoji/emoji_dr_23.png",
    "[怒]": "/static/emoji/emoji_dr_24.png",
    "[捂脸]": "/static/emoji/emoji_dr_25.png",
    "[吐]": "/static/emoji/emoji_dr_26.png",
    "[恐惧]": "/static/emoji/emoji_dr_27.png",
    "[抓狂]": "/static/emoji/emoji_dr_28.png",
    "[敬礼]": "/static/emoji/emoji_dr_29.png",
    "[石化]": "/static/emoji/emoji_dr_30.png",
    "[OK]": "/static/emoji/emoji_dr_31.png",
    "[赞]": "/static/emoji/emoji_dr_32.png",
    "[爱心]": "/static/emoji/emoji_dr_33.png",
    "[伤心]": "/static/emoji/emoji_dr_34.png",
    "[KISS]": "/static/emoji/emoji_dr_35.png",
    "[懂了]": "/static/emoji/emoji_dr_36.png",
    "[探究]": "/static/emoji/emoji_dr_37.png",
    "[重拳出击]": "/static/emoji/emoji_dr_38.png",
    "[吃瓜]": "/static/emoji/emoji_dr_39.png",
    "[盯]": "/static/emoji/emoji_dr_40.png",
    "[你细品]": "/static/emoji/emoji_dr_41.png",
    "[赶稿中]": "/static/emoji/emoji_dr_42.png",
    "[注意]": "/static/emoji/emoji_dr_43.png",
    "[饱了]": "/static/emoji/emoji_dr_44.png",
    "[码住]": "/static/emoji/emoji_dr_45.png",
    "[学会了]": "/static/emoji/emoji_dr_46.png",
    "[顶帖]": "/static/emoji/emoji_dr_47.png",
    "[求爆更]": "/static/emoji/emoji_dr_48.png",
    "[求关注]": "/static/emoji/emoji_dr_49.png",
    "[我也强推]": "/static/emoji/emoji_dr_50.png",
    "[雀食神作]": "/static/emoji/emoji_dr_51.png",
    "[已种草]": "/static/emoji/emoji_dr_52.png",
    "[书架加一]": "/static/emoji/emoji_dr_53.png",
    "[歪头笑哭]": "/static/emoji/emoticon_emoji_wtxk.png",
    "[神评]": "/static/emoji/emoticon_xiaoqi_sp.png",
    "[狗头]": "/static/emoji/emoticon_emoji_doge.png",
    "[哈哈]": "/static/emoji/emoticon_emoji_hhh.png",
    "[流泪]": "/static/emoji/emoticon_emoji_tears.png",
    "[可爱]": "/static/emoji/emoticon_emoji_cute.png",
    "[色]": "/static/emoji/emoticon_emoji_smimi.png",
    "[调皮]": "/static/emoji/emoticon_emoji_tpi.png",
    "[小七_神评]": "/static/emoji/emoticon_xiaoqi_sp.png",
    "[小七_狗头]": "/static/emoji/emoticon_xiaoqi_gt.png",
    "[小七_鄙视]": "/static/emoji/emoticon_xiaoqi_bs.png",
    "[小七_高兴]": "/static/emoji/emoticon_xiaoqi_gx.png",
    "[小七_黑人问号]": "/static/emoji/emoticon_xiaoqi_hrwh.png",
    "[小七_厉害]": "/static/emoji/emoticon_xiaoqi_lh.png",
    "[小七_流泪]": "/static/emoji/emoticon_xiaoqi_ll.png",
    "[小七_OK]": "/static/emoji/emoticon_xiaoqi_ok.png",
    "[小七_色]": "/static/emoji/emoticon_xiaoqi_s.png",
    "[小七_伤心]": "/static/emoji/emoticon_xiaoqi_sx.png",
    "[小七_调皮]": "/static/emoji/emoticon_xiaoqi_tq.png",
    "[小七_委屈]": "/static/emoji/emoticon_xiaoqi_wh.png",
    "[小七_笑哭]": "/static/emoji/emoticon_xiaoqi_xk.png",
    "[小七_笑嘻嘻]": "/static/emoji/emoticon_xiaoqi_xxy.png",
    "[小七_斜眼笑]": "/static/emoji/emoticon_xiaoqi_xyx.png",
    "[小七_赞美]": "/static/emoji/emoticon_xiaoqi_zm.png",
    "[眯眼笑]": "/static/emoji/emoticon_xiaoqi_xxy.png"
};

function getFanqieEmojiMap(baseUrl) {
    var root = String(baseUrl || "").replace(/\/$/, "");
    var result = {};
    Object.keys(FANQIE_EMOJI_PATHS).forEach(function(name) {
        result[name] = root + FANQIE_EMOJI_PATHS[name];
    });
    return result;
}

var FANQIE_CARD_EMOJI_TEXT = {
    "[微笑]":"😊","[偷笑]":"😏","[笑]":"😁","[什么]":"🤔","[害羞]":"😳","[爱慕]":"😍","[飞吻]":"😘","[奸笑]":"😏","[尬笑]":"😅","[思考]":"🤔","[撇嘴]":"😒","[做鬼脸]":"😜","[酷]":"😎","[翻白眼]":"🙄","[惊呆]":"😲","[震惊]":"😱","[送心]":"❤️","[委屈]":"🥺","[快哭了]":"😭","[笑哭]":"😂","[哭]":"😢","[大笑]":"😆","[舔屏]":"😋","[怒]":"😡","[捂脸]":"🤦","[吐]":"🤮","[恐惧]":"😨","[抓狂]":"😫","[敬礼]":"🫡","[石化]":"🗿","[OK]":"👌","[赞]":"👍","[爱心]":"💖","[伤心]":"💔","[KISS]":"💋","[懂了]":"✅","[探究]":"🔎","[重拳出击]":"👊","[吃瓜]":"🍉","[盯]":"👀","[你细品]":"🤌","[赶稿中]":"✍️","[注意]":"⚠️","[饱了]":"😋","[码住]":"🔖","[学会了]":"✅","[顶帖]":"📌","[求爆更]":"🙏","[求关注]":"🔔","[我也强推]":"🚀","[雀食神作]":"👍","[已种草]":"🌱","[书架加一]":"📚+1","[歪头笑哭]":"😂","[神评]":"🌟","[狗头]":"🐶","[哈哈]":"😆","[流泪]":"😭","[可爱]":"🥰","[色]":"😍","[调皮]":"😜","[小七_神评]":"🌟","[小七_狗头]":"🐶","[小七_鄙视]":"😒","[小七_高兴]":"😊","[小七_黑人问号]":"❓","[小七_厉害]":"👍","[小七_流泪]":"😭","[小七_OK]":"👌","[小七_色]":"😍","[小七_伤心]":"💔","[小七_调皮]":"😜","[小七_委屈]":"🥺","[小七_笑哭]":"😂","[小七_笑嘻嘻]":"😁","[小七_斜眼笑]":"😏","[小七_赞美]":"👏","[眯眼笑]":"😁"
};

function splitFanqieGodNoteEmojis(value, baseUrl, sources) {
    var text = String(value || "").replace(/\[[^\[\]]+\]/g, function(token) {
        return FANQIE_CARD_EMOJI_TEXT[token] || token;
    }).replace(/\s+/g, " ").trim();
    return { text: text, images: "" };
}
function decodeFanqieNoteText(value) {
    return String(value || '')
        .replace(/&#x([0-9a-f]+);/gi, function(_match, code) {
            return String.fromCharCode(parseInt(code, 16));
        })
        .replace(/&#([0-9]+);/g, function(_match, code) {
            return String.fromCharCode(parseInt(code, 10));
        })
        .replace(/&quot;/g, '"')
        .replace(/&apos;|&lsquo;|&rsquo;/g, "'")
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&amp;/g, '&');
}

// 将后端返回的 <note> 神评标签转换成阅读/源阅可渲染的 SVG 卡片。
function getFanqieNoteAttribute(noteTag, name) {
    var reg = new RegExp(name + '=\"([^\"]*)\"');
    var match = String(noteTag || '').match(reg);
    if (!match) return '';
    try { return decodeFanqieNoteText(match[1]); } catch (e) { return match[1]; }
}

function cleanFanqieGodNoteText(value) {
    var text = String(value || '')
        .replace(/<[^>]*>/g, ' ')
        .replace(/\[fn=(\d+)\]/g, '[表情]')
        .replace(/\s+/g, ' ')
        .trim();
    return text;
}

function createFanqieGodNoteCard(noteTag, sources) {
    var noteUrl = getFanqieNoteAttribute(noteTag, 'ident');
    var rawNoteText = getFanqieNoteAttribute(noteTag, 'text');
    var noteText = cleanFanqieGodNoteText(rawNoteText);
    if (!noteText) return '';
    var originMatch = String(noteUrl || '').match(/^(https?:\/\/[^\/]+)/);
    var baseUrl = originMatch ? originMatch[1] : getArguments(this.source.getVariable(), 'server');
    var isShuqi = String(sources || '').indexOf('书旗') >= 0;
    var jc = 'js';
    try { if (this.checkEnv() == '改版') jc = 'click'; } catch (e) {}
    var actionUrl = String(noteUrl || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/[\r\n]/g, '');
    var title = String(sources || '番茄').replace(/'/g, '');
    var meta = '{"' + jc + '":"showCmt(\'' + actionUrl + '\',\'' + title + '\',\'段评\')","style":"FULL"}';
    if (isShuqi) {
        var cardUrl = String(baseUrl || '').replace(/\/$/, '') + '/shuqi_god_card_svg?text=' + encodeURIComponent(rawNoteText) + '&v=4';
        return '<img src="' + cardUrl + ',' + meta + '">';
    }
    var emojiResult = splitFanqieGodNoteEmojis(rawNoteText, baseUrl, sources);
    var displayText = shortenFanqieCommunityText(cleanFanqieGodNoteText(emojiResult.text), 27);
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="108" viewBox="0 0 1000 108">' +
        '<rect width="100%" height="100%" fill="rgba(255,255,255,0.55)" rx="30"/>' +
        '<rect x="35" y="28" width="125" height="52" rx="16" fill="#F06260"/>' +
        '<text x="97" y="65" font-size="32" fill="#FFFFFF" text-anchor="middle" font-weight="bold">神评论</text>' +
        '<text x="175" y="67" font-size="38" fill="#333333">' + escapeFanqieCommunityText(displayText) + '</text>' +
        '</svg>';
    return '<img src="data:image/svg+xml;base64,' + this.java.base64Encode(svg) + ',' + meta + '">';
}
function renderFanqieGodNoteCards(value, sources) {
    var runtime = this;
    return String(value || '').replace(/<note\b[^>]*>(?:<\/note>)?/g, function(noteTag) {
        return createFanqieGodNoteCard.call(runtime, noteTag, sources) || '';
    });
}
function checkEnv() {
    const {
        java,
        source
    } = this;

    try {
        java.qread();
        return "轻阅读";
    } catch (e) {}

    try {
        if (typeof java.reLoginView == 'function') {
            return "改版";
        }
        new Packages.io.legato.kazusa.utils.TimeoutCancellationException('');
        return "改版";
    } catch (e) {}
    try {
        java.deviceID();
        return "苹果";
    } catch (e) {}

    if (typeof source.loginUi == 'function') {
        return "安卓";
    }

    return "改版";
}

// 获取番茄token

function createGod(url,svg) {
    var jc = 'js';
    let islyc = this.checkEnv()
    if (islyc == "改版") {
        jc = 'click'
    }
   let cz= `{"${jc}":"showCmt('${url}','段评' )","style":"FULL"}`
	let img = `<img src="${svg},${cz}">`
	return img
	}

let svgs = ["<svg t='1760002253572' class='icon' viewBox='-150 0 1224 1224' version='1.1' xmlns='http://www.w3.org/2000/svg' p-id='1490' width='800' height='800'><g transform='rotate(90 512 512) scale(1 1.2)'><path d='M224 149.333333h576c40.533333 0 74.666667 34.133333 74.666667 74.666667v460.8c0 40.533333-34.133333 74.666667-74.666667 74.666667h-108.8c-40.533333 0-78.933333 17.066667-104.533334 46.933333l-49.066666 55.466667c-4.266667 6.4-14.933333 10.666667-23.466667 10.666667-10.666667 0-19.2-4.266667-25.6-10.666667l-46.933333-55.466667c-25.6-29.866667-64-46.933333-104.533334-46.933333h-110.933333c-40.533333 0-74.666667-34.133333-74.666667-74.666667V224c0-40.533333 34.133333-74.666667 74.666667-74.666667z' fill='$tccolor' p-id='1529'></path><path d='M512 938.666667c-27.733333 0-55.466667-12.8-72.533333-34.133334l-46.933334-55.466666c-14.933333-17.066667-34.133333-25.6-57.6-25.6h-110.933333c-76.8 0-138.666667-61.866667-138.666667-138.666667V224C85.333333 147.2 147.2 85.333333 224 85.333333h573.866667c76.8 0 138.666667 61.866667 138.666666 138.666667v460.8c0 76.8-61.866667 138.666667-138.666666 138.666667h-108.8c-21.333333 0-42.666667 8.533333-55.466667 25.6l-49.066667 55.466666c-17.066667 21.333333-44.8 34.133333-72.533333 34.133334zM224 149.333333C183.466667 149.333333 149.333333 183.466667 149.333333 224v460.8c0 40.533333 34.133333 74.666667 74.666667 74.666667h110.933333c40.533333 0 78.933333 17.066667 104.533334 49.066666l46.933333 55.466667c6.4 6.4 14.933333 10.666667 25.6 10.666667 8.533333 0 19.2-4.266667 23.466667-10.666667l49.066666-55.466667c25.6-29.866667 64-46.933333 104.533334-46.933333h108.8c40.533333 0 74.666667-34.133333 74.666666-74.666667V224C874.666667 183.466667 840.533333 149.333333 800 149.333333h-576z' fill='$color' p-id='1530'></path> </g><text x='460' y='650' font-family='Arial, sans-serif' text-anchor='middle' font-size='400' fill='$fontcolor'>$displayText</text></svg>"];


// 创建svg

function showFanqieComment(url, title) {
    let { java } = this;
    title = title || '本章说';
    let pageUrl = String(url || '');
    if (!pageUrl) {
        try { java.toast('评论地址为空，请刷新本章'); } catch (e) {}
        return;
    }
    let islyc = this.checkEnv();
    try {
        if (islyc == '轻阅读') {
            java.startBrowserDp(pageUrl, title);
            return;
        }
        if (islyc == '改版') {
            let htmlContent = java.ajax(pageUrl);
            java.showBrowser(
                pageUrl,
                htmlContent,
                `window.java=java;`,
                JSON.stringify({
                    "expandedCornersRadius": 20,
                    "dismissOnTouchOutside": true,
                    "isDraggable": true,
                    "shouldDimBackground": true,
                    "backgroundDimAmount": 0.5,
                    "hardwareAccelerated": true,
                    "isNestedScrollingEnabled": true,
                    "isGestureInsetBottomIgnored": true,
                    "setFitToContents": true,
                    "isHideable": true,
                    "heightPercentage": 0.8
                })
            );
            return;
        }
        try {
            java.showReadingBrowser(pageUrl, title);
            return;
        } catch (e) {}
        java.startBrowser(pageUrl, title);
    } catch (e) {
        try { java.startBrowser(pageUrl, title); } catch (err) { java.log('打开番茄评论页失败:' + err); }
    }
}


// 生成本章说尾部卡片的点击协议，只负责打开官方评论聚合页，不复用段评点击逻辑。
function endclick(url, title) {
    var jc = 'js';
    let islyc = this.checkEnv();
    if (islyc == '改版') {
        jc = 'click';
    }
    title = title || '本章说';
    return `"${jc}":"showFanqieComment('${url}','${title}')"`;
}


function paraForAndroid(content, sources) {
    let {
        java,
        cache,
        source
    } = this;
    const createSvg = this.createSvg.bind(this);
    const createGod = this.createGod.bind(this);
    content = renderFanqieGodNoteCards.call(this, content, sources);
     content = content.replace(
        /<p><img ident="([^"]*)" src="([^"]*)"\s*\/><\/p>/g,
        (match, ident, src) => {
            return `<p>${createGod(ident, src)}</p>`;
        }
    );
    

    return content.replace(/<p>(.*?)(?:<comment ident="([^"]*)" count="([^"]*)" \/>)?<\/p>/g,
        (match, text, url, count) => {
            if (url && count) {
                const click = 0;
                cache.putMemory(url, click);
                const encodedUrl = url;
                return `<p>${text}<img src="${createSvg(count, encodedUrl,sources)}"></p>`;
            } else {
                return `<p>${text}</p>`;
            }
        }
    );
}
// 创建神评论

function showCmt(url, sources,ident) {
    let {
        java,
        cache
    } = this;
    if (ident == null) ident = '段评';
    const currentTime = Date.now();
    const click = cache.getFromMemory(url);
    let islyc = this.checkEnv()
    if (click < 1 && islyc == "安卓") {
        cache.putMemory(url, click + 1);
        return;
    } else {
        if (islyc == "轻阅读") {
            java.startBrowserDp(url, sources + ident);
        } else if (islyc == "改版") {
            let paradata = new Date().toLocaleDateString();
            let isQimaoComment = String(url || '').indexOf('/qimao_comment?') >= 0;
            let htmlContent = isQimaoComment ? '' : cache.get(paradata+ident+"new4");
            if (!htmlContent || String(htmlContent).indexOf("评论") == -1) {
                java.longToast(`\n${paradata} 初始化${ident}页面,请稍等~`);
                try {
                    htmlContent = java.ajax(url);
                } catch {

                }

                if (!isQimaoComment) cache.put(paradata+ident+"new4", htmlContent);
                java.longToast(`\n${paradata} 初始化${ident}页面成功~`);
            }
            java.showBrowser(
                url,
                htmlContent,
                `window.java=java;`,
                JSON.stringify({
                    "expandedCornersRadius": 20,
                    "dismissOnTouchOutside": true,
                    "isDraggable": true,
                    "shouldDimBackground": true,
                    "backgroundDimAmount": 0.5,
                    "hardwareAccelerated": true,
                    "isNestedScrollingEnabled": true,
                    "isGestureInsetBottomIgnored": true,
                    "setFitToContents": true,
                    "isHideable": true,
                    "heightPercentage": 0.8
                })
            );
        } else {
            java.startBrowser(url, sources + ident);
        }
    }
}

//源阅段评

function normalizeBubbleTemplateConfig(value, origin) {
    var result = {};
    if (!value || typeof value != 'object') return result;
    Object.keys(value).forEach(function(key) {
        var item = value[key];
        var data = item && typeof item == 'object' ? item : {svg: String(item || '')};
        var svg = String(data.svg || '');
        var renderPath = String(data.renderPath || data.renderUrl || '');
        if (svg.indexOf('<svg') < 0 && !renderPath) return;
        result[String(key)] = {
            name: String(data.name || ('样式 ' + key)),
            type: String(data.type || (renderPath ? 'image' : 'svg')),
            svg: svg,
            renderPath: renderPath,
            _origin: String(origin || '').replace(/\/$/, '')
        };
    });
    return result;
}

function getBubbleTemplates() {
    var now = Date.now();
    var memoryKey = '__bubble_templates_cache_v3__';
    try {
        if (this.cache && typeof this.cache.getFromMemory === 'function') {
            var cached = String(this.cache.getFromMemory(memoryKey) || '');
            if (cached) {
                var memory = JSON.parse(cached);
                if (memory && memory.templates && Object.keys(memory.templates).length && now - Number(memory.time || 0) < 30000) {
                    return memory.templates;
                }
            }
        }
    } catch (e) {}
    var server = String(getArguments(this.source.getVariable(), 'server') || host[0]).replace(/\/$/, '');
    var servers = [server].concat(host || []).filter(function(value, index, values) {
        value = String(value || '').replace(/\/$/, '');
        return value && values.map(function(item) { return String(item || '').replace(/\/$/, ''); }).indexOf(value) == index;
    });
    var paths = ['/api/bubbles?_=','/static/js/bubble_templates.json?_='];
    for (var i = 0; i < servers.length; i++) {
        var currentServer = String(servers[i]).replace(/\/$/, '');
        for (var pathIndex = 0; pathIndex < paths.length; pathIndex++) {
            try {
                var raw = String(this.java.ajax(currentServer + paths[pathIndex] + now) || '{}');
                var templates = normalizeBubbleTemplateConfig(JSON.parse(raw), currentServer);
                if (Object.keys(templates).length) {
                    try {
                        if (this.cache && typeof this.cache.putMemory === 'function') {
                            this.cache.putMemory(memoryKey, JSON.stringify({ time: now, templates: templates }));
                        }
                    } catch (e) {}
                    return templates;
                }
            } catch (e) {
                try { this.java.log('气泡模板加载失败: ' + e); } catch (_) {}
            }
        }
    }
    var fallback = {
        '0': {name: '经典气泡', type: 'svg', svg: svgs[0], renderPath: '', _origin: server}
    };
    try {
        if (this.cache && typeof this.cache.putMemory === 'function') {
            this.cache.putMemory(memoryKey, JSON.stringify({ time: now, templates: fallback }));
        }
    } catch (e) {}
    return fallback;
}

function createSvg(number, encodedUrl, sources) {
    var displayText = number > 99 ? "99+" : number.toString();
    let configuredColor = '';
    try {
        configuredColor = String(getArguments(this.source.getVariable(), "plcolor") || '').trim();
    } catch (e) {}
    let plcolor = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(configuredColor) ? configuredColor : "#A7A7A7";
    let bubbleStyle = String(getArguments(this.source.getVariable(), 'pstyle') || '0');
    let templates = getBubbleTemplates.call(this);
    if (!templates[bubbleStyle]) bubbleStyle = Object.keys(templates)[0] || '0';
    let selectedTemplate = templates[bubbleStyle] || templates['0'];
    var jc = 'js';
    let islyc = this.checkEnv();
    if (islyc == "改版") jc = 'click';
    let style = 'text';
    var action = '{"' + jc + '":"showCmt(\'' + encodedUrl + '\', \'' + sources + '\' ,\'段评\')","style":"' + style + '"}';

    if (selectedTemplate && selectedTemplate.renderPath) {
        var renderPath = String(selectedTemplate.renderPath || '');
        var renderUrl = /^https?:\/\//i.test(renderPath)
            ? renderPath
            : String(selectedTemplate._origin || getArguments(this.source.getVariable(), 'server') || host[0]).replace(/\/$/, '') + (renderPath.charAt(0) == '/' ? renderPath : '/' + renderPath);
        renderUrl += (renderUrl.indexOf('?') >= 0 ? '&' : '?') + 'count=' + encodeURIComponent(displayText) + '&color=' + encodeURIComponent(plcolor);
        return renderUrl + ',' + action;
    }

    let color = plcolor;
    let tccolor = 'transparent';
    let fontcolor = plcolor;
    let svg = selectedTemplate && selectedTemplate.svg ? selectedTemplate.svg : svgs[0];
    svg = svg.replace(/\{\{color\}\}/g, color)
        .replace(/\{\{tccolor\}\}/g, tccolor)
        .replace(/\{\{count\}\}/g, displayText)
        .replace(/\$color/g, color)
        .replace(/\$tccolor/g, tccolor)
        .replace(/\$fontcolor/g, fontcolor)
        .replace(/\$displayText/g, displayText);
    var encodedSvg = this.java.base64Encode(svg);
    return 'data:image/svg+xml;base64,' + encodedSvg + ',' + action;
}


// 显示弹窗



var CompatibilityUtils = {
    hasJavaClass: function(className) {
        try {
            var parts = className.split('.');
            var obj = Packages;
            for (var i = 0; i < parts.length; i++) {
                obj = obj[parts[i]];
                if (!obj) return false;
            }
            return true;
        } catch (e) {
            return false;
        }
    },
    
    safeImport: function(javaImport) {
        var classes = [
            'android.util.Base64',
            'java.lang.String', 
            'java.net.URL',
            'okhttp3.HttpUrl'
        ];
        
        classes.forEach(function(className) {
            if (this.hasJavaClass(className)) {
                try {
                    var classObj = eval('Packages.' + className);
                    javaImport.importClass(classObj);
                } catch (e) {
                    java.log('无法导入类: ' + className);
                }
            }
        }.bind(this));
        
        return javaImport;
    }
};


var javaImport = CompatibilityUtils.safeImport(new JavaImporter());

with(javaImport) {
    

    function getSubDomain(url) {
        let baseUrl = getBaseUrl(url);
        if (!baseUrl) {
            return url;
        }
        try {
            let mURL = URL(baseUrl);
            let host = mURL.host;
            if (isIPAddress(host)) return host;
            return HttpUrl.parse(baseUrl).topPrivateDomain() || host;
        } catch (e) {
            this.java.log(e);
            return baseUrl;
        }
    }

    function getDomain(url) {
        let baseUrl = getBaseUrl(url);
        if (!baseUrl) {
            return url;
        }
        try {
            return URL(baseUrl).host;
        } catch (e) {
            return baseUrl;
        }
    }
    /**
     * 移除cookie
     */
    function removeCookie(url) {
        const {
            cookie
        } = this;
        cookie.removeCookie(url);
        let domains = [getDomain(url), getSubDomain(url)];
        domains.forEach((domain) => {
            cookie.removeCookie(domain);
        });
    }
}

function getBaseUrl(url) {
    if (!url) {
        return null;
    }
    url = String(url);
    if (url.match(/https?:\/\//i)) {
        var index = url.indexOf("/", 9);
        return index == -1 ? url : url.substring(0, index);
    }
    return null;
}

function isIPv4Address(ip) {
    ip = String(ip);
    let parts = ip.split(".");
    if (parts.length !== 4) return false;

    for (let part of parts) {
        if (!/^\d+$/.test(part)) return false; // 必须是数字
        if (part.length > 1 && part[0] === "0") return false; // 禁止前导零
        let num = parseInt(part, 10);
        if (num < 0 || num > 255) return false; // 范围检查
    }
    return true;
}

function isIPv6Address(ip) {
    ip = String(ip);
    // 处理双冒号（最多出现一次）
    if (ip.includes(":::")) return false;
    let doubleColonCount = (ip.match(/::/g) || []).length;
    if (doubleColonCount > 1) return false;

    // 分割成组
    let groups = ip.split(":");
    let validGroupCount = 8;
    let actualGroupCount = groups.filter((g) => g !== "").length;

    // 验证组数
    if (doubleColonCount === 1) {
        if (actualGroupCount > validGroupCount - 1) return false;
    } else {
        if (groups.length !== validGroupCount) return false;
    }

    // 验证每组内容
    for (let group of groups) {
        if (group === "") continue; // 跳过空组（双冒号部分）
        if (!/^[0-9a-fA-F]{1,4}$/.test(group)) return false; // 1-4位十六进制
    }
    return true;
}

function isIPAddress(input) {
    return isIPv4Address(input) || isIPv6Address(input);
}

function getKey(key) {
    let parts = key.split(";");
    for (let part of parts) {
        if (part.includes("qttoken")) {
            return part.split("=")[1];
        }
    }
    return "";
}

function paraForiOS(html, sources) {
    html = renderFanqieGodNoteCards.call(this, html, sources);
	   let result = html.replace(
        /<p><img ident="([^"]*)" src="([^"]*)"\s*\/><\/p>/g,
        (match, ident, src) => {
            return `<div rs-native>${createGod(ident, src)}</div>`;
        }
    );
    result = result.replace(
        /<p>(.*?)(?:<comment ident="([^"]*)" count="([^"]*)" \/>)?<\/p>/g,
        function(match, text, url, count) {
            if (url && count) {
                const encodedUrl = url.replace(/&/g, '&amp;');
                let displayCount = count;
                const numCount = Number(count);
                if (!isNaN(numCount) && numCount > 99) {
                    displayCount = '99';
                }
                return `<div rs-native>${text}<comment count="${displayCount}" onPress="java.showReadingBrowser('${encodedUrl}','${sources}段评')"></div>`;
            } else {
                return `<div rs-native>${text}</div>`;
            }
        }
    );
    return result.replace(/&#34;/g, '"');
}




//按钮切换时改变源变量并刷新发现
function show(m, t) {
    const {
        java,
        source
    } = this;
    //源变量为空时刷新发现，重置源变量
    source.getVariable()==''?java.refreshExplore():'';//
    var data = JSON.parse(source.getVariable());
    //java.log(data);
    data[t] = m;
    if (t=="find_tab"){
    	data["find_source"]="番茄";
    	}
    //java.longToast(JSON.stringify(data));
    source.setVariable(JSON.stringify(data, null, 2));
    java.refreshExplore();
}

/**
 * 创建筛选器配置
 * @param {string} title - 筛选器标题
 * @param {string[]} chars - 选项列表
 * @param {string} defaultVal - 默认值
 * @param {string} paramKey - URL参数名
 * @param {number} size - 布局占比（0-1之间，如0.33表示33%）
 * @returns {Object} 筛选器配置对象
 */
function createFilter(title, chars, defaultVal, paramKey, size) {
    return {
        title: title,
        type: "select",
        chars: chars,
        default: defaultVal,
        action: `show(infoMap['${title}'],'${paramKey}')`,
        style: {
            layout_flexGrow: 1,
            layout_flexBasisPercent: size
        }
    };
}

function removeAllImgTags(htmlString) {
    const imgTagRegex = /<img\b[^>]*>|<\/img>|<img\b[^>]*\/>/gi;
    return htmlString.replace(imgTagRegex, '');
}


// 书旗音色使用稳定数字编号；真实Key只在请求前转换。
var SHUQI_TONE_OPTIONS = [
    {number: '1', name: '多角色对话', key: 'multi_role'},
    {number: '2', name: '双角色对话', key: 'double_role'},
    {number: '3', name: '成熟男人', key: 'mingge'},
    {number: '4', name: '甜美少女', key: 'yifei'},
    {number: '5', name: '阳光青年', key: 'xiaohou'},
    {number: '6', name: '知性主播', key: 'qianxue'},
    {number: '7', name: '沉稳男士', key: 'SQ_M03_PB_1218_01'},
    {number: '8', name: '温婉淑女', key: 'F1029_PB_1128'},
    {number: '9', name: '清朗学长', key: 'SQ_iVc8TnhZXioTB52v'},
    {number: '10', name: '清冷校花', key: 'SQ_5Oh4F5zWa8EZbWvr'},
    {number: '11', name: '沉稳青叔', key: 'zh_male_quarkttsV1_novel_King196'},
    {number: '12', name: '博主小帅', key: 'zh-CN-YunxiNeural'},
    {number: '13', name: '博主小美', key: 'zh-CN-XiaochenNeural'},
    {number: '14', name: '敏敏郡主', key: 'zhaomin'},
    {number: '15', name: '无忌哥哥', key: 'wuji'}
];

function getShuqiToneOption(value) {
    value = String(value == null ? '' : value).trim();
    for (var i = 0; i < SHUQI_TONE_OPTIONS.length; i++) {
        var option = SHUQI_TONE_OPTIONS[i];
        if (value == option.number || value == option.name || value == option.key) return option;
    }
    return null;
}

function resolveShuqiToneId(value) {
    var option = getShuqiToneOption(value);
    return option ? option.key : String(value || 'multi_role');
}

function getShuqiToneNumber(value) {
    var option = getShuqiToneOption(value);
    return option ? option.number : String(value || '1');
}

function getShuqiToneName(value) {
    var option = getShuqiToneOption(value);
    return option ? option.name : String(value || '多角色对话');
}
