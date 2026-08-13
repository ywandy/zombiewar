# 联机服务端双运行时设计

**日期：** 2026-08-13

**状态：** 已确认

## 背景

当前 `server/` 是 Cloudflare Worker + D1 + Durable Objects 实现。线上联机协议、房间
状态机、20Hz 帧泵、断线补帧、排行榜投票和客户端接入均已投入使用。项目还需要一套
可以脱离 Cloudflare、通过普通 Docker Compose 直接部署的单机服务端。

本次不恢复或参考旧镜像中的源码。当前 `server/` 是唯一业务真相。目标不是复制一份
逐渐漂移的 `server_standalone/`，而是在同一个 npm 项目中提供 Cloudflare 与
standalone 两个入口，共享全部业务规则，只替换运行平台提供的基础设施。

## 目标

1. 保持现有 Cloudflare Worker 的部署命令、Wrangler 配置、bindings、自定义域和线上
   行为不变。
2. 在 `server/` 内新增 standalone Node 入口，可通过 Docker Compose 直接部署。
3. Cloudflare 与 standalone 共用同一份协议、房间逻辑、补帧、命令合并、排行榜投票
   和反作弊校验。
4. standalone 使用单 Node 进程承载所有活跃房间，使用 SQLite 单文件持久化身份、
   会话、房间目录和排行榜。
5. Godot 客户端不增加运行时分支，只需切换服务端 base URL。
6. 保持既有 standalone 部署契约：监听 `0.0.0.0:8787`、数据库位于
   `/data/zombiewar.db`、支持 `CORS_ORIGINS`、提供 `/api/health` 健康检查，并在
   15 秒内优雅退出。

## 非目标

- 不支持 standalone 多副本、负载均衡或跨进程房间迁移。
- 不引入 Redis、消息队列、分布式锁或外部数据库。
- 不让普通 Node 进程直接使用 Durable Objects，也不让 Worker 加载
  `better-sqlite3`。
- 不改变现有 HTTP 路径、JSON 字段、WebSocket 消息、关闭码或协议版本。
- 不修改 Godot 客户端联机业务逻辑。
- 不把正在进行的房间持久化到 SQLite；standalone 重启后，活跃对局允许失效。
- 不改变 Cloudflare 的 D1 schema、Durable Object migration tag、Worker 名称或路由。

## 已确认约束

- standalone 仅运行一个容器、一个 Node 进程。
- `server/` 是唯一 npm 项目，不创建第二套独立业务源码仓库。
- 使用两个显式入口，而不是试图让同一个运行产物仅靠环境变量获得两套平台能力。
- Cloudflare 原有脚本名继续有效；standalone 使用带 `:standalone` 后缀的新脚本。
- standalone 镜像中的源码和产物只来自当前仓库，不参考旧镜像实现。

## 总体架构

```text
Godot Client
    │
    │ 相同 HTTP / WebSocket 协议
    ▼
┌──────────────────────────────────────────────────────┐
│ server/src/core + server/src/lib                     │
│ 协议、房间状态、帧泵、补帧、规则、投票、身份规则    │
└──────────────────────┬───────────────────────────────┘
                       │ ports
          ┌────────────┴────────────┐
          ▼                         ▼
Cloudflare entry               Standalone entry
Hono / Worker                  Fastify / Node
D1                            better-sqlite3
Durable Object                MemoryRoomRegistry
WebSocketPair                 Node WebSocket
```

两个入口在构建期选择，不在核心逻辑中判断 `SERVER_RUNTIME`。环境变量只配置选定入口，
不承担平台能力探测。

## 目录结构

目标结构如下，具体文件可在实施计划中按最小改动调整：

```text
server/
├── src/
│   ├── entry/
│   │   ├── cloudflare.ts
│   │   └── standalone.ts
│   ├── core/
│   │   ├── ports.ts
│   │   ├── room.ts
│   │   └── room_factory.ts
│   ├── adapters/
│   │   ├── d1_store.ts
│   │   ├── sqlite_store.ts
│   │   ├── durable_room_host.ts
│   │   └── memory_room_host.ts
│   ├── lib/
│   │   ├── frame_history.ts
│   │   ├── leaderboard.ts
│   │   ├── protocol.ts
│   │   ├── room_code.ts
│   │   ├── room_rules.ts
│   │   └── sessions.ts
│   ├── index.ts
│   └── room_do.ts
├── migrations/
├── test/
├── Dockerfile.standalone
├── docker-compose.yml
├── .env.example
├── package.json
└── wrangler.jsonc
```

`src/index.ts` 与 `src/room_do.ts` 可以继续作为 Wrangler 看到的兼容入口；它们只转发
到新的 Cloudflare entry/adapter，避免修改 `wrangler.jsonc` 的 `main`、Durable Object
类名和 binding。

