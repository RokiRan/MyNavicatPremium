# 开发路线图（对标 duious/MyNavicat 分析）

> 基准分析日期：2026-07-24
> 对标仓库：[duious/MyNavicat](https://github.com/duious/MyNavicat)（Vue3 + Electron 10，2021 年停更）
> 完整功能清单（源码级）：`/tmp/bench-MyNavicat/FEATURE_INVENTORY.md`

## 对标结论

该项目**完成度低于本项目**：数据编辑、导入导出、转储、SSH 隧道均为菜单桩或空壳函数
（`edit.addTr`/`edit.subTr` 空实现、`ssh2 on('ready')` 空回调）；密码明文存 electron-store。
我们已全面反超：真实数据编辑（PK 定位）、CSV/JSON/SQL 导出、拖拽跨库迁移、二进制安全往返、
Keychain 密码、28 个真库集成测试。

真正落后只有三处，即本路线图的目标：

1. **查询编辑器体验**：它有 Monaco 语法高亮、选中执行、EXPLAIN tab、耗时统计
2. **连接能力**：它有 SSL/TLS 证书配置（SSH 是空壳，我们做真的）
3. **对象覆盖**：它的库下分 表/视图/函数/存储过程/事件 六类节点，我们只有表/视图

## 技术风险（先于计划锁定）

### 风险 1：SHOW PROFILE 路线不可照搬 ⚠️

对标项目的"执行剖析"基于 `SET PROFILING=1` + `SHOW PROFILE` / `INFORMATION_SCHEMA.PROFILING`。
该特性 **MySQL 5.7 已 deprecated，8.0 已彻底移除**（我们要求支持 5.7 + 8.x）。

**替代路线**：
- `EXPLAIN FORMAT=JSON` → 解析渲染（type / key / rows / filtered / cost）
- MySQL 8 追加 `EXPLAIN ANALYZE`（实际执行耗时，5.7 优雅降级为普通 EXPLAIN）
- 需要更细粒度时查 `performance_schema.events_statements_history` / `sys.statement_analysis`

### 风险 2：Monaco 不搬进 SwiftUI

对标是 Electron，textarea 套 Monaco 零成本。原生没有免费午餐，两条路：

| 方案 | 成本 | 风险 |
| --- | --- | --- |
| **TextKit2 / CodeEditor + 自研 lexer**（首选） | 中：NSTextView 包装 + 关键字高亮 | 低：MySQL 方言小（关键字 ~200 条），`SQLUtils` 已有引号/注释感知切分逻辑可复用 |
| Monaco via WKWebView（备选） | 高：web shell + JS 桥 + 打包体积 | 高：输入法/焦点/字体渲染问题多，背离原生定位 |

**决策**：P1 走 TextKit2 + 自研轻量 lexer（关键字/字符串/注释/数字四类 token 足够）；
仅当自研体验明显不达标时，才评估 Monaco-WKWebView。

## 分阶段计划

### P1 — 查询体验（对标唯一领先点）

| # | 项 | 要点 |
| --- | --- | --- |
| 1 ✅ | SQL 语法高亮 | **已完成 2026-07-24**：`SQL.scan` 公共 scanner（SQLUtils.swift，code/string/quotedIdentifier/comment 四类片段，`splitStatements` 重写在其上）；`SQLLexer`（关键字 MySQL 8 reserved words/数字/指数/hex）；`SQLEditor`（TextKit2 手工栈，QueryView 替换 TextEditor，快捷键 ⌘Return→⌘R）。14 单测 + 42/42 全绿 + UI 冒烟（五色 token/⌘R/结果网格）。坑：NSTextContainer() 默认 0x0 必须显式 size；ad-hoc 重打包必弹 Keychain，冒烟用 smoke 用户绕过（见下） |
| 2 | 选中执行 | 有选区跑选区，无选区跑全文；与现有多语句切分兼容 |
| 3 | 查询历史 + 收藏查询 | 路线图既有项；JSON 落盘，按连接过滤，收藏可命名 |
| 4 | 执行耗时统计 | 每条语句结果栏显示 ms 级耗时 |

### P2 — 连接能力

| # | 项 | 要点 |
| --- | --- | --- |
| 5 | SSH 隧道 | 本项目原 roadmap 项（与对标无关，它只有空壳）。swift-nio-ssh 本地转发，会话经隧道建连；表单加 SSH 页（host/port/user/私钥/密码） |
| 6 | SSL/TLS | 连接表单加 SSL 页（CA / 客户端证书 / key），映射 `TLSConfiguration`；对标实现可直接参考字段集 |

### P3 — 执行分析

| # | 项 | 要点 |
| --- | --- | --- |
| 7 | EXPLAIN 可视化 tab | 按「风险 1」替代路线实现；**禁止引入 SHOW PROFILE** |

### P4 — 对象覆盖补全

| # | 项 | 要点 |
| --- | --- | --- |
| 8 | 函数/存储过程/事件只读节点 | 侧栏库下新增三类；列表用 `SHOW FUNCTION STATUS` / `SHOW PROCEDURE STATUS` / `information_schema.EVENTS`（对标的 SQL_DEF 可直接参考），点开显示 `SHOW CREATE X` DDL |

### P5 — 工程化（可选，随时插入）

| # | 项 | 要点 |
| --- | --- | --- |
| 9 | 窗口/侧栏尺寸持久化 | 对标 win-state.js 的等价物 |
| 10 | 查询真取消 | 独立连接 + `KILL QUERY <id>`；对标的"停止"只置 flag 是假停止，不抄 |

## 排序依据与依赖

- P1 先行：高频路径、无外部依赖、可独立冒烟
- P2 改动 `MySQLSession` 建连路径，安排在 P1 之后避免与编辑器工作冲突；SSH/SSL 两项互不依赖
- P3 依赖 P1 的查询 tab 容器（EXPLAIN 复用结果区 UI）
- P4 纯增量，任何时刻可插
- 每阶段独立交付，冒烟走已验证的本机 AX/CGEvent 流程
