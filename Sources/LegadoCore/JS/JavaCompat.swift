// ============================================================
// ⭐⭐⭐ **站方 JS 的 Java 兼容层**（从轻阅的老引擎**原样搬来**，一行没改）
//
// ⚠️⚠️ **为什么编进 Swift 而不是当 SPM 资源**：
//   `Bundle.module` 在 App（静态链接）与 CI 里都可能拿不到 ⇒ 兼容层没注入
//   ⇒ 站方 jsLib 第一行 `new JavaImporter()` 抛错 ⇒ **jsLib 整个加载失败**
//   ⇒ 站方 JS 走兜底分支 ⇒ 分类变成「未分组」假分类 ⇒ 整本书打不开 ⭐
//
// ⚠️⚠️ **注入时必须用「间接 eval」**（`(0, eval)(src)`）——
//   **JSC 的 evaluateScript 顶层 var 不进全局**（与 WebKit 不同！）⭐
// ============================================================

public enum JavaCompat {

    /// `packagesStub` 的源码（分块拼接 ⇒ 避免超长字面量把编译器压垮）
    static let packagesStubSource: String = [
        ##"""
// ====== Packages/JavaImporter 兼容层 ======
// 模拟 Rhino/legado 的 Java 包导入机制
// 书源使用 Packages.javax.crypto.Cipher 等 Java 类进行加密解密，
// 此脚本在 JavaScriptCore 中提供等价的纯 JS 实现，底层委托给 Swift 原生函数。

// ====== String.prototype.getBytes (模拟 java.lang.String.getBytes) ======
if (typeof String.prototype.getBytes !== 'function') {
    String.prototype.getBytes = function(charset) {
        if (charset && typeof _nativeStrToBytes === 'function') {
            return _nativeStrToBytes(this.toString(), String(charset));
        }
        // 默认 UTF-8 编码
        var str = this.toString();
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 0x80) {
                bytes.push(c);
            } else if (c < 0x800) {
                bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
            } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
                var hi = c, lo = str.charCodeAt(++i);
                var cp = ((hi - 0xd800) << 10) + (lo - 0xdc00) + 0x10000;
                bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
            } else {
                bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
            }
        }
        return bytes;
    };
}

// ====== JavaImporter (模拟 Rhino 的 JavaImporter + with 语句) ======
if (typeof JavaImporter === 'undefined' || !JavaImporter.__qireaderCompatibleJavaImporter) {
    JavaImporter = function() {
        var self = {};
        var _importPkg = function() {
            for (var i = 0; i < arguments.length; i++) {
                var pkg = arguments[i];
                if (pkg && typeof pkg === 'object') {
                    if (pkg.__javaClassName) {
                        self[pkg.__javaClassName] = pkg;
                        continue;
                    }
                    for (var k in pkg) {
                        if (pkg.hasOwnProperty(k)) self[k] = pkg[k];
                    }
                } else if (pkg && typeof pkg === 'function') {
                    self[pkg.__javaClassName || pkg.name] = pkg;
                }
            }
        };
        _importPkg.apply(null, arguments);
        self.importPackage = _importPkg;
        self.importClass = function() {};
        return self;
    };
    JavaImporter.__qireaderCompatibleJavaImporter = true;
}

// ====== importPackage 全局函数（Rhino 兼容） ======
if (typeof importPackage === 'undefined') {
    var importPackage = function() {};
}

// ====== Packages 命名空间 ======
if (typeof Packages === 'undefined') { var Packages = {}; }

// ------ com.jayway.jsonpath ------
Packages.com = Packages.com || {};
Packages.com.jayway = Packages.com.jayway || {};
Packages.com.jayway.jsonpath = Packages.com.jayway.jsonpath || {};
Packages.com.jayway.jsonpath.Option = Packages.com.jayway.jsonpath.Option || {
    SUPPRESS_EXCEPTIONS: 'SUPPRESS_EXCEPTIONS'
};
Packages.com.jayway.jsonpath.Configuration = Packages.com.jayway.jsonpath.Configuration || {
    builder: function() {
        var suppress = false;
        return {
            options: function() {
                for (var i = 0; i < arguments.length; i++) {
                    if (arguments[i] === Packages.com.jayway.jsonpath.Option.SUPPRESS_EXCEPTIONS) suppress = true;
                }
                return this;
            },
            build: function() { return { _suppressExceptions: suppress }; }
        };
    }
};
Packages.com.jayway.jsonpath.JsonPath = Packages.com.jayway.jsonpath.JsonPath || {
    read: function(json, path) {
        return _nativeJsonPathRead(json, String(path), false);
    },
    parse: function(json) {
        return this.using(null).parse(json);
    },
    using: function(configuration) {
        var suppress = !!(configuration && configuration._suppressExceptions);
        return {
            parse: function(json) {
                return {
                    read: function(path) {
                        return _nativeJsonPathRead(json, String(path), suppress);
                    }
                };
            }
        };
    }
};
Packages.com.jayway.jsonpath.JsonPath.__javaClassName = 'JsonPath';
Packages.com.jayway.jsonpath.Configuration.__javaClassName = 'Configuration';
Packages.com.jayway.jsonpath.Option.__javaClassName = 'Option';
if (typeof com === 'undefined') { var com = Packages.com; }

// ------ javax.crypto ------
Packages.javax = Packages.javax || {};
Packages.javax.crypto = Packages.javax.crypto || {};
Packages.javax.crypto.Cipher = Packages.javax.crypto.Cipher || {
    ENCRYPT_MODE: 1,
    DECRYPT_MODE: 2,
"""##,
        ##"""
    getInstance: function(transformation) {
        return {
            _t: String(transformation),
            _keyBytes: null,
            _ivBytes: null,
            _opmode: 0,
            init: function(opmode, key, ivSpec) {
                this._opmode = (typeof opmode === 'number') ? opmode : 2;
                if (key) this._keyBytes = key._keyBytes || key;
                if (ivSpec) this._ivBytes = ivSpec._ivBytes || ivSpec;
            },
            doFinal: function(data) {
                var keyB64 = _nativeBase64Encode(Array.prototype.slice.call(this._keyBytes || []));
                var ivB64 = this._ivBytes ? _nativeBase64Encode(Array.prototype.slice.call(this._ivBytes)) : '';
                var dataB64 = _nativeBase64Encode(Array.prototype.slice.call(data || []));
                var isDecrypt = (this._opmode === 2);
                return _nativeCipherProcess(dataB64, keyB64, this._t, ivB64, isDecrypt);
            }
        };
    }
};
Packages.javax.crypto.SecretKeyFactory = Packages.javax.crypto.SecretKeyFactory || {
    getInstance: function(algorithm) {
        return {
            generateSecret: function(keySpec) {
                return keySpec;
            }
        };
    }
};

// ------ javax.crypto.spec ------
Packages.javax.crypto.spec = Packages.javax.crypto.spec || {};
if (!Packages.javax.crypto.spec.SecretKeySpec) {
    Packages.javax.crypto.spec.SecretKeySpec = function(keyBytes, algorithm) {
        return { _keyBytes: Array.prototype.slice.call(keyBytes), _algorithm: String(algorithm) };
    };
}
if (!Packages.javax.crypto.spec.IvParameterSpec) {
    Packages.javax.crypto.spec.IvParameterSpec = function(ivBytes) {
        return { _ivBytes: Array.prototype.slice.call(ivBytes) };
    };
}
if (!Packages.javax.crypto.spec.DESKeySpec) {
    Packages.javax.crypto.spec.DESKeySpec = function(keyBytes) {
        return { _keyBytes: Array.prototype.slice.call(keyBytes) };
    };
}

// ------ java.lang ------
Packages.java = Packages.java || {};
Packages.java.lang = Packages.java.lang || {};
var __javaStringMarkerKey = '__qireaderJavaType';
var __javaStringMarkerValue = 'java.lang.String';
function __javaIsStringLike(val) {
    return typeof val === 'string' || (val !== undefined && val !== null && (val[__javaStringMarkerKey] === __javaStringMarkerValue || Object.prototype.toString.call(val) === '[object String]'));
}
function __javaStringText(val, charset) {
    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
    if (val !== undefined && val !== null && !__javaIsStringLike(val) && typeof val !== 'number' && typeof val !== 'boolean') {
        if (typeof _nativeBytesToStr === 'function') {
            return _nativeBytesToStr(Array.prototype.slice.call(val), charset || 'UTF-8');
        }
        var s = '';
        for (var i = 0; i < val.length; i++) s += RootString.fromCharCode(val[i] & 0xFF);
        return s;
    }
    return RootString(val);
}
function __javaStringObject(text) {
    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
    var obj = new RootString(text);
    try {
        Object.defineProperty(obj, __javaStringMarkerKey, {
            value: __javaStringMarkerValue,
            enumerable: false,
            configurable: true
        });
    } catch (e) {
        obj[__javaStringMarkerKey] = __javaStringMarkerValue;
    }
    obj.toString = function() { return text; };
    obj.valueOf = function() { return text; };
    if (typeof obj.getBytes !== 'function') {
        obj.getBytes = function(charset) { return RootString.prototype.getBytes.call(text, charset); };
    }
    return obj;
}
if (!Packages.java.lang.String) {
    Packages.java.lang.String = function(val, charset) {
        return __javaStringObject(__javaStringText(val, charset));
    };
    Packages.java.lang.String.__javaClassName = 'String';
}
// java.lang.Integer（Rhino 兼容：书源 with(javaImport) 中使用 Integer.parseInt 等）
if (!Packages.java.lang.Integer) {
    Packages.java.lang.Integer = {
        parseInt: function(str, radix) { return parseInt(str, radix || 10); },
        valueOf: function(i) { return parseInt(i); },
        toHexString: function(i) { return (i >>> 0).toString(16); },
        toBinaryString: function(i) { return (i >>> 0).toString(2); },
        toOctalString: function(i) { return (i >>> 0).toString(8); },
        MAX_VALUE: 2147483647,
        MIN_VALUE: -2147483648
    };
}
// java.lang.Long（Rhino 兼容）
if (!Packages.java.lang.Long) {
    Packages.java.lang.Long = {
        parseLong: function(str, radix) { return parseInt(str, radix || 10); },
        valueOf: function(i) { return parseInt(i); },
        MAX_VALUE: 9007199254740991
    };
}
// java.lang.Math（委托给 JS Math）
if (!Packages.java.lang.Math) {
    Packages.java.lang.Math = Math;
}
// java.lang.System（最小存根）
if (!Packages.java.lang.System) {
"""##,
        ##"""
    Packages.java.lang.System = {
        currentTimeMillis: function() { return Date.now(); },
        nanoTime: function() { return Date.now() * 1000000; }
    };
}
if (!Packages.java.lang.Thread) {
    Packages.java.lang.Thread = {
        sleep: function(ms) {
            ms = Math.max(0, Math.min(Number(ms) || 0, 2000));
            if (typeof _nativeSleepMillis === 'function') {
                _nativeSleepMillis(ms);
                return;
            }
            var end = Date.now() + Math.min(ms, 50);
            while (Date.now() < end) {}
        }
    };
    Packages.java.lang.Thread.__javaClassName = 'Thread';
}
if (!Packages.java.lang.StringBuilder) {
    Packages.java.lang.StringBuilder = function(initial) {
        var value = (initial === undefined || initial === null) ? '' : String(initial);
        return {
            append: function(v) { value += (v === null ? 'null' : String(v)); return this; },
            appendCodePoint: function(codePoint) { value += String.fromCodePoint ? String.fromCodePoint(codePoint) : String.fromCharCode(codePoint); return this; },
            insert: function(index, v) { index = Math.max(0, Math.min(value.length, Number(index) || 0)); value = value.slice(0, index) + (v === null ? 'null' : String(v)) + value.slice(index); return this; },
            delete: function(start, end) { start = Math.max(0, Number(start) || 0); end = Math.min(value.length, Number(end) || start); value = value.slice(0, start) + value.slice(end); return this; },
            deleteCharAt: function(index) { index = Number(index) || 0; if (index >= 0 && index < value.length) value = value.slice(0, index) + value.slice(index + 1); return this; },
            replace: function(start, end, str) { start = Math.max(0, Number(start) || 0); end = Math.min(value.length, Number(end) || start); value = value.slice(0, start) + String(str) + value.slice(end); return this; },
            substring: function(start, end) { return value.substring(start, end); },
            charAt: function(index) { return value.charAt(index); },
            length: function() { return value.length; },
            setLength: function(len) { len = Math.max(0, Number(len) || 0); value = value.length > len ? value.slice(0, len) : value + new Array(len - value.length + 1).join('\u0000'); return this; },
            toString: function() { return value; }
        };
    };
    Packages.java.lang.StringBuilder.__javaClassName = 'StringBuilder';
}
if (!Packages.java.lang.StringBuffer) {
    Packages.java.lang.StringBuffer = function(initial) {
        return new Packages.java.lang.StringBuilder(initial);
    };
    Packages.java.lang.StringBuffer.__javaClassName = 'StringBuffer';
}

