<js>
var open_argument = source.getVariable();
if (!open_argument || open_argument == '') {
    var initData = {
        tab: "小说",
        tone_id: "默认音色",
        shuqi_tone_id: "multi_role",
        server: host[0],
        sources: "番茄",
        source_type: "男频",
        find_source: "番茄",
        find_tab: "小说",
        fq_word_filter: "不限",
        fq_status_filter: "不限",
        fq_sort_filter: "不限",
        fqpara: "on",
        fqcommunity: "on",
        pstyle: "0"
    };
    source.setVariable(JSON.stringify(initData));
    open_argument = source.getVariable();
}
var base_url = getArguments(open_argument, 'server') || host[0];
var ms = getArguments(open_argument, 'tone_id') || '';
var source_type = getArguments(open_argument, 'source_type') || '男频';
var tab = getArguments(open_argument, 'find_tab') || getArguments(open_argument, 'tab') || '小说';
var sources =  getArguments(open_argument, 'sources') || '番茄';
var fxyjr = getArguments(open_argument, 'fxyjr');
var fq_word_filter = getArguments(open_argument, 'fq_word_filter') || '不限';
var fq_status_filter = getArguments(open_argument, 'fq_status_filter') || '不限';
var fq_sort_filter = getArguments(open_argument, 'fq_sort_filter') || '不限';


function checkEnv() {
    let isModified = false;
    try {
        new Packages.io.legato.kazusa.utils.TimeoutCancellationException('');
        isModified = true;
    } catch (e) {
        isModified = typeof source.loginUi == 'function' ? false : true;
    }

    return isModified;
}

var islyc = checkEnv();
let device_type = '安卓';
try {
	  try {
	  java.qread();
	  device_type ="轻阅读";
	  } catch {
	  	java.deviceID();
    device_type = "苹果";
	  	}
    
} catch (e) {
    try {
        java.androidId();
        device_type = "安卓";
    } catch (e) {
        device_type = "安卓";
    }
}

var discoverySource = String(getArguments(open_argument, 'find_source') || '').trim();
    if (discoverySource.indexOf(',') >= 0) {
        discoverySource = discoverySource.split(',')[0].trim();
    }
    // “全部”只用于搜索；发现页必须落到一个真实平台，否则选择器会显示番茄但实际仍是全部。
    if (!discoverySource || discoverySource == '全部' || discoverySource == 'vip' || discoverySource == 'svip') {
        discoverySource = '番茄';
    }
    sources = discoverySource;
    setArguments('find_source', sources);
var sdtoken;
try {
    var loginInfoMap = source.getLoginInfoMap ? source.getLoginInfoMap() : {};
    sdtoken = String(loginInfoMap['手动填写番茄token(可不填)'] || '');
} catch (e) {
    sdtoken = '';
}

var rawCookie = getFanqieCookie() || sdtoken;
var match = rawCookie.match(/sessionid=[^;]+/);
var fqcookie = match ? match[0] : '';
var fqssionid = '';
if (!fqcookie && (sources == '番茄' || sources == '全部')) {
    java.toast('您还未登陆番茄账号，无法同步数据哦！');
} else {
    fqssionid = getSessionId(fqcookie)
}
var fqsjurl = base_url + "/bookshelf?page={{page}}&ssionid=" + fqssionid;
var fqtjurl = base_url + "/fqrecommend?page={{page}}&ssionid=" + fqssionid;
var fqlsurl = base_url + "/fqhistory?page={{page}}&ssionid=" + fqssionid;

var groupDatas = [];
var infoData = [ ];
if (sources == '番茄' || sources == '全部') {
infoData = [{
        "title": "登录番茄",
        "url": '{\{java.startBrowser("https://fanqienovel.com/","番茄登录");}}',
        "style": {
            "layout_flexGrow": 1,
            "layout_flexBasisPercent": 0.45
        }
    }];
}

var hasValidCookie = fqcookie.length > 0;

