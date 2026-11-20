# M1 数据层进度（store-core）

> 交付时间：2026-11-19。范围内所有代码在
> `packages/legado_core/lib/src/domain/`、`lib/src/store/`、`test/store/`。

## 一、做了什么

### 1. 领域实体（22 张表 + 1 视图 + 3 个 DTO）

全部按 `app/src/main/java/io/legado/app/data/entities/*.kt` 逐个还原，字段顺序、列名、
默认值、复合主键、索引名都与 Room 一致。每个实体都有：

- `static const String tableXxx`
- `static const String createSql`（完整 `CREATE TABLE IF NOT EXISTS`）
- `factory Xxx.fromRow(Map<String, Object?>)` / `Map<String, Object?> toRow()`
- 核心实体（`Book` / `BookChapter` / `BookSource` / `BookGroup` / `SearchBook` / `ReplaceRule`）有 `copyWith`；
  可空字段用 `_unset` 哨兵，能显式置 null。

文件划分：

| 文件 | 内容 |
| --- | --- |
| `domain/book.dart` | `Book` `BookChapter` `BookGroup` `Bookmark` `ReadRecord` + `BookType` `BookSourceType` |
| `domain/book_source.dart` | `BookSource` `BookSourcePart`(视图) + 分组解析 |
| `domain/search.dart` | `SearchBook` `SearchKeyword` |
| `domain/rss.dart` | `RssSource` `RssArticle` `RssStar` `RssReadRecord` |
| `domain/settings.dart` | `ReplaceRule` `Cache` `DictRule` `HttpTTS` `RuleSub` `Server` `TxtTocRule` `Cookie` `KeyboardAssist` |
| `domain/row_utils.dart` | `asInt/asBool/asString/...`，统一 `INTEGER(0/1) <-> bool` |
| `domain/domain.dart` | 统一导出 |

**不是表**（Kotlin 里没有 `@Entity`）：`BookChapterReview`、`BookProgress`、`ReadRecordShow`，
按 DTO 实现，不参与建表。`BookSourcePart` 是 `@DatabaseView`，落地为 `CREATE VIEW`。

### 2. 数据库与迁移（`lib/src/store/`）

- `database.dart`
  - `LegadoDatabase.open(path)` / `LegadoDatabase.inMemory()`
  - `PRAGMA journal_mode=WAL`、`foreign_keys=ON`、`busy_timeout=5000`
  - **额外注册了 `LOCALIZED` 排序规则**（见踩坑 1）
  - 迁移基于 `PRAGMA user_version`，`Migration(version, up)` 按版本升序，每步独立事务
  - `runInTransaction(db, fn)`：批量写统一入口，异常 ROLLBACK 并原样抛出
- `schema.dart`：`schemaVersion = 1`，22 张表 + `book_sources_part` 视图 + 12 个索引（索引名照抄 Room 的 `index_<表>_<列>`）
- `migration.dart`：`Migration` 单版本号模型

### 3. DAO（22 个，`lib/src/store/dao/`）

`BookDao` `BookChapterDao` `BookSourceDao` `BookGroupDao` `BookmarkDao` `ReadRecordDao`
`ReplaceRuleDao` `CacheDao` `SearchBookDao` `SearchKeywordDao` `RssSourceDao` `RssArticleDao`
`RssReadRecordDao` `RssStarDao` `DictRuleDao` `HttpTTSDao` `RuleSubDao` `ServerDao`
`TxtTocRuleDao` `CookieDao` `KeyboardAssistDao`，统一 `dao.dart` 导出。

- SQL 逐条对照 Kotlin `@Query`，包括原版里 `and/or` 没加括号的语义都保留了（`BookmarkDao.search` 有注释）。
- 所有多行写入在单事务内：`Book.insertAll`、`BookChapter.insertAll`、`BookSource.insertAll`、
  `RssSource.insertAll`、`RssArticle.appendAll`、`BookSource.deleteAllByKey`。
- Kotlin 的 `Flow<...>` 换成同步 `List<...>`：纯 Dart 内核没有响应式流，服务层/UI 需要订阅时再包一层。

### 4. 装配

- `lib/src/store/store.dart` 新增 `StoreModule implements CoreModule`
  - `migrate`：确保 homeDir 存在，打开 `${homeDir}/legado.db`，暴露 `StoreDaos`
  - `register`：注册 `System.Database` → `{version, path, tables: {表名: 行数}}`
  - `close`：关库并清空静态引用
  - `StoreModule.instance` / `StoreModule.daos` 给 M3 服务层取 DAO