// ------ java.util ------
Packages.java.util = Packages.java.util || {};
// java.util.UUID (Rhino/legado 兼容：书源常用 Packages.java.util.UUID.randomUUID())
if (!Packages.java.util.UUID) {
    Packages.java.util.UUID = {
        randomUUID: function() {
            // 优先使用原生桥接（由 Swift JsBridgeShared+Util 注册）
            if (typeof java !== 'undefined' && typeof java.randomUUID === 'function') {
                return java.randomUUID();
            }
            // 纯 JS UUID v4 回退
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0;
                var v = c === 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        },
        fromString: function(str) {
            return String(str);
        },
        nameUUIDFromBytes: function(bytes) {
            // UUID v3/v5 风格 — 生成基于名称的 UUID（MD5 版本）
            var nameStr = '';
            if (typeof bytes === 'string') {
                nameStr = bytes;
            } else if (bytes && typeof bytes.length === 'number') {
                for (var i = 0; i < bytes.length; i++) {
                    nameStr += String.fromCharCode(bytes[i] & 0xFF);
                }
            } else {
                nameStr = String(bytes || '');
            }
            var hash = '';
            if (typeof java !== 'undefined' && typeof java.md5Encode === 'function') {
                hash = java.md5Encode(nameStr);
            }
            // 格式化为 UUID
            if (hash && hash.length >= 32) {
                return (hash.substr(0, 8) + '-' + hash.substr(8, 4) + '-' +
                        '3' + hash.substr(13, 3) + '-' +
                        ((parseInt(hash.substr(16, 2), 16) & 0x3f | 0x80).toString(16)) +
                        hash.substr(18, 2) + '-' + hash.substr(20, 12));
            }
            return '00000000-0000-3000-8000-000000000000';
        }
    };
    Packages.java.util.UUID.__javaClassName = 'UUID';
}
function __javaValueToString(value) {
    if (value === null || value === undefined) return 'null';
    if (Array.isArray(value)) return '[' + value.map(__javaValueToString).join(', ') + ']';
    if (value && typeof value === 'object' && value.toString === Object.prototype.toString) {
        return '{' + Object.keys(value).map(function(key) {
            return key + '=' + __javaValueToString(value[key]);
        }).join(', ') + '}';
    }
    if (value && typeof value.toString === 'function' && value.toString !== Object.prototype.toString) return String(value.toString());
    return String(value);
}
function __javaArrayListFrom(items) {
    var arr = Array.prototype.slice.call(items || []);
    var list = {
        add: function(index, value) {
            if (arguments.length === 1) {
                arr.push(index);
            } else {
                index = Math.max(0, Math.min(arr.length, Number(index) || 0));
                arr.splice(index, 0, value);
            }
            return true;
        },
        addAll: function(values) {
            var incoming = values && typeof values.toArray === 'function' ? values.toArray() : Array.prototype.slice.call(values || []);
            for (var i = 0; i < incoming.length; i++) arr.push(incoming[i]);
            return incoming.length > 0;
"""##,
        ##"""
        },
        get: function(index) { return arr[Number(index) || 0]; },
        set: function(index, value) { index = Number(index) || 0; var old = arr[index]; arr[index] = value; return old; },
        remove: function(value) {
            if (typeof value === 'number') return arr.splice(value, 1)[0];
            var index = arr.indexOf(value);
            if (index >= 0) { arr.splice(index, 1); return true; }
            return false;
        },
        size: function() { return arr.length; },
        isEmpty: function() { return arr.length === 0; },
        clear: function() { arr.length = 0; },
        contains: function(value) { return arr.indexOf(value) >= 0; },
        indexOf: function(value) { return arr.indexOf(value); },
        toArray: function() { return arr.slice(); },
        forEach: function(callback) { for (var i = 0; i < arr.length; i++) callback(arr[i], i); },
        iterator: function() {
            var index = 0;
            return {
                hasNext: function() { return index < arr.length; },
                next: function() { return arr[index++]; }
            };
        },
        toString: function() { return '[' + arr.map(__javaValueToString).join(', ') + ']'; }
    };
    return list;
}
function __qireaderCollectionBridgeFrom(items, options) {
    var arr = items && typeof items.toArray === 'function'
        ? Array.prototype.slice.call(items.toArray() || [])
        : Array.prototype.slice.call(items || []);
    var list = __javaArrayListFrom(arr);
    var bridgeOptions = options || {};
    var indexedLength = 0;

    function defineHidden(target, key, value) {
        try {
            Object.defineProperty(target, key, {
                value: value,
                enumerable: false,
                configurable: true,
                writable: true
            });
        } catch (_) {
            try { target[key] = value; } catch (_) {}
        }
    }

    function syncIndexes() {
        for (var i = 0; i < indexedLength; i++) delete list[i];
        for (var j = 0; j < arr.length; j++) list[j] = arr[j];
        indexedLength = arr.length;
    }

    function wrapMutator(name) {
        var original = list[name];
        if (typeof original !== 'function') return;
        defineHidden(list, name, function() {
            var result = original.apply(list, arguments);
            syncIndexes();
            return result;
        });
    }

    try {
        Object.defineProperty(list, 'length', {
            get: function() { return arr.length; },
            enumerable: false,
            configurable: true
        });
    } catch (_) {}

    if (typeof list.first !== 'function') {
        defineHidden(list, 'first', function() { return arr.length ? arr[0] : null; });
    }
    if (typeof list.last !== 'function') {
        defineHidden(list, 'last', function() { return arr.length ? arr[arr.length - 1] : null; });
    }
    if (typeof list.map !== 'function') {
        defineHidden(list, 'map', function(callback, thisArg) { return arr.map(callback, thisArg); });
    }
    if (typeof list.filter !== 'function') {
        defineHidden(list, 'filter', function(callback, thisArg) { return arr.filter(callback, thisArg); });
    }

    defineHidden(list, '__qireaderCollectionBridge', true);
    defineHidden(list, '__qireaderCollectionKind', String(bridgeOptions.kind || 'list'));
    defineHidden(list, 'toString', function() {
        return '[' + arr.map(__javaValueToString).join(', ') + ']';
    });
    defineHidden(list, 'valueOf', function() { return this.toString(); });

    wrapMutator('add');
    wrapMutator('addAll');
    wrapMutator('set');
    wrapMutator('remove');
    wrapMutator('clear');
    syncIndexes();
    return list;
}
if (!Packages.java.util.ArrayList) {
    Packages.java.util.ArrayList = function(initial) {
        if (initial && typeof initial.toArray === 'function') return __javaArrayListFrom(initial.toArray());
        if (initial && typeof initial.length === 'number' && typeof initial !== 'string') return __javaArrayListFrom(initial);
        return __javaArrayListFrom([]);
    };
    Packages.java.util.ArrayList.__javaClassName = 'ArrayList';
}
if (!Packages.java.util.HashMap) {
    Packages.java.util.HashMap = function(initial) {
        var map = {};
        var keys = [];
        function keyOf(key) { return String(key); }
        function remember(key) { if (keys.indexOf(key) < 0) keys.push(key); }
        var api = {
            put: function(key, value) { key = keyOf(key); var old = map.hasOwnProperty(key) ? map[key] : null; remember(key); map[key] = value; return old; },
            get: function(key) { key = keyOf(key); return map.hasOwnProperty(key) ? map[key] : null; },
            getOrDefault: function(key, def) { key = keyOf(key); return map.hasOwnProperty(key) ? map[key] : def; },
            remove: function(key) { key = keyOf(key); if (!map.hasOwnProperty(key)) return null; var old = map[key]; delete map[key]; keys = keys.filter(function(k) { return k !== key; }); return old; },
            containsKey: function(key) { return map.hasOwnProperty(keyOf(key)); },
"""##,
        ##"""
            containsValue: function(value) { for (var i = 0; i < keys.length; i++) if (map[keys[i]] === value) return true; return false; },
            size: function() { return keys.length; },
            isEmpty: function() { return keys.length === 0; },
            clear: function() { map = {}; keys = []; },
            putAll: function(other) {
                if (!other) return;
                if (typeof other.entrySet === 'function') {
                    var entries = other.entrySet().toArray();
                    for (var i = 0; i < entries.length; i++) this.put(entries[i].getKey(), entries[i].getValue());
                } else {
                    for (var k in other) if (other.hasOwnProperty(k)) this.put(k, other[k]);
                }
            },
            keySet: function() { return __javaArrayListFrom(keys.slice()); },
            values: function() { return __javaArrayListFrom(keys.map(function(k) { return map[k]; })); },
            entrySet: function() {
                return __javaArrayListFrom(keys.map(function(k) {
                    return {
                        getKey: function() { return k; },
                        getValue: function() { return map[k]; },
                        toString: function() { return k + '=' + __javaValueToString(map[k]); }
                    };
                }));
            },
            toString: function() { return '{' + keys.map(function(k) { return k + '=' + __javaValueToString(map[k]); }).join(', ') + '}'; }
        };
        if (initial) api.putAll(initial);
        return api;
    };
    Packages.java.util.HashMap.__javaClassName = 'HashMap';
}
if (!Packages.java.util.LinkedHashMap) {
    Packages.java.util.LinkedHashMap = function(initial) {
        return new Packages.java.util.HashMap(initial);
    };
    Packages.java.util.LinkedHashMap.__javaClassName = 'LinkedHashMap';
}
if (!Packages.java.util.Base64) {
    Packages.java.util.Base64 = {
        getDecoder: function() {
            return {
                decode: function(input) {
                    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
                    var str;
                    if (__javaIsStringLike(input)) {
                        str = RootString(input);
                    } else {
                        str = '';
                        for (var i = 0; i < input.length; i++) str += String.fromCharCode(input[i] & 0xFF);
                    }
                    return _nativeBase64DecodeToBytes(str);
                }
            };
        },
        getEncoder: function() {
            return {
                encode: function(input) {
                    var b64 = _nativeBase64Encode(Array.prototype.slice.call(input));
                    var bytes = [];
                    for (var i = 0; i < b64.length; i++) bytes.push(b64.charCodeAt(i));
                    return bytes;
                },
                encodeToString: function(input) {
                    return _nativeBase64Encode(Array.prototype.slice.call(input));
                }
            };
        }
    };
}
if (!Packages.java.util.Arrays) {
    Packages.java.util.Arrays = {
        copyOfRange: function(arr, from, to) {
            return Array.prototype.slice.call(arr, from, to);
        },
        copyOf: function(arr, newLength) {
            var result = Array.prototype.slice.call(arr, 0, newLength);
            while (result.length < newLength) result.push(0);
            return result;
        }
    };
}
Packages.java.util.concurrent = Packages.java.util.concurrent || {};
if (!Packages.java.util.concurrent.TimeUnit) {
    Packages.java.util.concurrent.TimeUnit = {
        MILLISECONDS: {
            sleep: function(ms) { Packages.java.lang.Thread.sleep(ms); },
            toMillis: function(value) { return Number(value) || 0; }
        },
        SECONDS: {
            sleep: function(seconds) { Packages.java.lang.Thread.sleep((Number(seconds) || 0) * 1000); },
            toMillis: function(value) { return (Number(value) || 0) * 1000; }
        }
    };
    Packages.java.util.concurrent.TimeUnit.__javaClassName = 'TimeUnit';
}
Packages.java.util.regex = Packages.java.util.regex || {};
if (!Packages.java.util.regex.Pattern) {
    Packages.java.util.regex.Pattern = {
        CASE_INSENSITIVE: 2,
        MULTILINE: 8,
        DOTALL: 32,
        quote: function(text) { return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); },
        matches: function(pattern, input) { return this.compile(pattern).matcher(input).matches(); },
        compile: function(pattern, flags) {
            var jsFlags = 'g';
            flags = flags || 0;
            if (flags & 2) jsFlags += 'i';
            if (flags & 8) jsFlags += 'm';
            if (flags & 32) jsFlags += 's';
            var source = String(pattern);
            return {
                pattern: function() { return source; },
                matcher: function(input) {
                    input = String(input);
                    var regex = new RegExp(source, jsFlags);
                    var last = null;
                    return {
                        find: function() { last = regex.exec(input); return !!last; },
                        group: function(index) { index = index || 0; return last ? (last[index] !== undefined ? last[index] : null) : null; },
                        groupCount: function() { return last ? Math.max(0, last.length - 1) : 0; },
"""##,
        ##"""
                        matches: function() { var r = new RegExp('^(?:' + source + ')$', jsFlags.replace('g', '')); last = r.exec(input); return !!last; },
                        replaceAll: function(replacement) { return input.replace(new RegExp(source, jsFlags), String(replacement)); },
                        replaceFirst: function(replacement) { return input.replace(new RegExp(source, jsFlags.replace('g', '')), String(replacement)); },
                        reset: function(newInput) { input = newInput === undefined ? input : String(newInput); regex.lastIndex = 0; last = null; return this; }
                    };
                },
                split: function(input) { return String(input).split(new RegExp(source, jsFlags.replace('g', ''))); },
                toString: function() { return source; }
            };
        }
    };
    Packages.java.util.regex.Pattern.__javaClassName = 'Pattern';
}