if (hasValidCookie && (sources == '番茄' || sources == '全部')) {
    function groupQuery() {
        try {
            var url = base_url + "/group_name?ssionid=" + fqssionid;
            var res = java.ajax(url);
            var response = JSON.parse(res);

            if (!(response && response.data)) {}

            response.data.forEach(function(group) {
                var keys = Object.keys(group);
                if (keys.length > 0) {
                    var key = keys[0];
                    var value = group[key];
                    if (value && value.length) {
                        var option = {
                            "method": "POST",
                            "body": {
                                "book_ids": value,
                                "page": "{{page}}"
                            }
                        };
                        groupDatas.push({
                            title: key,
                            url: base_url + "/bookshelf," + JSON.stringify(option),
                            style: {
                                layout_flexGrow: 1,
                                layout_flexBasisPercent: 0.45
                            }
                        });
                    }
                }
            });

            if (groupDatas.length % 2 !== 0) {
                groupDatas.push({
                    title: "--",
                    url: "",
                    style: {
                        layout_flexGrow: 1,
                        layout_flexBasisPercent: 0.45
                    }
                });
            }
        } catch (e) {
            java.longToast("番茄登录过期，已隐藏番茄书架" + fqssionid);
        }
    }

    try {
        java.longToast("正在加载分组数据...");
        var userUrl = base_url + "/fquser?ssionid=" + fqssionid;
        var userRes = java.ajax(userUrl);
        var userData = JSON.parse(userRes);

        var userName = (userData && userData.data && userData.data.name) ? userData.data.name : '未知用户';
        if (!userName.includes('未知用户')) {
            infoData = [{
                title: "番茄个人中心",
                url: fqsjurl,
                style: {
                    layout_flexGrow: 1,
                    layout_flexBasisPercent: 0.45
                }
            }, {
                title: "个性推荐(番茄)",
                url: fqtjurl,
                style: {
                    layout_flexGrow: 1,
                    layout_flexBasisPercent: 0.45
                }
            }, {
                title: "历史阅读(番茄)",
                url: fqlsurl,
                style: {
                    layout_flexGrow: 1,
                    layout_flexBasisPercent: 0.45
                }
            }];
        }
        groupQuery();
    } catch (e) {
        java.longToast("番茄登录过期，已隐藏番茄书架");
    }
}

var style_list = [];
try {
    var durl = `${base_url}/discovestyle?source=${sources}&source_type=${source_type}&tab=${tab}`;
    var res = java.ajax(durl);
    var result = JSON.parse(res);
    style_list = result.data || [];

    // 番茄分类筛选只作用于小说的普通分类，不影响排行榜和其他来源。
    if (sources == '番茄' && tab == '小说') {
        var fqWordMap = {
            '不限': 'word_num_default',
            '10万字以内': 'word_num_lte10',
            '30万字以内': 'word_num_lte30',
            '50万字以内': 'word_num_lte50',
            '30万字以上': 'word_num_gte30',
            '50万字以上': 'word_num_gte50',
            '100万字以上': 'word_num_gte100',
            '200万字以上': 'word_num_gte200',
            '300万字以上': 'word_num_gte300',
            '500万字以上': 'word_num_gte500'
        };
        var fqStatusMap = {
            '不限': 'creation_status_default',
            '完结': 'creation_status_end',
            '连载': 'creation_status_loading',
            '半年内完结': 'creation_status_half_year_end',
            '3日内更新': 'creation_status_3day_update',
            '7日内更新': 'creation_status_7day_update',
            '1月内更新': 'creation_status_1month_update'
        };
        var fqSortMap = {
            '不限': 'sort_default',
            '热门': 'sort_hot',
            '新书': 'sort_new_book',
            '评分': 'sort_score',
            '字数': 'sort_word_number',
            '有声': 'sort_audio_book'
        };
        var hasActiveFilter = fq_word_filter != '不限' || fq_status_filter != '不限' || fq_sort_filter != '不限';
        if (hasActiveFilter) {
            var selectedItems = [
                fqWordMap[fq_word_filter] || fqWordMap['不限'],
                fqStatusMap[fq_status_filter] || fqStatusMap['不限'],
                fqSortMap[fq_sort_filter] || fqSortMap['不限']
            ].join(',');
            style_list.forEach(function(item) {
                if (!item || typeof item.url != 'string') return;
                var isCategory = item.url.indexOf('/get_discover?') >= 0 &&
                    item.url.indexOf('source=番茄') >= 0 &&
                    item.url.indexOf('&type=') >= 0 &&
                    item.url.indexOf('&bdtype=') < 0 &&
                    item.url.indexOf('&is_ranking=1') < 0;
                if (isCategory && item.url.indexOf('&selected_items=') < 0) {
                    item.url += '&selected_items=' + selectedItems;
                }
            });
        }
    }
    if (result.msg) {
        java.toast(result.msg);
    }
} catch (e) {
    java.toast("发现样式获取失败");
}
let qtcookie = cookie.getCookie(base_url);
//let qtcookie = ""
let qtop = {
    method: "GET",
    headers: {
        cookie: qtcookie
    },
};