## 共享核心边界

### `core/room.ts`

承接当前 `RoomDurableObject` 中与 Cloudflare 无关的业务状态：

- 房间码、公开状态、lobby/playing/ended 状态。
- 座位、房主、准备状态、角色与地图选择。
- 开局前座位压实和最终 slot 分配。
- 服务端权威 seed 与 20Hz tick。
- pending command 合并、sticky/edge bits 清理和 wave request 聚合。
- 帧编码、历史保存、重连覆盖检查和 backfill。
- 心跳、连接超时、断线留座与重连抢回原座。
- 帧哈希不一致检测。
- 结果收集、宽限计时、交叉验证、排行榜写入和回大厅。

核心层不得导入 `DurableObjectState`、`D1Database`、`WebSocketPair`、Fastify 或
`better-sqlite3`。

### `core/ports.ts`

用窄接口表达核心真正需要的平台能力：

- `RoomConnection`：发送文本、关闭连接、稳定连接标识。
- `SessionStore`：根据 token 解析玩家身份。
- `ResultStore`：写入已验证的比赛结果。
- `RoomDirectoryStore`：发布和查询房间目录。
- `RoomClock`：当前时间、interval、timeout 及取消操作。
- `RoomLogger`：结构化 info/warn/error/diagnostic 日志。

时钟抽象用于可控测试，不改变生产环境仍以墙钟驱动 50ms 服务端帧泵的事实。

### 继续共享的 `lib/`

以下文件仍是两个运行时唯一的协议和规则来源：

- `protocol.ts`：协议版本、tick 常量、关闭码、命令解析与合并。
- `frame_history.ts`：广播字节历史与分块补帧。
- `room_rules.ts`：准备条件和内容 ID 形状校验。
- `leaderboard.ts`：多数投票、合理性上限和榜单语义。
- `sessions.ts`：设备 ID、昵称和匿名身份规则。
- `room_code.ts`：房间码生成、规范化和耗尽处理。

平台相关 SQL 调用从这些模块中移入 store adapter；纯规则函数保留原模块名称和测试。

## Cloudflare 入口

Cloudflare 对外保持现状：

- Hono HTTP 路由和响应结构不变。
- `wrangler.jsonc` 保持 Worker 名称、`main`、compatibility 配置、observability、
  custom domain、D1 binding、Durable Object binding、migration tag 和 vars 不变。
- `RoomDurableObject` 类名和导出方式不变。
- D1 继续保存 players、sessions、scores 与 rooms。
- Durable Object 继续按房间码提供单房间顺序执行与运行时隔离。
- `WebSocketPair` 由 Cloudflare adapter 包装成 `RoomConnection`。
- Durable Object storage 继续保存初始化所需的 code 和 is_public。

现有 npm 命令必须继续有效且语义不变：

```bash
npm run dev
npm run deploy
npm run db:local
npm run db:remote
npm run tail
npm run typecheck
npm test
```

本次抽取共享核心不构成修改 Cloudflare 部署方式的授权。

## Standalone 入口

### HTTP 与 WebSocket

- 使用 Fastify 监听 `HOST:PORT`。
- 使用 `@fastify/cors` 实现与 Worker 等价的 CORS 行为。
- 使用 `@fastify/websocket` 承接 `/ws/rooms/:code`。
- 提供与 Cloudflare 完全相同的根路由、`/api/health`、匿名身份、排行榜、建房、
  房间列表、房间详情和房间 WebSocket 路径。
- 错误响应继续使用 `{ error, message }` 结构。
- 客户端无需知道当前连接的是哪一种运行时。

### `MemoryRoomRegistry`

- 使用进程内 `Map<string, Room>` 按房间码保存活跃房间。
- 建房时创建并注册房间；WebSocket 与详情查询解析到同一个实例。
- 空房间停止所有 timer，并在目录 TTL 后从 registry 清除。
- 单 Node 事件循环天然序列化同步状态修改；涉及身份查询的 join 仍保留显式 join queue，
  保证抵达顺序与分配 slot 顺序一致。
- 进程退出或重启后活跃房间不恢复。

### SQLite

使用 `better-sqlite3` 打开 `DB_PATH`，默认 `/data/zombiewar.db`：

- 启动时创建父目录并自动执行幂等迁移。
- 启用 WAL、foreign keys 和 busy timeout。
- schema 与 D1 的 players、sessions、scores、rooms 语义保持一致。
- 事务用于身份 upsert + session 创建，以及整局多条成绩写入。
- sessions 继续在身份请求时机会式清理过期记录。
- rooms 表是可浏览目录，不是活跃房间状态恢复源。
- SQLite 写入错误被记录并转成 `persisted: false`，不得导致房间进程退出或客户端永远
  收不到 `end`。