- `lib/src/modules/modules.dart`：只加了 1 行 import + 1 个实例（经主控授权）

### 5. 测试（`test/store/`，87 个用例全绿）

| 文件 | 覆盖 |
| --- | --- |
| `database_test.dart` (9) | 版本号、表/视图齐全、无多余表、重复迁移幂等、磁盘重开、乱序迁移、失败回滚、外键级联、行数统计 |
| `entity_roundtrip_test.dart` (25) | 21 个实体 `toRow → INSERT → SELECT → fromRow` 整行相等（含 null），`copyWith` 清空可空字段 |
| `book_dao_test.dart` (12) | CRUD、REPLACE、位域分组、批量查名、搜索、`insertAll`、进度/分组更新、临时书清理、在用书源 |
| `book_chapter_dao_test.dart` (9) | 批量插入顺序、按 index/title 取、区间、更新、字数、按书删除 |
| `book_source_dao_test.dart` (10) | 视图现算 `hasLoginUrl/hasExploreUrl`、`patchRaw` JSON 合并、`fromJson/toJson`、分组精确/模糊、启停排序、级联删搜索结果、事务删除 |
| `misc_dao_test.dart` (15) | Cache 过期/变量清理、替换规则作用域、阅读时长聚合、RSS 已读 join/append/clearOld、Cookie 两类、关键词排序、搜索缓存、内置项清理 |
| `transaction_test.dart` (4) | 异常回滚、成功提交、章节批量插入外键失败不留半批 |
| `store_module_test.dart` (4) | `System.Database`、DAO 与行数同步、关库重开、未 migrate 报错 |