// ------ java.security ------
Packages.java.security = Packages.java.security || {};
if (!Packages.java.security.MessageDigest) {
    Packages.java.security.MessageDigest = {
        getInstance: function(algorithm) {
            var algorithmName = String(algorithm || 'MD5').toUpperCase().replace(/_/g, '-');
            var buffer = '';
            function bytesToString(data) {
                if (data === null || data === undefined) return '';
                if (typeof data === 'string') return data;
                var arr = Array.prototype.slice.call(data);
                if (typeof _nativeBytesToStr === 'function') return _nativeBytesToStr(arr, 'UTF-8');
                var s = '';
                for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i] & 0xFF);
                return s;
            }
            function hexToBytes(hex) {
                var out = [];
                for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
                return out;
            }
            function digestHex(text) {
                if (typeof java !== 'undefined' && java.digestHex) return java.digestHex(text, algorithmName);
                if (algorithmName === 'MD5' && typeof java !== 'undefined' && java.md5Encode) return java.md5Encode(text);
                return '';
            }
            return {
                update: function(data) { buffer += bytesToString(data); },
                digest: function(data) { var text = data === undefined ? buffer : bytesToString(data); var bytes = hexToBytes(digestHex(text)); buffer = ''; return bytes; },
                reset: function() { buffer = ''; },
                getAlgorithm: function() { return algorithmName; }
            };
        },
        isEqual: function(a, b) {
            a = Array.prototype.slice.call(a || []);
            b = Array.prototype.slice.call(b || []);
            if (a.length !== b.length) return false;
            var diff = 0;
            for (var i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]);
            return diff === 0;
        }
    };
    Packages.java.security.MessageDigest.__javaClassName = 'MessageDigest';
}
Packages.java.security.spec = Packages.java.security.spec || {};
Packages.java.security.interfaces = Packages.java.security.interfaces || {};
function __javaKeySpecBytes(bytes) {
    return Array.prototype.slice.call(bytes || []).map(function(v) { return Number(v) & 0xFF; });
}
if (!Packages.java.security.spec.PKCS8EncodedKeySpec) {
    Packages.java.security.spec.PKCS8EncodedKeySpec = function(bytes) {
        var encoded = __javaKeySpecBytes(bytes);
        return { getEncoded: function() { return encoded.slice(); }, _bytes: encoded, _format: 'PKCS8' };
    };
    Packages.java.security.spec.PKCS8EncodedKeySpec.__javaClassName = 'PKCS8EncodedKeySpec';
}
if (!Packages.java.security.spec.X509EncodedKeySpec) {
    Packages.java.security.spec.X509EncodedKeySpec = function(bytes) {
        var encoded = __javaKeySpecBytes(bytes);
        return { getEncoded: function() { return encoded.slice(); }, _bytes: encoded, _format: 'X509' };
    };
    Packages.java.security.spec.X509EncodedKeySpec.__javaClassName = 'X509EncodedKeySpec';
}
if (!Packages.java.security.KeyFactory) {
    Packages.java.security.KeyFactory = {
        getInstance: function(algorithm) {
            algorithm = String(algorithm || 'RSA').toUpperCase();
            function makeKey(spec, kind) {
                var bytes = spec && typeof spec.getEncoded === 'function' ? spec.getEncoded() : __javaKeySpecBytes(spec && spec._bytes ? spec._bytes : spec);
                return {
                    _algorithm: algorithm,
                    _kind: kind,
                    _keyBytes: bytes,
                    _keyBase64: _nativeBase64Encode(bytes),
                    getAlgorithm: function() { return algorithm; },
                    getEncoded: function() { return bytes.slice(); },
                    getFormat: function() { return spec && spec._format ? spec._format : ''; },
                    toString: function() { return algorithm + ' ' + kind + ' key'; }
                };
            }
            return {
                generatePrivate: function(spec) { return makeKey(spec, 'private'); },
                generatePublic: function(spec) { return makeKey(spec, 'public'); }
            };
        }
    };
    Packages.java.security.KeyFactory.__javaClassName = 'KeyFactory';
}
if (!Packages.java.security.Signature) {
    Packages.java.security.Signature = {
        getInstance: function(algorithm) {
            algorithm = String(algorithm || 'SHA256WithRSA');
            var privateKey = null;
            var publicKey = null;
            var buffer = [];
            function appendBytes(data) {
                if (data === null || data === undefined) return;
                if (typeof data === 'string') data = data.getBytes ? data.getBytes('UTF-8') : String(data).split('').map(function(c) { return c.charCodeAt(0); });
                var arr = Array.prototype.slice.call(data);
                for (var i = 0; i < arr.length; i++) buffer.push(Number(arr[i]) & 0xFF);
            }
            function bufferedString() {
                if (typeof _nativeBytesToStr === 'function') return _nativeBytesToStr(buffer, 'UTF-8');
                var s = '';
                for (var i = 0; i < buffer.length; i++) s += String.fromCharCode(buffer[i]);
                return s;
"""##,
        ##"""
            }
            return {
                initSign: function(key) { privateKey = key; buffer = []; },
                initVerify: function(key) { publicKey = key; buffer = []; },
                update: function(data) { appendBytes(data); },
                sign: function() {
                    if (!privateKey || !privateKey._keyBase64 || typeof java === 'undefined' || typeof java.createSign !== 'function') return [];
                    var signed = java.createSign(algorithm).setPrivateKey(privateKey._keyBase64).signBase64(bufferedString());
                    return _nativeBase64DecodeToBytes(signed || '');
                },
                verify: function(signature) {
                    if (!publicKey || !publicKey._keyBase64 || typeof java === 'undefined' || typeof java.createSign !== 'function') return false;
                    var sigB64 = _nativeBase64Encode(Array.prototype.slice.call(signature || []));
                    return !!java.createSign(algorithm).setPublicKey(publicKey._keyBase64).verify(bufferedString(), sigB64);
                },
                getAlgorithm: function() { return algorithm; }
            };
        }
    };
    Packages.java.security.Signature.__javaClassName = 'Signature';
}