qtop = JSON.stringify(qtop);
let qtsjurl = base_url + '/get_book_shelf,' + qtop;

let qtsj = [];

// 源阅 iOS 已支持新版发现页筛选栏；此书源统一使用新版发现页。
var useModernExplore = true;
if (useModernExplore) {
    try {
        qtsj.push(createFilter(
            "线路",
            host,
            base_url,
            "server",
            1
        ));
        qtsj.push(createFilter(
            "模式",
            ["小说", "听书", "短剧", "漫画"],
            tab,
            "find_tab",
            0.33
        ));
        qtsj.push(createFilter(
            "频道",
            ["男频", "女频"],
            source_type,
            "source_type",
            0.33
        ));
        let source_list = ['番茄', '七猫', '书旗', '塔读', '江湖', '小米', '米读', 'QQ阅读', '酷我小说', '幻梦轻小说', '猫眼', '西瓜小说', '69书吧', '顶点', '爱下电子书', '伪69', '超会专属小说', '听小说', '阅友小说', '百度', '得间', 'QQ', '搜书神器', '得奇', '知乎', '追更人', '久久小说', '52书库', '腐小说', '完本小说', '盐选文库', '有度中文', '三零读书', '鹿鹿', '星空小说', '365小说', '冷冷文学', '万相书城', '独步小说', '福书网', '速读谷', '全本同人'];
        if (tab == '听书') {
            source_list = ['番茄', '七猫', '书旗', '喜马拉雅', '酷我'];
        }
        if (tab == '漫画') {
            source_list = ['全免漫画', '番茄', '漫画屋', '漫画网', '漫客栈', '鸟韩漫', '新新漫画', '武芊漫画', '拷贝漫画', '漫画屋'];
        }
        if (tab == '短剧') {
            source_list = ['番茄', 'YY短剧', '东梨短剧', '星芽短剧', '极速影视'];
        }
        qtsj.push(createFilter(
            "平台",
            source_list,
            sources,
            "find_source",
            1
        ));
        if (sources == '番茄' && tab == '小说') {
            qtsj.push(createFilter(
                "字数",
                ["不限", "10万字以内", "30万字以内", "50万字以内", "30万字以上", "50万字以上", "100万字以上", "200万字以上", "300万字以上", "500万字以上"],
                fq_word_filter,
                "fq_word_filter",
                0.33
            ));
            qtsj.push(createFilter(
                "状态",
                ["不限", "完结", "连载", "半年内完结", "3日内更新", "7日内更新", "1月内更新"],
                fq_status_filter,
                "fq_status_filter",
                0.33
            ));
            qtsj.push(createFilter(
                "排序",
                ["不限", "热门", "新书", "评分", "字数", "有声"],
                fq_sort_filter,
                "fq_sort_filter",
                0.33
            ));
        }
       const excludeTitles = ['点击登录可切换来源', '切换后长按刷新即可'];
       style_list = style_list.filter(item => !excludeTitles.includes(item.title));
    } catch {}
} else {
	if (device_type == '安卓'){
	qtsj.push({
        "title": "下载阅读Sigma最新测试版",
        "url": '{\{java.longToast("本书源推荐使用最新版洛娅橙改版阅读Σ\\n请安装后重新导入书源");java.startBrowser("https://legado.langge.cf","下载阅读Sigma最新测试版");}}',
        "style": {
            "layout_flexGrow": 1,
            "layout_flexBasisPercent": 1
        }
    })}
	}

if (qtcookie) {
qtsj.push({
    title: "大灰狼个人中心",
    url: qtsjurl,
    style: {
        layout_flexGrow: 1,
        layout_flexBasisPercent: 0.45
    }
})
} else {
qtsj.push({
    title: "登录大灰狼书源",
    url: `{\{java.startBrowser("${base_url}/login","登录书源");}}`,
    style: {
        layout_flexGrow: 1,
        layout_flexBasisPercent: 0.45
    }
})
}


var finalData = infoData.concat(groupDatas, style_list);
finalData = qtsj.concat(finalData);
JSON.stringify(finalData);
</js>