`better-sqlite3` 只出现在 standalone 的依赖闭包中，Cloudflare 构建不得加载或打包它。

## 环境变量

Standalone 保持已有 Compose 契约：

```dotenv
HOST=0.0.0.0
PORT=8787
DB_PATH=/data/zombiewar.db
CORS_ORIGINS=*
```

规则：

- `HOST` 默认 `0.0.0.0`。
- `PORT` 默认 `8787`，必须是合法端口。
- `DB_PATH` 默认 `/data/zombiewar.db`。
- `CORS_ORIGINS` 为 `*` 或逗号分隔白名单。
- 现有 Worker 的 `ZW_CORS_ORIGIN`、`ZW_MAX_LEADERBOARD_LIMIT`、
  `ZW_SESSION_TTL_SECONDS` 保持不变。
- standalone 内部可以把两套命名归一到共享配置对象，但不得要求现有 Compose 改名。

## Docker 与 Compose

`server/Dockerfile.standalone` 使用多阶段构建：

1. 安装完整依赖并编译 standalone 入口。
2. 运行时镜像只包含 Node、standalone 构建产物、生产依赖和 SQLite 原生模块。
3. 以非 root 用户运行。
4. 暴露 8787，入口执行 `npm run start:standalone` 对应的生产命令。

`server/docker-compose.yml` 保持如下运行行为：

```yaml
services:
  server:
    build:
      context: .
      dockerfile: Dockerfile.standalone
    container_name: zombiewar-server
    restart: unless-stopped
    ports:
      - "0.0.0.0:8787:8787"
    environment:
      HOST: 0.0.0.0
      PORT: 8787
      DB_PATH: /data/zombiewar.db
      CORS_ORIGINS: ${CORS_ORIGINS:-*}
    volumes:
      - ./data:/data
    healthcheck:
      test:
        - CMD
        - node
        - -e
        - "fetch('http://127.0.0.1:8787/api/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    stop_grace_period: 15s
```

发布到镜像仓库时可以继续使用原有镜像地址和新 tag，但镜像名称/tag 不写死在源码或
Dockerfile 中。

## 启动与退出生命周期

### 启动

1. 解析并验证 standalone 环境变量。
2. 创建数据库目录，打开 SQLite，设置 pragmas 并运行迁移。
3. 创建 store adapters 与 `MemoryRoomRegistry`。
4. 装配 Fastify HTTP/WebSocket 路由。
5. 监听 `HOST:PORT`，健康检查开始返回成功。

如果数据库打不开、迁移失败或端口无法监听，进程启动失败并以非零状态退出，不得在
半可用状态下通过健康检查。

### 优雅退出

收到 `SIGTERM` 或 `SIGINT` 后：

1. 将服务标记为 draining，健康检查返回非成功状态并拒绝新建房/新 WebSocket。
2. 停止接受新的 HTTP 连接。
3. 向在线客户端关闭 WebSocket，使用明确的服务关闭原因。
4. 停止所有房间帧泵、心跳、结果宽限和清理 timer。
5. 等待已开始的结果写入完成；新的结果写入不再启动。
6. 关闭 SQLite 和 Fastify。
7. 在 Compose 的 15 秒宽限期内正常退出；超时才由容器运行时强制结束。

清理方法必须幂等，重复信号或连接 close/error 双重回调不得重复结算或泄漏 timer。

## 协议兼容

两个入口必须对客户端呈现相同契约：

- 相同 `PROTOCOL_VERSION`、`TICK_HZ`、position quantization 和关闭码。
- 相同 HTTP 路径、状态码、JSON 字段和分页语义。
- 相同 lobby、roster、start、frame、backfill、end、ping/pong、desync 消息。
- 相同 slot 压实、host 迁移、ready、角色/地图选择规则。
- 相同 command merge：sticky bits 取最新，edge bits 累积，events 拼接。
- 相同重连规则：按 `resume_tick` 补帧，历史不足时以 4007 拒绝，绝不部分补帧。
- 相同排行榜反作弊边界：无公开写榜端点，至少两人、席位严格多数、合理性上限和
  单人房不入榜。

因为协议没有变化，本次不主动提升 `PROTOCOL_VERSION`。若实施中发现必须改变任何
线上字段或消息语义，则停止实现、先修改设计并按项目规则同步提升两端协议版本。

## 测试策略

### 共享核心

使用可控 clock、fake stores 和 fake connections 覆盖：

