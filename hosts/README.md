# hosts —— 三种驱动方式

> core 是纯 Go 业务库，宿主只负责 I/O。同一套方法注册表在三个宿主里自动可用，
> 新增模块不需要改这里任何一行（见 `docs/ARCHITECTURE-V2.md` §4、§6）。

## CLI（headless 一等公民）

```bash
cd hosts

go run ./cli info                       # 运行时信息 + 数据目录
go run ./cli methods                    # 全部方法（128 个）
go run ./cli methods Reader             # 按域过滤
go run ./cli schema -o ../methods.json  # 导出契约（Dart 侧据此校验参数）
go run ./cli call Shelf.ListGroups
go run ./cli call Shelf.ListBooks '[1]'
go run ./cli call Reader.GetContent '[3, 12]'
go run ./cli serve -port 8580           # loopback HTTP：/rpc /events /schema
```

参数是**位置参数数组**（Go 反射拿不到参数名）。`System.Methods` 会返回每个方法的
`arity`、`paramTypes`、`resultTypes`，可用来生成调用代码。

数据目录默认是用户配置目录下的 `legado`，可用 `LEGADO_HOME` 覆盖：

```bash
LEGADO_HOME=/tmp/legado-dev go run ./cli call Shelf.ListGroups
```

## FFI（c-shared）

需要 C 工具链（Windows 上是 mingw-w64）。本机 `CGO_ENABLED=0` 且无 gcc 时，
`ffi/main_stub.go` 会顶上，`go build ./...` 仍然通过。

```bash
go build -buildmode=c-shared -o ../dist/legado.dll ./ffi
```

导出：`LegadoInit(root)` / `LegadoCall(reqJSON)` / `LegadoFree(p)` / `LegadoClose()`。
协议与 `/rpc` 相同，返回字符串由库分配，调用方必须 `LegadoFree`。

> 当前 Flutter 端默认走 HTTP：启动时探 `127.0.0.1:8580`，失败则自动拉起
> `legado-core serve -port 0` 并解析 stdout 的 `listening http://...`。
> 装好 mingw 后可切 FFI，Dart 侧只需要换 `LegadoClient` 的传输实现。

## HTTP 数据面

| 路由 | 用途 |
|---|---|
| `POST /rpc` | 控制面（与 CLI `call` 等价） |
| `GET /healthz` | 存活探测（Flutter 启动时用） |
| `GET /schema`、`GET /methods` | 契约导出 |
| `GET /events` | SSE，推 `kernel.TraceEvent` |

后续由 G10 补齐 `/content`、`/img`、`/stream`（正文、封面、音频流，支持 Range/206）。

## 命名注意

core 可执行文件必须叫 **`legado-core`**，不能与应用同名 `legado.exe`：
两者同名时构建会互相覆盖（已踩过一次，`scripts/build.ps1` 已固化这个约定）。