// ------ java.io (最小存根) ------
Packages.java.io = Packages.java.io || {};
function __qireaderZeroBytes(length) {
    length = Math.max(0, Number(length) || 0);
    var arr = new Array(length);
    for (var i = 0; i < length; i++) arr[i] = 0;
    return arr;
}
function __qireaderNormalizeBytes(bytes) {
    if (!bytes) return [];
    return Array.prototype.slice.call(bytes).map(function(value) {
        return Number(value) & 0xFF;
    });
}
function __qireaderByteStream(bytes) {
    var source = __qireaderNormalizeBytes(bytes);
    return {
        _bytes: source,
        _pos: 0,
        read: function(target, offset, length) {
            if (arguments.length === 0) {
                if (this._pos >= this._bytes.length) return -1;
                return this._bytes[this._pos++] & 0xFF;
            }
            if (!target || typeof target.length !== 'number') return -1;
            offset = arguments.length > 1 ? Math.max(0, Number(offset) || 0) : 0;
            length = arguments.length > 2 ? Math.max(0, Number(length) || 0) : (target.length - offset);
            length = Math.min(length, Math.max(0, target.length - offset));
            if (length === 0) return 0;
            var remaining = this._bytes.length - this._pos;
            if (remaining <= 0) return -1;
            var count = Math.min(length, remaining);
            for (var i = 0; i < count; i++) {
                target[offset + i] = this._bytes[this._pos++] & 0xFF;
            }
            return count;
        },
        skip: function(count) {
            count = Math.max(0, Number(count) || 0);
            var skipped = Math.min(count, Math.max(0, this._bytes.length - this._pos));
            this._pos += skipped;
            return skipped;
        },
        available: function() {
            return Math.max(0, this._bytes.length - this._pos);
        },
        close: function() {},
        toByteArray: function() {
            return this._bytes.slice(this._pos);
        }
    };
}
if (!Packages.java.io.IOException) {
    Packages.java.io.IOException = function(message) {
        var error = new Error(String(message || ''));
        error.name = 'IOException';
        error.getMessage = function() { return error.message; };
        return error;
    };
    Packages.java.io.IOException.__javaClassName = 'IOException';
}
if (!Packages.java.io.ByteArrayInputStream) {
    Packages.java.io.ByteArrayInputStream = function(bytes) {
        return __qireaderByteStream(bytes);
    };
    Packages.java.io.ByteArrayInputStream.__javaClassName = 'ByteArrayInputStream';
}
if (!Packages.java.io.ByteArrayOutputStream) {
    Packages.java.io.ByteArrayOutputStream = function() {
        var buf = [];
        return {
            write: function(b, offset, length) {
                if (b === null || b === undefined) return;
                if (Array.isArray(b) || (typeof b === 'object' && typeof b.length === 'number')) {
                    var values = __qireaderNormalizeBytes(b);
                    var start = arguments.length > 1 ? Math.max(0, Number(offset) || 0) : 0;
                    var end = arguments.length > 2 ? Math.min(values.length, start + Math.max(0, Number(length) || 0)) : values.length;
                    for (var i = start; i < end; i++) buf.push(values[i] & 0xFF);
                    return;
                }
                buf.push(Number(b) & 0xFF);
            },
            toByteArray: function() { return buf; },
            reset: function() { buf = []; },
            close: function() {}
        };
    };
    Packages.java.io.ByteArrayOutputStream.__javaClassName = 'ByteArrayOutputStream';
}
if (!Packages.java.io.BufferedInputStream) {
    Packages.java.io.BufferedInputStream = function(input) {
        var stream = input || __qireaderByteStream([]);
        return {
            read: function(target, offset, length) {
                if (!stream || typeof stream.read !== 'function') return -1;
                if (arguments.length === 0) return stream.read();
                if (arguments.length === 1) return stream.read(target);
                if (arguments.length === 2) return stream.read(target, offset);
"""##,
        ##"""
                return stream.read(target, offset, length);
            },
            skip: function(count) {
                if (!stream || typeof stream.skip !== 'function') return 0;
                return stream.skip(count);
            },
            available: function() {
                if (!stream || typeof stream.available !== 'function') return 0;
                return stream.available();
            },
            close: function() {
                if (stream && typeof stream.close === 'function') stream.close();
            },
            toByteArray: function() {
                if (stream && typeof stream.toByteArray === 'function') return stream.toByteArray();
                return [];
            }
        };
    };
    Packages.java.io.BufferedInputStream.__javaClassName = 'BufferedInputStream';
}
if (!Packages.java.io.InputStreamReader) {
    Packages.java.io.InputStreamReader = function(input, charset) {
        var bytes = input && input._bytes ? input._bytes : [];
        var text = typeof _nativeBytesToStr === 'function' ? _nativeBytesToStr(Array.prototype.slice.call(bytes), charset || 'UTF-8') : '';
        var offset = 0;
        return {
            read: function() { return offset < text.length ? text.charCodeAt(offset++) : -1; },
            close: function() {},
            toString: function() { return text; }
        };
    };
}

// ------ java.util.zip ------
Packages.java.util = Packages.java.util || {};
Packages.java.util.zip = Packages.java.util.zip || {};
if (!Packages.java.util.zip.GZIPInputStream) {
    Packages.java.util.zip.GZIPInputStream = function(input) {
        var rawBytes = [];
        if (input && typeof input.toByteArray === 'function') {
            rawBytes = __qireaderNormalizeBytes(input.toByteArray());
        } else if (input && typeof input.read === 'function') {
            var temp = __qireaderZeroBytes(1024);
            var read;
            while ((read = input.read(temp)) > 0) {
                for (var i = 0; i < read; i++) rawBytes.push(temp[i] & 0xFF);
            }
        }
        var decompressed = typeof _nativeGunzip === 'function' ? _nativeGunzip(rawBytes) : rawBytes;
        var stream = __qireaderByteStream(decompressed);
        return {
            read: function(target, offset, length) {
                if (arguments.length === 0) return stream.read();
                if (arguments.length === 1) return stream.read(target);
                if (arguments.length === 2) return stream.read(target, offset);
                return stream.read(target, offset, length);
            },
            skip: function(count) {
                return stream.skip(count);
            },
            available: function() {
                return stream.available();
            },
            close: function() {},
            toByteArray: function() {
                return stream.toByteArray();
            }
        };
    };
    Packages.java.util.zip.GZIPInputStream.__javaClassName = 'GZIPInputStream';
}

// ------ java.nio ------
Packages.java.nio = Packages.java.nio || {};
if (!Packages.java.nio.ByteBuffer) {
    Packages.java.nio.ByteBuffer = {
        allocate: function(length) {
            var storage = __qireaderZeroBytes(length);
            return {
                array: function() { return storage; }
            };
        },
        wrap: function(bytes) {
            var storage = __qireaderNormalizeBytes(bytes);
            return {
                array: function() { return storage; }
            };
        }
    };
    Packages.java.nio.ByteBuffer.__javaClassName = 'ByteBuffer';
}

