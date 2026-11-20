# 进度 — JS 解释器（js-runtime）

> 纯 Dart 的书源脚本子集解释器。零 native、零 Flutter，CLI 与 App 共用同一份语义。
> 目录：`packages/legado_core/lib/src/js/`、`packages/legado_core/test/js/`。
> 接口 `lib/src/js/js_engine.dart` **未改动**。

## 一、交付物

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `token.dart` | 507 | 手写 lexer：数字/字符串/模板字符串/正则字面量、ASI 所需的换行信息 |
| `ast.dart` | 387 | 语法树节点，全部带 1 起始行列号 |
| `parser.dart` | 956 | 递归下降 + 优先级爬升；不支持语法给出明确中文错误 |
| `scope.dart` | 75 | 作用域链，`var` 提升到函数作用域，`let/const` 块级 |
| `values.dart` | 362 | 类型转换（ToNumber/ToString/ToBoolean/ToPrimitive/宽松相等）、`JsHostObject`、`JsRegExp`、`JsDate`、`JsArray` |
| `interpreter.dart` | 1403 | 求值、属性读写、调用/构造、控制流信号、`this`、闭包、递归上限 |
| `builtins.dart` | 1344 | String/Array/Object/JSON/Math/RegExp/Number/Date/console/编码函数 |
| `java_host.dart` | 282 | `java` 对象工厂，纯计算能力自实现，网络/规则能力回调注入 |
| `dart_js_engine.dart` | 94 | 对外 `DartJsEngine`：AST 缓存、`precompile`、错误补位置、结果归一化 |
| `js_exception.dart` | 103 | `JsException`，`toString()` 输出「第 N 行: 源码 + ^」 |

测试 `test/js/`：**240 个用例全绿**，覆盖运算符、转换、字符串、数组、正则、闭包、
控制流、作用域、内建、bindings/java、错误定位、真实书源脚本、性能下限。

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
dart test packages/legado_core/test/js
dart analyze packages/legado_core/lib/src/js packages/legado_core/test/js   # No issues
```

## 二、支持的语法（明确清单）

**字面量**：十进制/十六进制/二进制/八进制数字、`.5`、科学计数；单双引号字符串
（`\n \t \r \b \f \v \0 \xNN \uNNNN \u{...}` 与续行）；模板字符串（含 `${}` 嵌套、
嵌套模板）；`true/false/null/undefined`；数组（空位、展开）；对象（简写、计算方法名、
方法简写、展开）；正则字面量 `/re/flags`。

**声明**：`var/let/const`、多声明、逗号分隔；函数声明提升。

**表达式**：`+ - * / % **`、比较、`==/===/!=/!==`、`&&/||/!`（短路且返回原值）、
`??`、三元、逗号、`?.`/`?.[]`/`?.()`、`typeof/instanceof/in/delete/void`、位运算、
`=` 与 `+= -= *= /= %= **= <<= >>= >>>= &= |= ^=`、前后缀 `++/--`、`new`、展开实参。

**语句**：`if/else`、`for`（三段式、多变量）、`for...of`、`for...in`、`while`、
`do...while`、`switch/case/default`（含贯穿）、`try/catch/finally`、`throw`、
`break/continue`（含标签）、块、空语句、标签语句、自动分号插入。

**函数**：声明/表达式/箭头（单参免括号、表达式体、块体）、默认参数、剩余参数、
`arguments`、闭包、`this`、`call/apply/bind`、IIFE、递归（深度上限 220）。

**明确不支持（解析期给中文错误，不会静默跑错）**：
`class/extends/super`、生成器 `function*`、解构声明/参数/赋值、`import/export`、
`yield`、标签模板、getter/setter 字面量、`with`、`Symbol`、`Map/Set` 构造器。
`async/await` 只做了语法透传（`await x` 等价 `x`），因为宿主桥接是同步的。

## 三、内建 API 覆盖

- **String**：`length charAt charCodeAt codePointAt at indexOf lastIndexOf includes
  startsWith endsWith slice substring substr split replace replaceAll match matchAll
  search toLowerCase toUpperCase trim trimStart trimEnd padStart padEnd repeat concat
  localeCompare normalize toString valueOf`
  - `replace/replaceAll` 支持 `$$ $& $\` $' $1..$99 $<name>` 与函数替换（match、各组、offset、原串）。
  - `split` 支持正则分隔并保留捕获组。