运行方式：

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
cd C:\Users\bingx\work\code\legado\legado-flutter
dart test packages/legado_core/test/store
```

## 二、没做什么 / 有意为之

1. **没有 `raw` 列**。原版 `BookSource` 不存在「raw 全量 JSON + 冗余索引列」的结构，
   它的规则字段是 6 个 TEXT 列（`ruleExplore/ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleReview`），
   由 Room TypeConverter 存 JSON。为符合真源，Dart 实体保留 JSON 字符串列，并提供
   `BookSource.fromJson` / `toJson` / `patchRaw(Map)`：`patchRaw` 把「书源 JSON 的改动」合并回实体，
   规则对象重新序列化、标量按 DB 类型收紧；`book_sources_part` 视图由 SQLite 现算，不存在漏刷新冗余列的问题。
   如果主控确实要「新增 raw 列」的存储结构，需要一次 schema 决策，我没有擅自偏离 Room schema。
2. **规则对象未建模**。`SearchRule/ExploreRule/TocRule/...` 属于 M2 `rules/`，数据层只存 JSON 字符串。
   等规则层给出类型后，可加 `bookSource.ruleSearchObj` 之类只读访问器，不需要改表。
3. **没有移植复杂的 `BookGroupDao.show`**（一段带 `with const as (...) select ...` 的可见分组查询）。
   它依赖 UI 语义（哪些分组该显示），建议进 service/UI 层。`flowSelect` 已由 `selectable` 覆盖。
4. **`BookSourceDao` 的一些纯展示查询**（`flowExplore` 各种过滤）只保留了核心的
   `all/allEnabled/getByGroup/getEnabledByGroup/search/groupSearch/getEnabledByType`，
   其余可在服务层用 `all` 过滤，或后续按需补 SQL。
5. **未做「从 Android 旧库导入」**。当前 `schemaVersion=1` 是全新库；
   Android 侧 Room 已到 65+，直接 `ATTACH` 需要列对齐校验。**Android legado.db 直读：未做，留 M8 兼容性回归。**
6. **没有做 reactive 变更通知**。`sqlite3` 3.5.2 有 `db.updates` 流，若 UI 需要实时刷新，
   建议在 M3 服务层统一封装，而不是让每个 DAO 各写一套。

## 三、踩了什么坑

1. **`collate localized` 在纯 Dart 里不存在**。
   `BookmarkDao`、`ReadRecordDao` 的 SQL 抄了 Kotlin 的 `order by bookName collate localized`，
   而 `localized` 是 Android Room 注册的 ICU 排序规则。不注册会在**执行查询时**报
   `no such collation sequence: localized`（建表阶段完全正常，很容易漏测）。
   `LegadoDatabase` 打开时用 `createCollation` 注册了同名规则；目前是 code-unit 比较，
   **拼音排序需上层实现**（服务层/UI 做拼音转换后再排）。
2. **`sqlite3` 的 `Statement.dispose()` / `Database.dispose()` 已废弃**，改用 `close()`，否则 `dart analyze` 出 info。
3. **`INSERT OR REPLACE` 会先 DELETE**，`chapters`/`searchBooks` 上的外键是 `ON DELETE CASCADE`，
   所以「REPLACE 一条书源」会顺带删掉它的搜索结果。测试里验证过，业务层做「更新书源」时应优先 `update` 而不是 `insert`。
4. **`getEnabledByType` 的 `bookUrlPattern != 'NONE'` 会排除 NULL**：SQL 三值逻辑，`NULL != 'NONE'` 是 NULL。
   Kotlin 原 SQL 如此，我保持一致；书源没有 `bookUrlPattern` 时不会被「按类型取源」命中。
5. **测试取行不能用 `.first`**：用 `INSERT` 后再 `select * limit 1` 会取到别的行，
   表现为「某个字段莫名不对」。改用 `last_insert_rowid()` 定位（`test/store/store_test_support.dart`）。
6. **`books(name, author)` 是唯一索引**：造测试数据时同名同作者会直接约束失败；
   批量插入的测试数据必须保证 `(name, author)` 唯一。

## 四、留给谁

| 接手方 | 需要知道的事 |
| --- | --- |
| **M2 rules** | 实体在 `lib/src/domain/domain.dart`；书源规则是 6 个 JSON 字符串列，自行 decode 成规则对象后**不要**直接改回列，统一走 `BookSource.patchRaw` + `BookSourceDao.update`。`Book.readConfig` 同理是 JSON 字符串。 |
| **M3 service** | 服务实现用**构造注入**：`XxxService(StoreDaos daos)`。`StoreModule.instance!.daos` 只允许出现在 `modules/` 装配层，不许写进 service 实现里（主控决定）。多行写请用 `runInTransaction`（DAO 批量方法已内置，跨 DAO 的复合写需要自己包）。 |
| **M3/UI** | 排序/中文拼音、分组展示顺序、`BookGroupDao.show` 的可见性规则需要在上层实现。 |
| **主控** | 见下面「需要主控决定的接口问题」。 |

## 五、需要主控决定的问题

1. **`BookSource` 是否真的要加 `raw` 列**？我按 Kotlin 真源实现，没有 raw。
   若要求 raw 双写，请明确：raw 是额外列（schema 变更）还是仅导出 JSON（当前 `toJson` 已满足）。
2. **旧库导入策略**：Flutter 版 schemaVersion 从 1 起，Android 是 65+。
   是否要兼容直接打开 Android 的 `legado.db`？若要，需要列级对齐表 + 一次性导入迁移。
3. **`System.Database` 方法名/返回结构**是否作为正式契约固化？当前返回
   `{version:int, path:string, tables:{表名:行数}}`，`test/store/store_module_test.dart` 守着它。
4. **`StoreModule.instance` 静态访问**是否可接受？服务层没有依赖注入容器，
   静态引用最简单；若主控要引入 `ServiceLocator`，我可以改成构造注入。
5. **`dart analyze packages/legado_core` 目前仍有 64 个 issue，全部在 `lib/src/js/`**
   （`ast.dart` 的 super 参数、`parser.dart` 的 `use_of_void_result` 等），不是数据层引入的。
   数据层三个目录单独 analyze 为 **0 issue**。另外 `test/core_test.dart` import 了
   `package:legado_core/legado_core.dart`，会被 JS 编译错误连带失败；
   我的测试刻意只 import `src/core.dart` 以下的路径，避免被别的域阻塞。

## 六、追加交付：书源导入导出（2026-11-19 第二轮）

主控确认：不加 raw 列、不做旧库导入、`System.Database` 契约不变、service 用构造注入。

### A. 真实书源回归固化

`test/store/book_source_dao_test.dart` 新增「23 个顶层字段 fromJson → toJson 零丢失」：
内联超星结构样本（23 个顶层 key，`loginUi` 等规则块带 2–5 个子字段），断言
`toJson().keys` 覆盖全部输入 key，并落库再读一遍验证 JSON 列层级没丢。
这条测试的作用是拦住「以后实体加字段但忘了改 `toJson`」。

### B. `lib/src/service/source/`

> 目录本身越过了一期「不许新建 `lib/src/service/`」的约定，系主控明确指派。

**`source_io.dart` — `SourceIoService(StoreDaos)`**

- `Future<ImportResult> importText(String text, {bool overwrite = false})`
  - 4 种输入：单对象 / 数组 / `{"sources":[...]}` / 逐行 URL（URL 计入 `skipped`）
  - 宽松 JSON：BOM、尾部逗号、`//` 行注释；逐字符扫描，URL 字符串里的 `//` 不会被吞
  - `overwrite=false`：已存在 → `skipped`；`true`：走 `update`
  - **绝不用 `INSERT OR REPLACE`**：REPLACE 先 DELETE，`searchBooks` 外键 CASCADE 会级联删搜索结果
  - 整批一个事务；单条失败只记 `errors`，不中断整批
  - 返回 `ImportResult{added, updated, skipped, errors}`