// ------ android.util.Base64 ------
// ------ java.net.URL (模拟 Java URL 类) ------
Packages.java.net = Packages.java.net || {};
if (!Packages.java.net.URL) {
    Packages.java.net.URL = function(urlStr) {
        var m = String(urlStr).match(/^(https?):\/\/([^:\/\?#]+)(?::(\d+))?(\/[^?#]*)?(?:\?([^#]*))?(?:#(.*))?/);
        var protocol = m ? m[1] : '';
        var host = m ? m[2] : '';
        var port = m && m[3] ? parseInt(m[3]) : -1;
        var path = m && m[4] ? m[4] : '/';
        var query = m && m[5] ? m[5] : '';
        var ref = m && m[6] ? m[6] : null;
        return {
            protocol: protocol,
            host: host,
            port: port,
            path: path,
            query: query,
            ref: ref,
            getProtocol: function() { return protocol; },
            getHost: function() { return host; },
            getPort: function() { return port; },
            getPath: function() { return path; },
            getQuery: function() { return query; },
            getRef: function() { return ref; },
            toString: function() { return String(urlStr); }
        };
"""##,
        ##"""
    };
}
if (!Packages.java.net.URLEncoder) {
    Packages.java.net.URLEncoder = {
        encode: function(value, charset) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var bytes = _nativeStrToBytes(RootString(value), charset || 'UTF-8');
            var out = '';
            var hex = '0123456789ABCDEF';
            for (var i = 0; i < bytes.length; i++) {
                var b = bytes[i] & 0xFF;
                if (b === 0x20) {
                    out += '+';
                } else if ((b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b === 0x2A || b === 0x2D || b === 0x2E || b === 0x5F) {
                    out += RootString.fromCharCode(b);
                } else {
                    out += '%' + hex[(b >> 4) & 0xF] + hex[b & 0xF];
                }
            }
            return out;
        }
    };
    Packages.java.net.URLEncoder.__javaClassName = 'URLEncoder';
}
if (!Packages.java.net.URLDecoder) {
    Packages.java.net.URLDecoder = {
        decode: function(value, charset) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var text = RootString(value);
            var bytes = [];
            for (var i = 0; i < text.length; i++) {
                var ch = text.charAt(i);
                if (ch === '+') {
                    bytes.push(0x20);
                } else if (ch === '%' && i + 2 < text.length) {
                    var hex = text.substr(i + 1, 2);
                    var b = parseInt(hex, 16);
                    if (!isNaN(b)) {
                        bytes.push(b & 0xFF);
                        i += 2;
                    } else {
                        bytes.push(ch.charCodeAt(0) & 0xFF);
                    }
                } else {
                    var raw = _nativeStrToBytes(ch, charset || 'UTF-8');
                    for (var j = 0; j < raw.length; j++) bytes.push(raw[j] & 0xFF);
                }
            }
            return _nativeBytesToStr(bytes, charset || 'UTF-8');
        }
    };
    Packages.java.net.URLDecoder.__javaClassName = 'URLDecoder';
}

// ------ java.math ------
Packages.java.math = Packages.java.math || {};
if (!Packages.java.math.BigInteger) {
    Packages.java.math.BigInteger = function(value, radix) {
        var n = parseInt(String(value || '0'), radix || 10);
        if (!isFinite(n)) n = 0;
        return {
            intValue: function() { return n | 0; },
            longValue: function() { return n; },
            toString: function(outRadix) { return Math.trunc(n).toString(outRadix || 10); }
        };
    };
    Packages.java.math.BigInteger.__javaClassName = 'BigInteger';
}

// ------ android.util.Base64 ------
Packages.android = Packages.android || {};
Packages.android.util = Packages.android.util || {};
if (!Packages.android.util.Base64 || !Packages.android.util.Base64.decode) {
    Packages.android.util.Base64 = {
        DEFAULT: 0,
        NO_WRAP: 2,
        NO_PADDING: 1,
        URL_SAFE: 8,
        decode: function(input, flags) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var str;
            if (__javaIsStringLike(input)) {
                str = RootString(input);
            } else {
                str = '';
                for (var i = 0; i < input.length; i++) str += String.fromCharCode(input[i] & 0xFF);
            }
            return _nativeBase64DecodeToBytes(str);
        },
        encode: function(input, flags) {
            var b64 = _nativeBase64Encode(Array.prototype.slice.call(input));
            var bytes = [];
            for (var i = 0; i < b64.length; i++) bytes.push(b64.charCodeAt(i));
            return bytes;
        },
        encodeToString: function(input, flags) {
            return _nativeBase64Encode(Array.prototype.slice.call(input));
        }
    };
}

// ------ android.text.TextUtils ------
Packages.android.text = Packages.android.text || {};
if (!Packages.android.text.TextUtils) {
    Packages.android.text.TextUtils = {
        isEmpty: function(s) { return s === null || s === undefined || String(s) === ''; },
        join: function(delimiter, tokens) {
            if (!tokens) return '';
            return Array.prototype.slice.call(tokens).join(String(delimiter));
        }
    };
}

// ------ android.graphics (最小存根，图片处理无法在 JSC 实现) ------
Packages.android.graphics = Packages.android.graphics || {};
if (!Packages.android.graphics.BitmapFactory) {
    Packages.android.graphics.BitmapFactory = {
        decodeStream: function() { return null; },
        decodeByteArray: function() { return null; }
    };
"""##,
        ##"""
}

// ------ cn.hutool ------
Packages.cn = Packages.cn || {};
Packages.cn.hutool = Packages.cn.hutool || {};
Packages.cn.hutool.core = Packages.cn.hutool.core || {};
Packages.cn.hutool.core.codec = Packages.cn.hutool.core.codec || {};
if (!Packages.cn.hutool.core.codec.Base64) {
    Packages.cn.hutool.core.codec.Base64 = {
        encode: function(data) {
            if (typeof data === 'string') return java.base64Encode(data);
            return _nativeBase64Encode(Array.prototype.slice.call(data));
        },
        decode: function(data) {
            return _nativeBase64DecodeToBytes(String(data));
        },
        decodeStr: function(data) {
            return java.base64Decode(String(data));
        }
    };
}
Packages.cn.hutool.core.util = Packages.cn.hutool.core.util || {};
if (!Packages.cn.hutool.core.util.StrUtil) {
    Packages.cn.hutool.core.util.StrUtil = {
        reverse: function(str) {
            return String(str).split('').reverse().join('');
        },
        isEmpty: function(str) {
            return str === null || str === undefined || String(str) === '';
        },
        isNotEmpty: function(str) {
            return !this.isEmpty(str);
        },
        isBlank: function(str) {
            return this.isEmpty(str) || String(str).trim() === '';
        },
        isNotBlank: function(str) {
            return !this.isBlank(str);
        }
    };
}
if (!Packages.cn.hutool.core.util.ZipUtil) {
    Packages.cn.hutool.core.util.ZipUtil = {
        unGzip: function(data) {
            return _nativeGunzip(Array.prototype.slice.call(data));
        },
        gzip: function(data, charset) {
            if (typeof data === 'string') {
                data = data.getBytes ? data.getBytes(charset || 'UTF-8') : data.split('').map(function(c) { return c.charCodeAt(0); });
            }
            if (typeof _nativeGzip === 'function') {
                return _nativeGzip(Array.prototype.slice.call(data));
            }
            return data;
        }
    };
}
Packages.cn.hutool.crypto = Packages.cn.hutool.crypto || {};
Packages.cn.hutool.crypto.digest = Packages.cn.hutool.crypto.digest || {};
if (!Packages.cn.hutool.crypto.digest.DigestUtil) {
    Packages.cn.hutool.crypto.digest.DigestUtil = {
        md5: function(data) {
            function hexToBytes(hex) {
                var out = [];
                for (var i = 0; i + 1 < hex.length; i += 2) {
                    out.push(parseInt(hex.substr(i, 2), 16));
                }
                return out;
            }
            if (typeof data === 'object' && data.length !== undefined) {
                var s = '';
                for (var i = 0; i < data.length; i++) s += String.fromCharCode(data[i] & 0xFF);
                return hexToBytes(java.md5Encode(s));
            }
            return hexToBytes(java.md5Encode(String(data)));
        },
        md5Hex: function(data) {
            if (typeof data === 'object' && data.length !== undefined) {
                var s = '';
                for (var i = 0; i < data.length; i++) s += String.fromCharCode(data[i] & 0xFF);
                return java.md5Encode(s);
            }
            return java.md5Encode(String(data));
        }
    };
}

// ------ io.legado.app.help.http.StrResponse ------
Packages.io = Packages.io || {};
Packages.io.legado = Packages.io.legado || {};
Packages.io.legado.app = Packages.io.legado.app || {};
Packages.io.legado.app.help = Packages.io.legado.app.help || {};
Packages.io.legado.app.help.http = Packages.io.legado.app.help.http || {};
if (!Packages.io.legado.app.help.http.StrResponse) {
    Packages.io.legado.app.help.http.StrResponse = function(url, body) {
        var _url = url || '';
        var _body = (body !== undefined && body !== null) ? String(body) : '';
        return {
            url: function() { return _url; },
            body: function() { return _body; },
            toString: function() { return _body; }
        };
    };
}

// ------ org.jsoup (链接已有 Jsoup 桥接) ------
Packages.org = Packages.org || {};
Packages.org.jsoup = Packages.org.jsoup || {};
if (typeof org !== 'undefined' && org.jsoup && org.jsoup.Jsoup) {
    Packages.org.jsoup.Jsoup = org.jsoup.Jsoup;
}
Packages.org.jsoup.nodes = Packages.org.jsoup.nodes || {};
Packages.org.jsoup.nodes.Document = Packages.org.jsoup.nodes.Document || function() {};
Packages.org.jsoup.nodes.Element = Packages.org.jsoup.nodes.Element || function() {};

// ------ okhttp3 (最小存根，使用 java.ajax 桥接) ------

/**
 * okhttp3 stub 用的取数函数。
 *
"""##,
        ##"""
 * ⚠️⚠️ **这个函数以前根本没定义**（用了没声明 → 运行时 ReferenceError）：
 *    eslint 的 no-undef 扫出来的（其它门禁都抓不到 —— JS 的未声明变量
 *    只有运行时才炸，而 node 的 vm 上下文用 Proxy 拦全局对象，
 *    严格模式对未声明变量赋值**根本不抛** → jsdom 永远测不出来）。
 *    ⇒ 任何用到 okhttp3 的书源都会在运行时炸。
 *
 * 用引擎自己的请求通道：`java.ajax(url + ',{json}')`
 * （两遍跑机制认这个 `,{json}` 后缀，会把 method/headers/body 带去真请求）✅
 */
function _jsoupConnectFetch(url, method, body, headersJson) {
  var opts = { method: String(method || 'GET') };
  try {
    var h = JSON.parse(headersJson || '{}');
    if (h && typeof h === 'object' && Object.keys(h).length) opts.headers = h;
  } catch (e) { /* 头解析不了就算了 */ }
  if (body) opts.body = String(body);
  var full = String(url) + ',' + JSON.stringify(opts);
  var resp = '';
  try { resp = String(java.ajax(full)); } catch (e) { resp = ''; }
  return {
    body: resp,
    bytes: [],
    code: resp ? 200 : 0,
    url: String(url),
    headers: {}
  };
}

Packages.okhttp3 = Packages.okhttp3 || {};
if (!Packages.okhttp3.OkHttpClient) {
    Packages.okhttp3.OkHttpClient = function() {
        return {
            newCall: function(request) {
                return {
                    execute: function() {
                        var hJson = JSON.stringify(request._headers || {});
                        var resp = _jsoupConnectFetch(request._url, request._method || 'GET', request._body || '', hJson);
                        var respHeaders = resp.headers || {};
                        return {
                            _body: resp.body || '',
                            _bytes: resp.bytes || [],
                            _code: resp.code || 0,
                            _url: request._url,
                            _headers: respHeaders,
                            body: function() {
                                var self = this;
                                return {
                                    string: function() { return self._body; },
                                    bytes: function() { return self._bytes; },
                                    contentType: function() { return null; },
                                    close: function() {}
                                };
                            },
                            code: function() { return this._code; },
                            headers: function() {
                                var h = this._headers;
                                return {
                                    _map: h,
                                    get: function(name) { return h[name] || h[name.toLowerCase()] || null; },
                                    names: function() {
                                        var arr = [];
                                        for (var k in h) { if (h.hasOwnProperty(k)) arr.push(k); }
                                        // 添加 forEach 支持
                                        arr.forEach = arr.forEach || Array.prototype.forEach;
                                        return arr;
                                    }
                                };
                            },
                            close: function() {},
                            isSuccessful: function() { return this._code >= 200 && this._code < 300; }
                        };
                    }
                };
            }
        };
    };
    Packages.okhttp3.Request = {
        Builder: function() {
            var _url = '', _method = 'GET', _body = '', _headers = {};
            return {
                url: function(u) { _url = String(u); return this; },
                get: function() { _method = 'GET'; return this; },
                post: function(body) { _method = 'POST'; _body = body ? body._content || '' : ''; return this; },
                addHeader: function(name, value) { _headers[name] = value; return this; },
                header: function(name, value) { _headers[name] = value; return this; },
                build: function() { return { _url: _url, _method: _method, _body: _body, _headers: _headers }; }
            };
        }
    };
    Packages.okhttp3.RequestBody = {
        create: function(contentType, content) {
            return { _content: String(content || '') };
        }
    };
    Packages.okhttp3.MediaType = {
        parse: function(type) { return { _type: type }; }
    };
}

// ====== Rhino Java String 兼容方法 ======
// String.prototype 补充 Java String 兼容方法
if (!String.prototype.isEmpty) {
    String.prototype.isEmpty = function() { return this.length === 0; };
}
if (!String.prototype.contains) {
    String.prototype.contains = function(s) { return this.indexOf(s) >= 0; };
}
if (!String.prototype.equals) {
    String.prototype.equals = function(other) { return this.valueOf() === String(other); };
}
if (!String.prototype.equalsIgnoreCase) {
    String.prototype.equalsIgnoreCase = function(other) { return this.toLowerCase() === String(other).toLowerCase(); };
}

// 让脚本的顶层完成值是 undefined：WebKit 的 evaluateJavaScript 会把完成值
// 桥接回 Swift，普通 JS 对象/函数/Symbol 桥接不了 →
// WKError.resultTypeIsUnsupported → 轻阅报「引擎脚本执行出错」，整个引擎起不来。
// 栖阅原文件没有这行（它不走 evaluateJavaScript 返回值桥接），移植后必须补。
;void 0;

"""##,
    ].joined(separator: "\n")

    /// `packagesNative` 的源码（分块拼接 ⇒ 避免超长字面量把编译器压垮）
    static let packagesNativeSource: String = [
        ##"""
// ============================================================================
// packages-native.js —— 给「栖阅 packages_stub.js」补齐它依赖的原生函数
// ============================================================================
//
// 背景：栖阅把书源规则引擎编在 29MB 的 Swift 二进制里，JS 侧只留了一层
// 兼容层 packages_stub.js，它把 `Packages.javax.crypto.Cipher` 这些 Java 类
// 映射到 8~10 个 `_native*` 原生函数上。栖阅那边是 Swift 实现，搬不过来。
//
// 这里用**纯 JS** 把这些原生函数补上，让 packages_stub.js 能在轻阅里跑。
// 全部实现都是同步的（栖阅的 native 也是同步语义）。
//
// 注入顺序：必须在 packages_stub.js **之前**加载 ——
//   packages_stub.js 顶层就会定义 String.prototype.getBytes，函数体里就用 _nativeStrToBytes。
//
// ── 编码支持现状 ──
//   UTF-8 / ISO-8859-1 / US-ASCII：完整支持
//   GBK / GB18030 / Big5：**降级按 UTF-8 处理**（原生实现是 Swift 的 String.Encoding，
//   完整支持需要几十 KB 的编码表）。书源里密钥几乎都用 UTF-8，GBK 只在少数老源出现。
//   传入 GBK 且实际不是 UTF-8 时结果会不对 —— 这是已知限制，不是 bug。
//
// ── gzip ──
//   用 Web 标准的 CompressionStream / DecompressionStream（Safari 16.4+ / iOS 17+）。
//   轻阅部署目标 iOS 17，够用。不引第三方库。
//
// ── cipher ──
//   支持：AES/ECB/PKCS5Padding、AES/CBC/PKCS5Padding、AES/ECB/NoPadding、AES/CBC/NoPadding
//   不支持：DES / 3DES / Blowfish / GCM / CTR —— 明确抛错，不静默出错结果。

(function (g) {
  'use strict';
  if (typeof g === 'undefined') g = (typeof globalThis !== 'undefined') ? globalThis : this;
  var W = g;

  // ────────────────────────────────────────────────────────────────────────
  // 字节工具
  // ────────────────────────────────────────────────────────────────────────

  function toArray(b) {
    if (!b) return [];
    if (typeof b === 'string') {
      var out = [], enc = utf8Encode(b);
      for (var i = 0; i < enc.length; i++) out.push(enc[i]);
      return out;
    }
    if (b instanceof Uint8Array) return Array.prototype.slice.call(b);
    if (typeof b.length === 'number') return Array.prototype.slice.call(b);
    return [];
  }

  function utf8Encode(str) {
    if (typeof TextEncoder !== 'undefined') return Array.from(new TextEncoder().encode(str));
    // 兜底手写 UTF-8
    var out = [], i, c;
    for (i = 0; i < str.length; i++) {
      c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        i++;
      } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
    }
    return out;
  }

  function utf8Decode(bytes) {
    if (typeof TextDecoder !== 'undefined') {
      return new TextDecoder('utf-8').decode(new Uint8Array(bytes));
    }
    var s = '', i = 0, b, c;
    while (i < bytes.length) {
      b = bytes[i++];
      if (b < 0x80) c = b;
      else if (b < 0xe0) c = ((b & 31) << 6) | (bytes[i++] & 63);
      else if (b < 0xf0) c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      else {
        c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
        c -= 0x10000;
        s += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023));
        continue;
      }
      s += String.fromCharCode(c);
    }
    return s;
  }

  // 单字节编码（ISO-8859-1 / ASCII）
  function latin1Encode(str) {
    var out = [], i;
    for (i = 0; i < str.length; i++) out.push(str.charCodeAt(i) & 0xff);
    return out;
  }
  function latin1Decode(bytes) {
    var s = '', i;
    for (i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 0xff);
    return s;
  }

  function encodeByCharset(str, charset) {
    var cs = String(charset || 'UTF-8').toUpperCase();
    if (cs === 'ISO-8859-1' || cs === 'ISO8859-1' || cs === 'LATIN1' || cs === 'US-ASCII' || cs === 'ASCII') {
      return latin1Encode(str);
    }
    return utf8Encode(str);   // UTF-8 及其它一律按 UTF-8
  }

  function decodeByCharset(bytes, charset) {
    var cs = String(charset || 'UTF-8').toUpperCase();
    if (cs === 'ISO-8859-1' || cs === 'ISO8859-1' || cs === 'LATIN1' || cs === 'US-ASCII' || cs === 'ASCII') {
      return latin1Decode(bytes);
    }
    return utf8Decode(bytes);
  }

  // ────────────────────────────────────────────────────────────────────────
  // Base64
  // ────────────────────────────────────────────────────────────────────────