- **Array**：`length push pop shift unshift slice splice concat join indexOf lastIndexOf
  includes reverse sort map filter forEach reduce reduceRight find findIndex some every
  flat flatMap fill at keys values entries toString valueOf`
  - `sort` 用归并排序，比较函数返回非全序也不会抛 Dart 异常。
- **Object**：`keys values entries assign fromEntries freeze`
- **JSON**：`parse stringify`（跳过函数；因值模型原因 `undefined` 输出 `null`）
- **Math**：`floor ceil round abs trunc sign sqrt cbrt pow log log2 log10 exp sin cos tan
  asin acos atan atan2 min max random hypot` + `PI E LN2 LN10 SQRT2`
- **RegExp**：`test exec source flags global ignoreCase multiline lastIndex toString`，
  `g/y` 下维护 `lastIndex`，`new RegExp(pat, flags)` 与函数式调用。
- **Number**：`Number(x) parseInt parseFloat isNaN isFinite isInteger`、
  `MAX_SAFE_INTEGER MIN_SAFE_INTEGER EPSILON`、`toFixed toPrecision toString(radix)`
- **Date**：`Date.now/parse`、`new Date()` / `new Date(ms)` / `new Date(str)`、
  `getFullYear getMonth getDate getDay getHours getMinutes getSeconds getMilliseconds
  getUTC* getTime toISOString toString`
- **全局**：`parseInt parseFloat isNaN isFinite encodeURIComponent decodeURIComponent
  encodeURI decodeURI escape unescape btoa atob console.* print String Boolean Array
  Object Error/TypeError`

## 四、宿主桥接（rules 层请看这里）

`bindings` 里可以直接放：

1. Dart 原生值：`String/num/bool/List/Map`（Map 就是 JS 对象，脚本可写回）；
2. Dart 函数：`Object? Function(List<Object?>)`（也兼容 `Function.apply` 的任意签名）；
3. Dart 对象：用 `JsHostObject`（`lib/src/js/values.dart`），
   或一个 `Map<String, Object?>` 里混放值与方法。

```dart
import 'package:legado_core/src/js/java_host.dart';
import 'package:legado_core/src/js/values.dart';

final java = createJavaObject(
  ajax: (url) => analyzeUrl.getStrResponse().body,          // 必接
  get: (url, headers) => ...,                                // java.get(url, headers)
  post: (url, body, headers) => ...,                         // java.post
  connect: (url, body, headers) => JsHostObject(methods: {   // 需要 .body()/.statusCode
    'body': (a) => responseBody,
    'statusCode': (a) => 200,
  }),
  getString: (rule) => analyzeRule.getString(rule),          // java.getString(rule)
  getElements: (rule) => analyzeRule.getElements(rule),
  getList: (rule) => analyzeRule.getList(rule),
  onLog: logger.info,
  toast: (m) => ...,
  androidId: deviceId,
);
engine.eval(script, bindings: {
  'java': java,
  'result': content,
  'baseUrl': baseUrl,
  'book': bookMap,           // 建议直接传 Map，脚本里 book.name 即 Map['name']
  'source': sourceMap,
  'chapter': chapterMap,
  'cookie': cookieMap,       // 可用 JsHostObject 提供 getCookie/putCookie 等
});
```

`java` 已内置（与 Kotlin `JsExtensions` 对齐）：`ajax get post connect getString
getElements getList base64Encode base64Decode base64DecodeToByteArray md5Encode
md5Encode16 hexEncodeToString hexDecodeToString hexDecodeToByteArray strToBytes
bytesToStr timeFormat timeFormatUTC encodeURI htmlFormat log toast longToast
put get getVariable putVariable androidId`。
`md5Encode16` 与 Kotlin 一致取 `substring(8, 24)`。

没有注入回调时调用 `java.ajax/getString` 会抛出带说明的 `JsException`
（「未接入网络层/需要规则层注入」），不会静默返回 null。