- 按抵达顺序分配座位与房主。
- 准备、角色选择、地图选择和开局条件。
- 开局座位压实与 start roster。
- 20Hz 帧生成、seed、command merge、edge 清理和 wave request。
- frame history、成功补帧、历史不足拒绝和重连替换旧连接。
- 心跳超时、lobby 离座、playing 留座和 host 迁移。
- hash mismatch 广播。
- result grace、严格多数、无多数、SQLite/D1 写入失败后仍广播 end。
- 清理幂等与所有 timer 被取消。

### SQLite adapter

使用临时数据库覆盖：

- 首次迁移和重复迁移。
- 玩家 upsert、nickname 更新、session 创建与过期。
- 排行榜排序、分页、本人排名、team board 聚合。
- 比赛结果事务写入与失败回滚。
- 关闭并重新打开数据库后身份和榜单仍存在。
- WAL、foreign keys 与 busy timeout 已生效。

### Standalone 集成

- `/` 与 `/api/health`。
- 匿名身份、双榜、建房、列表和详情。
- WebSocket join/welcome/roster/start/frame/reconnect/end。
- Godot 使用的 Authorization 与 `X-Player-Token` 两种 token 位置。
- CORS `*` 与白名单。
- draining 后健康检查失败且不再接受新房间。
- `SIGTERM` 后在 15 秒内退出。

### Cloudflare 回归

- 现有 Vitest 全部通过。
- Cloudflare TypeScript 检查通过。
- `wrangler.jsonc` 与部署脚本语义不变。
- `tools/validation/validate_online_frame_sync.gd` 通过。
- `tools/validation/validate_online_reconnect_resume.gd` 通过。
- 共享核心测试同时约束 Worker adapter 与 standalone adapter 的行为一致。

### Docker Smoke Test

1. 构建 standalone 镜像。
2. 以临时 data volume 启动容器。
3. 等待 `/api/health` 成功。
4. 创建身份和房间，完成 WebSocket join。
5. 停止容器并确认正常退出。
6. 使用同一 volume 重启，确认身份和排行榜数据仍在。

## npm 脚本兼容

现有 Cloudflare 命令原样保留，新增：

```json
{
  "scripts": {
    "dev:standalone": "启动 standalone 开发入口",
    "build:standalone": "编译 standalone 生产产物",
    "start:standalone": "运行 standalone 生产产物",
    "test:standalone": "运行 standalone 与 SQLite 聚焦测试"
  }
}
```

具体工具可选择 `tsx` 开发、`tsc` 或轻量 bundler 构建；选择标准是：Cloudflare 构建不
解析 `better-sqlite3`，standalone 产物能在 Docker 中稳定加载其原生模块，并保留可读
堆栈。实施计划必须先用最小构建实验固定工具，不能把两套平台依赖打进同一 bundle。

## 失败处理与可观测性

- HTTP 未处理错误继续返回机器可读 `internal_error`，详细堆栈只写服务端日志。
- WebSocket 单条坏消息只关闭对应连接，不影响房间或进程。
- 房间 timer 回调捕获并记录异常，不能让未处理 rejection 终止 Node 进程。
- SQLite 持久化失败记录 room、match、error，结算仍广播 `persisted: false`。
- standalone 继续输出与现有 `ZWDIAG` 等价的结构化房间事件，便于比较两个运行时。
- 日志不得输出 session token、完整 Authorization header 或设备 ID。
- `/api/health` 至少返回 ok、protocol_version、tick_hz、max_players；standalone 可增加
  runtime 字段，但客户端不得依赖它，Cloudflare 响应保持原样。

## 安全边界

- standalone 与 Cloudflare 一样把匿名 device identity 明确标记为未认证。
- 无公开成绩提交端点。
- 服务器只信任经过形状校验的命令，比赛结果仍需多数交叉验证。
- SQLite 文件仅通过 volume 持久化，不通过 HTTP 暴露。
- 容器使用非 root 用户；数据库目录权限在启动时明确验证。
- CORS 不是认证；生产部署应通过 `CORS_ORIGINS` 收紧来源，但保持 `*` 作为既有默认。

## 交付标准

- `server/` 内存在 Cloudflare 与 standalone 两个明确入口。
- Cloudflare 原部署命令、Wrangler 配置和线上协议保持不变。
- standalone 能使用给定 Compose 契约在单容器中运行。
- `/data/zombiewar.db` 在容器重启后保留身份、会话和排行榜。
- 活跃房间、20Hz tick、重连补帧与结算行为由共享核心实现，不存在复制版本。
- Godot 客户端只切换 base URL 即可连接任一入口。
- 共享核心、SQLite、standalone 集成、Cloudflare 回归和 Docker smoke 验证通过。