- `Future<String> exportJson({String? group})`：JSON 数组，按 `customOrder` 升序

**`source_group.dart` — `SourceGroupService(StoreDaos)`**

- `List<String> listGroups()`：拆分 `,` / `;` / `，` / `；`，去空格去重排序
- `Future<int> rename(String from, String to)`：只替换命中的分组项，其余原样保留；`to` 空白等价删除
- `Future<int> remove(String group)`：从多值分组串里摘掉一项
- 两者都在单事务内、用 `bookSourceDao.upGroup`（只写一列，避免覆盖其它字段）

**测试**：`test/service/source_io_test.dart` 21 例；全量 `dart test test/store test/service`
共 **119 例全绿**（109 + 10 个 SettingsDao 用例）；数据层 + service 目录 `dart analyze` **0 issue**。

### 需要主控注册的方法名（建议）

| 方法名 | 参数 | 返回 |
| --- | --- | --- |
| `Source.Import` | `text String`, `overwrite bool` | `ImportResult.toJson()` |
| `Source.Export` | `group String?` | JSON 字符串 |
| `Source.ListGroups` | — | `List<String>` |
| `Source.RenameGroup` | `from String`, `to String` | `int` 影响条数 |
| `Source.RemoveGroup` | `group String` | `int` 影响条数 |

service 构造需要 `StoreDaos`，装配层可写
`final sourceIo = SourceIoService(StoreModule.instance!.daos);`（仅限 modules 层）。

## 七、追加：`app_settings` 表 + `SettingsDao`（2026-11-19 第三轮）

Kotlin 用 SharedPreferences、Go 版用 `app_settings` 表；Flutter 侧要让
`Settings.Values / Settings.Update / Settings.Reset` 有落点，补一张表。

- `domain/app_setting.dart`：`AppSetting.tableAppSettings` + `createSql`
  （`key TEXT NOT NULL, value TEXT, PRIMARY KEY(key)`），已加入
  `schema.createTableSqls` 与 `dataTableNames`，`schemaVersion` 仍为 **1**（尚未发布，无需迁移链）。
- `store/dao/settings_dao.dart`：`SettingsDao`
  - `getAll()`：只返回 value 非 null 的行
  - `get(key)` / `count()`
  - `put(key, value)`：`value == null` 等价删除
  - `putAll(patch)`：单事务，逐键 upsert / 删除
  - `removeAll(keys)`：单事务；**空列表 = 清空全表**
  - 值一律字符串，数字/布尔由 service 层转换
- `StoreDaos.settings` 已挂上，装配层可直接构造 Settings 服务。
- 测试 `test/store/settings_dao_test.dart` 10 例：CRUD、覆盖、null 删除、
  `putAll` 用临时 TRIGGER `RAISE(ABORT)` 验证中途失败整体回滚、空列表清空、
  中文 + emoji 往返、`getAll` 跳过脏 null 行。

### 顺带确认的字段口径（contract-docs 反馈）

- `BookType` 8 个位**已齐**（text/updateError/audio/image/webFile/local/archive/notShelf），
  `allBookType = 232`、`allBookTypeLocal = 488`，用位与判断。
- `BookSourceType` 是单选（0/1/2/3），与 `Book.type` 位域是两套常量，未合并。
- `enabledCookieJar` 的实体默认值（true）与建表 DEFAULT（0）按 Kotlin 原样保留，
  已在 `BookSource` 字段注释说明；DAO 始终显式写该列，日常路径无差异。