"""##,
        ##"""
  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function b64EncodeBytes(bytes) {
    var b = toArray(bytes), out = '', i;
    for (i = 0; i < b.length; i += 3) {
      var b0 = b[i] & 0xff, b1 = b[i + 1] & 0xff, b2 = b[i + 2] & 0xff;
      out += B64C.charAt(b0 >> 2);
      out += B64C.charAt(((b0 & 3) << 4) | (b1 >> 4));
      out += (i + 1 < b.length) ? B64C.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      out += (i + 2 < b.length) ? B64C.charAt(b2 & 63) : '=';
    }
    return out;
  }

  function b64DecodeToBytes(str) {
    var s = String(str || '').replace(/[\r\n\s]/g, '').replace(/=+$/, '');
    var out = [], i;
    // ⚠️ 不能靠 indexOf 返回 -1 来判断"字符缺失"——
    //    String.indexOf('') 返回 **0**，会把空位当成合法的 'A'，多解出字节。
    //    所以这里用 i+n < length 显式判断每组还剩几个字符。
    for (i = 0; i + 1 < s.length; i += 4) {
      var e0 = B64C.indexOf(s.charAt(i));
      var e1 = B64C.indexOf(s.charAt(i + 1));
      if (e0 < 0 || e1 < 0) break;
      out.push(((e0 << 2) | (e1 >> 4)) & 0xff);
      if (i + 2 < s.length) {
        var e2 = B64C.indexOf(s.charAt(i + 2));
        if (e2 < 0) break;
        out.push((((e1 & 15) << 4) | (e2 >> 2)) & 0xff);
        if (i + 3 < s.length) {
          var e3 = B64C.indexOf(s.charAt(i + 3));
          if (e3 < 0) break;
          out.push((((e2 & 3) << 6) | e3) & 0xff);
        }
      }
    }
    return out;
  }

  // ────────────────────────────────────────────────────────────────────────
  // AES（纯 JS）
  // ────────────────────────────────────────────────────────────────────────

  var SBOX = new Uint8Array(256), INV_SBOX = new Uint8Array(256);
  (function () {
    // S 盒 = GF(2^8) 上的乘法逆元 + 仿射变换。
    // 逆元用**暴力求**（gmul 找乘积为 1 的那个 b），不建 exp/log 幂表 ——
    // 幂表那条路容易在约简多项式/移位上错，而且错了不报错、只出错误密文。
    var sbox = new Uint8Array(256);
    function rotl8(v, n) { return ((v << n) | (v >>> (8 - n))) & 0xff; }
    for (var a = 0; a < 256; a++) {
      var inv = 0;
      // a=0 的逆元按 AES 规定取 0（不是 1），再走仿射变换 → S[0] = 0x63
      if (a !== 0) {
        for (var b = 1; b < 256; b++) {
          if (gmul(a, b) === 1) { inv = b; break; }
        }
      }
      sbox[a] = (inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63) & 0xff;
    }
    SBOX = sbox;
    for (var z = 0; z < 256; z++) { INV_SBOX[SBOX[z]] = z; }
  })();

  var RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d];

  function xtime(a) { return ((a << 1) ^ ((a & 0x80) ? 0x1b : 0)) & 0xff; }
  function gmul(a, b) {
    var p = 0, i, x = a, y = b;
    for (i = 0; i < 8; i++) {
      if (y & 1) p ^= x;
      x = xtime(x);
      y >>= 1;
    }
    return p & 0xff;
  }

  function expandKey(key) {
    var nk = key.length / 4, nr = nk + 6, w = [];
    var i, j;
    for (i = 0; i < nk; i++) {
      w[i] = [(key[4 * i] & 0xff), (key[4 * i + 1] & 0xff), (key[4 * i + 2] & 0xff), (key[4 * i + 3] & 0xff)];
    }
    for (i = nk; i < 4 * (nr + 1); i++) {
      var temp = [w[i - 1][0], w[i - 1][1], w[i - 1][2], w[i - 1][3]];
      if (i % nk === 0) {
        // RotWord → SubWord → XOR Rcon
        var t = temp[0];
        temp = [temp[1], temp[2], temp[3], t];
        for (j = 0; j < 4; j++) temp[j] = SBOX[temp[j]];
        temp[0] ^= RCON[i / nk - 1];
      } else if (nk > 6 && i % nk === 4) {
        // AES-192/256 的额外 SubWord
        for (j = 0; j < 4; j++) temp[j] = SBOX[temp[j]];
      }
      // ⚠️ w[i-nk] 的 XOR **只在这里做一次** ——
      //    在 RotWord 分支里再 XOR 一遍会导致双重异或，密钥扩展整个错掉（且不报错）。
      // ⚠️ 同样必须先攒够 4 个字节再赋值 ——
      //    写成 w[i] = [w[i-nk][j] ^ temp[j]] 会在循环里把整个字覆盖成单元素数组。
      var nw = [];
      for (j = 0; j < 4; j++) nw[j] = (w[i - nk][j] ^ temp[j]) & 0xff;
      w[i] = nw;
    }
    return { w: w, nr: nr };
  }

  function addRoundKey(s, w, rnd) {
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) s[r][c] ^= w[rnd * 4 + c][r];
    }
  }

  function subBytes(s, box) {
    for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) s[r][c] = box[s[r][c]];
  }

  // s[r][c]：r = 行，c = 列；state[r][c] = block[r + 4c]
  function shiftRows(s) {
    var t;
    // 行1：左移 1
"""##,
        ##"""
    t = s[1][0]; s[1][0] = s[1][1]; s[1][1] = s[1][2]; s[1][2] = s[1][3]; s[1][3] = t;
    // 行2：左移 2（两两对换，4 个都要换）
    t = s[2][0]; s[2][0] = s[2][2]; s[2][2] = t;
    t = s[2][1]; s[2][1] = s[2][3]; s[2][3] = t;
    // 行3：左移 3（= 右移 1）
    t = s[3][0]; s[3][0] = s[3][3]; s[3][3] = s[3][2]; s[3][2] = s[3][1]; s[3][1] = t;
  }

  function invShiftRows(s) {
    var t;
    // 行1：右移 1
    t = s[1][3]; s[1][3] = s[1][2]; s[1][2] = s[1][1]; s[1][1] = s[1][0]; s[1][0] = t;
    // 行2：右移 2
    t = s[2][0]; s[2][0] = s[2][2]; s[2][2] = t;
    t = s[2][1]; s[2][1] = s[2][3]; s[2][3] = t;
    // 行3：右移 3（= 左移 1）
    t = s[3][0]; s[3][0] = s[3][1]; s[3][1] = s[3][2]; s[3][2] = s[3][3]; s[3][3] = t;
  }

  function mixColumns(s) {
    for (var c = 0; c < 4; c++) {
      var a0 = s[0][c], a1 = s[1][c], a2 = s[2][c], a3 = s[3][c];
      s[0][c] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3;
      s[1][c] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3;
      s[2][c] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3);
      s[3][c] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2);
    }
  }

  function invMixColumns(s) {
    for (var c = 0; c < 4; c++) {
      var a0 = s[0][c], a1 = s[1][c], a2 = s[2][c], a3 = s[3][c];
      s[0][c] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
      s[1][c] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
      s[2][c] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
      s[3][c] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
    }
  }

  function aesEncryptBlock(block, ks) {
    var s = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], r, c, i;
    for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) s[r][c] = block[r + 4 * c] & 0xff;
    addRoundKey(s, ks.w, 0);
    for (i = 1; i < ks.nr; i++) {
      subBytes(s, SBOX); shiftRows(s); mixColumns(s); addRoundKey(s, ks.w, i);
    }
    subBytes(s, SBOX); shiftRows(s); addRoundKey(s, ks.w, ks.nr);
    var out = new Array(16);
    for (c = 0; c < 4; c++) for (r = 0; r < 4; r++) out[r + 4 * c] = s[r][c];
    return out;
  }

  function aesDecryptBlock(block, ks) {
    var s = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], r, c, i;
    for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) s[r][c] = block[r + 4 * c] & 0xff;
    addRoundKey(s, ks.w, ks.nr);
    for (i = ks.nr - 1; i >= 1; i--) {
      invShiftRows(s); subBytes(s, INV_SBOX); addRoundKey(s, ks.w, i); invMixColumns(s);
    }
    invShiftRows(s); subBytes(s, INV_SBOX); addRoundKey(s, ks.w, 0);
    var out = new Array(16);
    for (c = 0; c < 4; c++) for (r = 0; r < 4; r++) out[r + 4 * c] = s[r][c];
    return out;
  }

  function pkcs5Pad(bytes, blockSize) {
    var pad = blockSize - (bytes.length % blockSize);
    var out = bytes.slice();
    for (var i = 0; i < pad; i++) out.push(pad);
    return out;
  }

  function pkcs5Unpad(bytes) {
    if (!bytes.length) return bytes;
    var pad = bytes[bytes.length - 1];
    if (pad < 1 || pad > 16 || pad > bytes.length) return bytes;   // 越界就不动（别静默吞数据）
    return bytes.slice(0, bytes.length - pad);
  }

  function aesCbcEncrypt(data, key, iv, pad) {
    var ks = expandKey(key), bs = 16, out = [];
    var d = pad ? pkcs5Pad(data, bs) : data;
    var prev = iv ? iv.slice(0) : new Array(bs).fill(0);
    for (var off = 0; off < d.length; off += bs) {
      var block = new Array(bs), i;
      for (i = 0; i < bs; i++) block[i] = (d[off + i] || 0) ^ (prev[i] || 0);
      var enc = aesEncryptBlock(block, ks);
      out = out.concat(enc);
      prev = enc;
    }
    return out;
  }

  function aesCbcDecrypt(data, key, iv, unpad) {
    var ks = expandKey(key), bs = 16, out = [];
    var prev = iv ? iv.slice(0) : new Array(bs).fill(0);
    for (var off = 0; off < data.length; off += bs) {
      var block = data.slice(off, off + bs), i, c;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      var dec = aesDecryptBlock(block, ks);
      for (i = 0; i < bs; i++) out.push((dec[i] ^ (prev[i] || 0)) & 0xff);
      prev = block;
    }
    return unpad ? pkcs5Unpad(out) : out;
  }

  function aesEcbEncrypt(data, key, pad) {
    var ks = expandKey(key), bs = 16, out = [];
    var d = pad ? pkcs5Pad(data, bs) : data;
    for (var off = 0; off < d.length; off += bs) {
      var block = d.slice(off, off + bs), i;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      out = out.concat(aesEncryptBlock(block, ks));
    }
    return out;
  }

  function aesEcbDecrypt(data, key, unpad) {
    var ks = expandKey(key), bs = 16, out = [];
    for (var off = 0; off < data.length; off += bs) {
"""##,
        ##"""
      var block = data.slice(off, off + bs), i;
      for (i = 0; i < bs; i++) block[i] = block[i] || 0;
      out = out.concat(aesDecryptBlock(block, ks));
    }
    return unpad ? pkcs5Unpad(out) : out;
  }

  function cipherProcess(dataB64, keyB64, transform, ivB64, isDecrypt) {
    var t = String(transform || '').toUpperCase();
    var algo = t.split('/')[0];
    var mode = (t.split('/')[1] || 'ECB').toUpperCase();
    var padMode = (t.split('/')[2] || 'PKCS5PADDING').toUpperCase();

    if (algo !== 'AES') {
      throw new Error('cipherProcess: 不支持的算法 ' + algo + '（当前只支持 AES）');
    }
    if (mode !== 'ECB' && mode !== 'CBC') {
      throw new Error('cipherProcess: 不支持的模式 ' + mode + '（当前只支持 ECB/CBC）');
    }
    if (padMode !== 'PKCS5PADDING' && padMode !== 'NOPADDING') {
      throw new Error('cipherProcess: 不支持的填充 ' + padMode + '（当前只支持 PKCS5Padding/NoPadding）');
    }

    var data = b64DecodeToBytes(dataB64);
    var key = b64DecodeToBytes(keyB64);
    var iv = ivB64 ? b64DecodeToBytes(ivB64) : null;
    if (key.length !== 16 && key.length !== 24 && key.length !== 32) {
      throw new Error('cipherProcess: AES 密钥长度非法 ' + key.length + '（需 16/24/32）');
    }
    if (mode === 'CBC' && !iv) {
      throw new Error('cipherProcess: CBC 模式必须有 IV');
    }

    var usePad = padMode === 'PKCS5PADDING';
    var out;
    if (mode === 'CBC') {
      out = isDecrypt ? aesCbcDecrypt(data, key, iv, usePad)
                      : aesCbcEncrypt(data, key, iv, usePad);
    } else {
      out = isDecrypt ? aesEcbDecrypt(data, key, usePad)
                      : aesEcbEncrypt(data, key, usePad);
    }
    return b64EncodeBytes(out);
  }

  // ────────────────────────────────────────────────────────────────────────
  // gzip —— 同步纯 JS 实现
  // ────────────────────────────────────────────────────────────────────────
  //
  // 为什么不用 CompressionStream：它是 **异步** 的（返回 Promise），
  // 而栖阅的 _nativeGzip/_nativeGunzip 是**同步**契约 ——
  // packages_stub 里直接 `var decompressed = _nativeGunzip(rawBytes)` 就当字节数组用。
  // 返回 Promise 会直接把引擎搞坏。
  //
  // 解压：完整 inflate（stored / fixed / dynamic 三种块都支持）
  // 压缩：gzip 容器 + deflate **stored 块**（不压缩，但格式完全合法，
  //       Java GZIPInputStream / Node zlib / unzip 都能解）

  var CRC_TABLE = (function () {
    var t = new Uint32Array(256), c, n, k;
    for (n = 0; n < 256; n++) {
      c = n;
      for (k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();

  function crc32(bytes) {
    var c = 0xffffffff;
    for (var i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }

  // ---- inflate ----

  var LEN_BASE = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
  var LEN_EXTRA = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
  var DIST_BASE = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
  var DIST_EXTRA = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
  var CLEN_ORDER = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];

  // 规范 Huffman：count[len] = 该长度的码字数，symbol[] 按码值升序
  function buildHuffman(lengths) {
    var MAXBITS = 15, count = [], symbol = [], i, len, left;
    count.length = MAXBITS + 1;
    for (i = 0; i < lengths.length; i++) count[lengths[i]] = (count[lengths[i]] || 0) + 1;
    count[0] = 0;
    var offs = [];
    offs.length = MAXBITS + 2;
    offs[1] = 0;
    // ⚠️ count 是稀疏数组，count[len] 可能是 **undefined** ——
    //    直接参与加法会得到 NaN，然后 NaN 污染所有后续 offs，
    //    最后 symbol[NaN] = i 写到无效键上，整个 symbol 数组全是 undefined，
    //    而且**不报任何错**，只是解出来的全是垃圾。
    for (len = 1; len <= MAXBITS; len++) offs[len + 1] = offs[len] + (count[len] || 0);
    symbol = new Array(lengths.length);
    for (i = 0; i < lengths.length; i++) {
      if (lengths[i]) symbol[offs[lengths[i]]++] = i;
    }
    return { count: count, symbol: symbol };
  }

  function BitReader(data, pos) {
    this.data = data;
    this.pos = pos || 0;
    this.bitBuf = 0;
    this.bitCnt = 0;
  }
  BitReader.prototype.readBit = function () {
    if (this.bitCnt === 0) {
      if (this.pos >= this.data.length) throw new Error('inflate: 数据意外结束');
      this.bitBuf = this.data[this.pos++] & 0xff;
      this.bitCnt = 8;
    }
    var b = this.bitBuf & 1;
    this.bitBuf >>= 1;
    this.bitCnt--;
    return b;
  };
"""##,
        ##"""
  BitReader.prototype.readBits = function (n) {
    var v = 0, i;
    for (i = 0; i < n; i++) v |= this.readBit() << i;
    return v;
  };
  BitReader.prototype.decode = function (huff) {
    var code = 0, first = 0, index = 0, len, count = huff.count, symbol = huff.symbol;
    for (len = 1; len <= 15; len++) {
      code |= this.readBit();
      var cnt = count[len] || 0;
      if (code - cnt < first) return symbol[index + (code - first)];
      index += cnt;
      first += cnt;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('inflate: 无效的 Huffman 码');
  };
  BitReader.prototype.align = function () { this.bitCnt = 0; this.bitBuf = 0; };

  function fixedTables() {
    var lengths = new Array(288), i;
    for (i = 0; i < 144; i++) lengths[i] = 8;
    for (i = 144; i < 256; i++) lengths[i] = 9;
    for (i = 256; i < 280; i++) lengths[i] = 7;
    for (i = 280; i < 288; i++) lengths[i] = 8;
    var dist = new Array(30);
    for (i = 0; i < 30; i++) dist[i] = 5;
    return { lit: buildHuffman(lengths), dist: buildHuffman(dist) };
  }

  function inflateRaw(data, startPos) {
    var br = new BitReader(data, startPos);
    var out = [];
    var fixed = null;
    var last = 0;
    do {
      last = br.readBit();
      var type = br.readBits(2);
      if (type === 0) {
        // stored
        br.align();
        if (br.pos + 4 > data.length) throw new Error('inflate: stored 块头部不完整');
        var len = data[br.pos] | (data[br.pos + 1] << 8);
        var nlen = data[br.pos + 2] | (data[br.pos + 3] << 8);
        br.pos += 4;
        if ((len ^ 0xffff) !== nlen) throw new Error('inflate: stored 块长度校验失败');
        if (br.pos + len > data.length) throw new Error('inflate: stored 块数据不完整');
        for (var i = 0; i < len; i++) out.push(data[br.pos++] & 0xff);
      } else if (type === 1 || type === 2) {
        var lit, dist;
        if (type === 1) {
          if (!fixed) fixed = fixedTables();
          lit = fixed.lit; dist = fixed.dist;
        } else {
          var hlit = br.readBits(5) + 257;
          var hdist = br.readBits(5) + 1;
          var hclen = br.readBits(4) + 4;
          var clens = new Array(19);
          var k;
          for (k = 0; k < 19; k++) clens[k] = 0;
          for (k = 0; k < hclen; k++) clens[CLEN_ORDER[k]] = br.readBits(3);
          var clHuff = buildHuffman(clens);
          var lengths = new Array(hlit + hdist);
          var idx = 0;
          while (idx < hlit + hdist) {
            var sym = br.decode(clHuff);
            if (sym < 16) { lengths[idx++] = sym; }
            else if (sym === 16) {
              if (idx === 0) throw new Error('inflate: 重复码没有前值');
              var prev = lengths[idx - 1];
              var rep = 3 + br.readBits(2);
              while (rep-- > 0 && idx < lengths.length) lengths[idx++] = prev;
            } else if (sym === 17) {
              var rep17 = 3 + br.readBits(3);
              while (rep17-- > 0 && idx < lengths.length) lengths[idx++] = 0;
            } else {
              var rep18 = 11 + br.readBits(7);
              while (rep18-- > 0 && idx < lengths.length) lengths[idx++] = 0;
            }
          }
          var litLengths = lengths.slice(0, hlit);
          var distLengths = lengths.slice(hlit);
          lit = buildHuffman(litLengths);
          dist = buildHuffman(distLengths);
        }
        // 解码符号
        for (;;) {
          var sym = br.decode(lit);
          if (sym < 256) { out.push(sym); continue; }
          if (sym === 256) break;
          sym -= 257;
          if (sym >= 29) throw new Error('inflate: 无效的长度码 ' + sym);
          var length = LEN_BASE[sym] + br.readBits(LEN_EXTRA[sym]);
          var dsym = br.decode(dist);
          if (dsym >= 30) throw new Error('inflate: 无效的距离码 ' + dsym);
          var distance = DIST_BASE[dsym] + br.readBits(DIST_EXTRA[dsym]);
          if (distance > out.length) throw new Error('inflate: 距离超出已解压数据');
          var start = out.length - distance;
          for (var j = 0; j < length; j++) out.push(out[start + j]);
        }
      } else {
        throw new Error('inflate: 保留的块类型 3');
      }
    } while (!last);
    return { bytes: out, pos: br.pos };
  }

  function gunzipBytes(bytes) {
    var d = toArray(bytes);
    if (d.length < 18) throw new Error('gunzip: 数据太短');
    if ((d[0] & 0xff) !== 0x1f || (d[1] & 0xff) !== 0x8b) throw new Error('gunzip: 不是 gzip 数据');
    if ((d[2] & 0xff) !== 8) throw new Error('gunzip: 不支持的压缩方法 ' + (d[2] & 0xff));
    var flg = d[3] & 0xff;
    var p = 10;
    if (flg & 0x04) {                                   // FEXTRA
      var xlen = d[p] | (d[p + 1] << 8); p += 2 + xlen;
    }
    if (flg & 0x08) {                                   // FNAME
      while (p < d.length && d[p] !== 0) p++;
"""##,
        ##"""
      p++;
    }
    if (flg & 0x10) {                                   // FCOMMENT
      while (p < d.length && d[p] !== 0) p++;
      p++;
    }
    if (flg & 0x02) { p += 2; }                         // FHCRC
    var r = inflateRaw(d, p);
    // 尾部 8 字节：CRC32 + ISIZE
    var tail = d.length - 8;
    if (tail >= 0) {
      var isize = (d[d.length - 4] | (d[d.length - 3] << 8) | (d[d.length - 2] << 16) | (d[d.length - 1] << 24)) >>> 0;
      if (isize !== (r.bytes.length >>> 0)) {
        throw new Error('gunzip: 长度校验失败（期望 ' + isize + '，实际 ' + r.bytes.length + '）');
      }
    }
    return r.bytes;
  }

  function gzipBytes(bytes) {
    var d = toArray(bytes);
    var out = [];
    var i;
    // gzip header
    out.push(0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff);
    // deflate stored 块（最大 65535 一块）
    var off = 0;
    do {
      var len = Math.min(65535, d.length - off);
      var last = (off + len >= d.length) ? 1 : 0;
      out.push(last);                                   // BFINAL + BTYPE=00
      out.push(len & 0xff, (len >> 8) & 0xff);
      out.push((len ^ 0xffff) & 0xff, ((len ^ 0xffff) >> 8) & 0xff);
      for (i = 0; i < len; i++) out.push(d[off + i]);
      off += len;
    } while (off < d.length);
    // CRC32 + ISIZE
    var c = crc32(d);
    out.push(c & 0xff, (c >>> 8) & 0xff, (c >>> 16) & 0xff, (c >>> 24) & 0xff);
    var n = d.length >>> 0;
    out.push(n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff);
    return out;
  }

  // ────────────────────────────────────────────────────────────────────────
  // JSONPath —— 委托给轻阅自带的 jsonpath.js
  // ────────────────────────────────────────────────────────────────────────

  function jsonPathRead(json, path, suppress) {
    try {
      if (W.JSONPath && typeof W.JSONPath.read === 'function') {
        return W.JSONPath.read(json, path);
      }
      if (W.jsonpath && typeof W.jsonpath.read === 'function') {
        return W.jsonpath.read(json, path);
      }
    } catch (e) {
      if (!suppress) throw e;
    }
    if (suppress) return null;
    throw new Error('jsonPathRead: 找不到 JSONPath 实现');
  }

  // ────────────────────────────────────────────────────────────────────────
  // 注册到 global
  // ────────────────────────────────────────────────────────────────────────

  W._nativeStrToBytes = function (str, charset) {
    return encodeByCharset(str == null ? '' : String(str), charset);
  };

  W._nativeBytesToStr = function (bytes, charset) {
    return decodeByCharset(toArray(bytes), charset || 'UTF-8');
  };

  W._nativeBase64Encode = function (bytes) {
    return b64EncodeBytes(toArray(bytes));
  };

  W._nativeBase64DecodeToBytes = function (str) {
    return b64DecodeToBytes(str);
  };

  W._nativeCipherProcess = cipherProcess;

  W._nativeGzip = function (bytes) { return gzipBytes(bytes); };
  W._nativeGunzip = function (bytes) { return gunzipBytes(bytes); };

  W._nativeJsonPathRead = jsonPathRead;

  W._nativeSleepMillis = function (ms) {
    // JS 单线程没有同步 sleep。栖阅那边是真阻塞。
    // 书源里极少调用，这里用忙等兜底（小数值），大数值直接返回。
    var n = Number(ms) || 0;
    if (n <= 0) return;
    if (n > 50) return;             // 太长不阻塞主线程
    var end = Date.now() + n;
    while (Date.now() < end) { /* 忙等 */ }
  };

  W._nativeBase = function (bytes, from, to) {
    // 编码转换：from → to
    var s = decodeByCharset(toArray(bytes), from || 'UTF-8');
    return encodeByCharset(s, to || 'UTF-8');
  };

  // ────────────────────────────────────────────────────────────────────────
  // java.digestHex —— MessageDigest 依赖它
  // ────────────────────────────────────────────────────────────────────────
  //
  // packages_stub 的 MessageDigest 是这么算摘要的：
  //     if (typeof java !== 'undefined' && java.digestHex) return java.digestHex(text, algorithmName);
  //     if (algorithmName === 'MD5' && ... java.md5Encode) return java.md5Encode(text);
  //     return '';
  //
  // 轻阅的 java-api.js 只有 md5Encode / sha1Encode，**没有 digestHex**：
  //   → MD5 走 md5Encode 能出结果
  //   → SHA-1 / SHA-256 全部落到 `return ''` → digest() 返回**空数组**，
  //     书源拿到的是空字符串，而且**不报任何错**。栖阅原生是有 digestHex 的。
  //
"""##,
        ##"""
  // 所以这里补上，算法支持 MD5 / SHA-1 / SHA-256（SHA-512 及其以上未实现）。
  // 未知算法返回 ''，与 packages_stub 自身的兜底行为一致 —— 不打断书源执行。

  function sha256hex(bytes) {
    var K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) | 0; }
    var len = bytes.length;
    var withPad = new Uint8Array((((len + 8) >> 6) + 1) * 64);
    withPad.set(bytes);
    withPad[len] = 0x80;
    // ⚠️ SHA-256 的长度字段是**整个 64 位大端**（高 32 位在前，且低 32 位自己也大端）。
    //    MD5 用的是 64 位小端。两种都写错的话：
    //      - 全小端 → 空输入对、非空全错（长度=0 时大小端一样）
    //      - 拆成两个 32 位各自大端 → 低 32 位变成 18 00 00 00，还是错
    var bitsHi = Math.floor(len / 0x20000000), bitsLo = (len << 3) >>> 0;
    var dp = withPad.length - 8;
    withPad[dp]     = (bitsHi >>> 24) & 0xff;
    withPad[dp + 1] = (bitsHi >>> 16) & 0xff;
    withPad[dp + 2] = (bitsHi >>> 8) & 0xff;
    withPad[dp + 3] = bitsHi & 0xff;
    withPad[dp + 4] = (bitsLo >>> 24) & 0xff;
    withPad[dp + 5] = (bitsLo >>> 16) & 0xff;
    withPad[dp + 6] = (bitsLo >>> 8) & 0xff;
    withPad[dp + 7] = bitsLo & 0xff;

    var w = new Int32Array(64), off, i, j;
    for (off = 0; off < withPad.length; off += 64) {
      for (i = 0; i < 16; i++) {
        j = off + i * 4;
        w[i] = (withPad[j] << 24) | (withPad[j + 1] << 16) | (withPad[j + 2] << 8) | withPad[j + 3];
      }
      for (i = 16; i < 64; i++) {
        var x = w[i - 15], y = w[i - 2];
        var s0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3);
        var s1 = rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (i = 0; i < 64; i++) {
        var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var ch = (e & f) ^ ((~e) & g);
        var t1 = (h + S1 + ch + K[i] + w[i]) | 0;
        var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    var out = '';
    for (i = 0; i < 8; i++) out += ('00000000' + (H[i] >>> 0).toString(16)).slice(-8);
    return out;
  }

  if (!W.java) W.java = {};
  if (typeof W.java.digestHex !== 'function') {
    W.java.digestHex = function (text, algo) {
      var s = String(text == null ? '' : text);
      var name = String(algo || 'MD5').toUpperCase().replace(/_/g, '-');
      if (name === 'MD5') return typeof W.java.md5Encode === 'function' ? W.java.md5Encode(s) : '';
      if (name === 'SHA-1' || name === 'SHA1') return typeof W.java.sha1Encode === 'function' ? W.java.sha1Encode(s) : '';
      if (name === 'SHA-256' || name === 'SHA256') return sha256hex(utf8Encode(s));
      return '';   // SHA-512 等未实现 —— 与 packages_stub 自身兜底一致，不打断书源
    };
  }

  // 调试/自检出口：让门禁能单独验证 S 盒、密钥扩展、轮函数这些内部件。
  // 定位 AES 出错时，逐层对比 FIPS-197 中间值比黑盒试快得多。
  W.__packagesNativeInternals = {
    SBOX: SBOX, INV_SBOX: INV_SBOX,
    gmul: gmul, xtime: xtime,
    expandKey: expandKey,
    aesEncryptBlock: aesEncryptBlock, aesDecryptBlock: aesDecryptBlock,
    addRoundKey: addRoundKey, subBytes: subBytes,
    shiftRows: shiftRows, invShiftRows: invShiftRows,
    mixColumns: mixColumns, invMixColumns: invMixColumns,
    b64EncodeBytes: b64EncodeBytes, b64DecodeToBytes: b64DecodeToBytes,
    sha256hex: sha256hex,
  };

})(typeof globalThis !== 'undefined' ? globalThis : this);

// 同 packages_stub.js：保证顶层完成值是 undefined（详见那里的注释）
;void 0;

"""##,
    ].joined(separator: "\n")

    /// ⭐ 两个兼容层源码（**注入顺序有讲究**：先 stub 再 native）
    public static var sources: [String] { [packagesStubSource, packagesNativeSource] }
}