**线程/异步**：解释器内部是**异步求值**的。宿主函数（`java.ajax` 这类要发网络请求的）
可以返回 `Future`，引擎会在调用点 `await` 掉，脚本侧拿到的仍是最终结果：

```dart
final java = createJavaObject(
  ajax: (url) async {
    final resp = await net.get(Uri.parse(url));   // 返回 Future，完全合法
    return resp.text();
  },
);
// 脚本里拿到的是响应文本，不是 Future 对象
final html = await engine.eval('java.ajax("/x")', bindings: {'java': java});
```

`JsCallable.callAsync` / `constructAsync`（`values.dart`）是统一的解包入口；
`interpreter.dart` 里 `_eval` / `_exec` / `callFunction` 等全部返回 `Future`。
数组/字符串的回调型内建（`map` `filter` `sort` `replace` …）也走同一条路，
回调可以是异步宿主函数。

代价：每次求值多一层 Future 开销（实测相对同步版约慢 2~3 倍，仍在毫秒级）。
收益：书源里 `java.ajax` 这种「脚本内发请求」才真正可用——这是原版 Legado
目录/正文规则的常见写法（例：漫画客的 `ruleToc` 要 POST `/morechapter` 取全量章节）。

宿主函数抛出的普通 Dart 异常会被转成 `JsException`，因此能被脚本里的
`try { ... } catch (e) { ... }` 抓住（对齐原版 Rhino 的行为）；
`StackOverflowError` / `OutOfMemoryError` 保持原样上抛。

## 五、性能（Windows 11 / debug 模式下 `dart run` 实测）

| 场景 | 耗时 |
| --- | --- |
| 100 行脚本（60 条累加 + 30 次 push + 链式高阶函数），单次 | **0.28 ms** |
| 典型章节清洗脚本（200 行输入，正则 + 循环 + JSON），单次 | **1.87 ms** |
| 语法解析（无缓存），单次 | **0.46 ms** |

结论：一次书源详情页跑几十个脚本，解析缓存后总开销在几毫秒量级，不是瓶颈。
`DartJsEngine` 内部以脚本原文为 key 缓存 AST（无上限；书源脚本数量有限）。
注意点：每次 `eval` 会新建全局作用域与内建表，脚本之间不串变量；这也是「列表页
重复执行不污染」的保证。

## 六、踩过的坑

1. **`undefined` 与 `null` 合并**（契约要求）。因此 `Number(undefined) === 1?` 不成立，
   `undefined + 1 === 1`、`JSON.stringify({u: undefined})` 输出 `null`。与标准 JS 有差异，
   但书源脚本几乎只用 `typeof x === 'undefined'` 和 `x == null`，实测无影响。
2. **`}` 之后的正则判定**：lexer 把 `}` 当作「不能结束表达式」，宁可把 `}` 后的 `/` 当正则。
   书源里对象字面量后直接除法的写法未见过；`if (x) /re/.test()` 这种写法同样未见过。
3. **正则 vs 除法**：靠前一个 token 判断，`a = 1/2` 与 `a = /re/.test(s)` 都有回归用例。
4. **`for (let i…)` 每轮独立绑定**：必须在 body 结束后复制一份新作用域再执行 update，
   否则闭包会全部拿到 3。已在 `_execFor` 里单独处理。
5. **`java.get` 双语义**：Kotlin 靠重载，JS 侧只能按参数个数区分——
   1 个参数是读变量，≥2 个参数是网络请求。
6. **`md5Encode16`** 不是「前 16 位」，是 `substring(8, 24)`，已按 Kotlin 源码对齐。
7. **模板字符串 lexer**：`${}` 内部要单独切 token，扫描配对花括号时必须跳过字符串、
   嵌套模板与转义，否则 `}</div>` 之类会把表达式提前截断。
8. **函数替换 `replace`**：`$1` 与「函数第一个参数是整段匹配」容易混；函数参数顺序是
   `(match, p1..pn, offset, 原串)`，已按规范实现并有测试。
9. **`in` 在 for 头里**：`for (var k in obj)` 与二元 `in` 冲突，
   解析 for 头时需要临时关闭 `in` 运算符。
10. **`this` 与箭头函数**：箭头函数在创建时捕获外层 `this`，普通函数调用时
    `this` 为 undefined（非严格模式本应是全局对象；书源不使用，选 undefined 更安全）。
11. **宿主函数返回 Future**：早期版本解释器是纯同步的，`java.ajax` 返回的
    `Future` 被当成普通对象塞进变量，脚本里 `JSON.parse(java.ajax(url))` 直接炸。
    已把整个求值链改成异步（`_eval`/`_exec`/`callFunction` 返回 `Future`），
    在 `callFunction` 里统一解包。注意：改完之后 `Scope`/`_thisValue` 这类
    解释器状态会跨越 `await` 保持不变，因此**宿主回调不能重入同一个解释器实例**
    （现在 `DartJsEngine.eval` 每次新建 `Interpreter`，天然满足）。

## 七、已知缺陷 / 后续可做

1. **TDZ 未实现**：`console.log(x); let x = 1` 得到 null 而非 ReferenceError。
2. **对象原型/继承未实现**：没有 `Object.create`、`prototype`、`getter/setter`。
   书源里出现 `org.jsoup.Jsoup` 这类写法依赖宿主注入 `org`，解释器不负责。
3. **`Map/Set/Symbol/Promise` 未实现**；遇到会报「未定义」。
4. **`undefined` 与 `null` 不可区分**（见坑 1），`arguments` 是带 `length` 的 Map，
   不是真正的数组（`arguments.map` 不可用）。
5. **数值边界**：大整数（>2^53）与 `-0` 的字符串化未完全对齐 ECMAScript。
6. **`Date` 时区**：`getFullYear` 等用本机时区，`toISOString` 用 UTC；
   未实现 `setFullYear` 等 setter。
7. **性能**：AST 缓存无容量上限，长期运行的服务端进程若动态生成脚本需自行控制；
   递归深度上限 220，超过会报错而非栈溢出。
8. **不支持解构**：`var [a, b] = ...` 会抛语法错误（契约允许后置）。书源里确实存在，
   如果后续遇到真实书源不兼容，优先补这一项。

## 八、真实书源验证

从仓库里 `sources/*.json` 与 `app/src/main/assets/defaultData/bookSources.json`
抽出全部 19 段 `<js>` / `@js:` 脚本：**19/19 通过语法解析**。
其中 3 段有代表性脚本（漫画章节解析、图片列表清洗、登录脚本）已做成
`test/js/real_source_test.dart` 的端到端用例，覆盖可选链下标、全局正则、
宿主对象再返回宿主对象、for 循环与 JSON 往返。

**联网实测（2026-11，5 个真实书源）**：

| 书源 | 搜索 | 目录 | 正文 |
| --- | --- | --- | --- |
| 漫画客 `yumanhua.com` | 8 条 | **681 章**（目录页只有 20 章，另有 661 章要 POST `/morechapter` 取） | 36 张图片直链 |
| 神奇漫画 `shenqimanhua.net` | 1 条 | 6 章 | 134 张图片直链 |
| 爱丽丝书屋 / t66y | — | 境内直连不通，需代理 | — |
| VISTA看天下 | 纯发现源，无搜索地址 | 3 个分类 | — |

漫画客这一例是 async 化的直接验收点：目录规则里的
`java.ajax(host + "/morechapter,{\"method\":\"POST\",\"body\":\"id=\" + id + \"}")`
在 async 化之前拿不到数据（降级成页面上的 20 章），之后拿到全量 681 章。

复现命令：

```powershell
dart run legado_cli:probe_full
LEGADO_E2E=1 flutter test test/e2e/
```

## 九、支持率自评

- 按「书源实际出现的写法」衡量：**约 95%**。
  常见的取值、清洗、拼接、正则、循环、JSON、java.* 全部覆盖；
  缺口集中在解构、`org.jsoup` 这类需要宿主注入的语法、以及少数现代内建对象。
- 按「完整 ECMAScript」衡量：约 60%——但这不是目标。
- 已知会失败的写法：`class`、解构、标签模板、`Map/Set`、生成器。
  这些都在解析期给出明确中文错误，不会静默算错。
