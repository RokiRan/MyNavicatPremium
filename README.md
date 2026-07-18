# MyNavicat

用 **Swift 原生**(SwiftUI + mysql-nio）开发的迷你版 Navicat Premium，先支持 **MySQL**。
不追求原版的复杂度，专注五件事：**连接、看表结构、看数据、查询、导出、跨库迁移**。

![表结构](docs/images/1-welcome.png)

## 功能

| 功能 | 说明 |
| --- | --- |
| 连接管理 | 多连接增删改、测试连接、默认数据库；配置持久化（文件权限 0600） |
| 数据库浏览 | 侧栏列出所有 schema（系统库灰色），表/视图区分图标，支持筛选 |
| 表结构 | 列名/类型/可空/键/默认值/EXTRA/注释，附完整建表语句 |
| 数据浏览 | 分页网格（100/500/2000 每页）,NULL 斜体显示，BIT 显示为整数，BLOB 显示为 `0x` 十六进制 |
| SQL 查询 | 多语句脚本执行（`⌘+回车`)，逐条显示结果集/影响行数/错误，数据库上下文选择器 |
| 导出 | CSV / JSON / SQL(INSERT 语句，含 DROP+CREATE，可在任意库重放），原子写文件 |
| 跨库迁移 | 同服务器跨库或跨服务器；选表、自动建库、结构+数据、逐表日志；视图自动识别 |

| 数据浏览 | SQL 查询 |
| --- | --- |
| ![数据](docs/images/3-data.png) | ![查询](docs/images/4-query.png) |

## 运行

要求：macOS 14.4+,Xcode 16 / Swift 6.2+,MySQL 5.7 或 8.x。

```sh
# 打包出 MyNavicat.app(默认 debug;release 用 ./make_app.sh release)
./make_app.sh
open MyNavicat.app

# 或者不打包直接跑
swift run MyNavicat
```

首次启动会预置一个本机连接（`root / 123456 @ 127.0.0.1:3306`)，在「管理连接」里修改成你的。

## 使用

- **打开表**：侧栏点数据库 → 点表名，即开一个标签页（结构/数据切换）
- **新建查询**：工具栏「新建查询」或欢迎页按钮；`⌘+回车` 运行，`⌘+⇧+W` 关闭标签页
- **导出**：选中表标签页 → 工具栏「导出」→ 选格式和位置
- **迁移**：选中数据库 → 工具栏「迁移」→ 选目标连接/目标库（可输入新库名自动创建）→ 勾选表 → 开始

## 架构

```
Sources/
├── MyNavicatCore/          # 核心库（无 UI 依赖，可单测）
│   ├── MySQLSession.swift  #   actor 封装连接：断线重连、USE 上下文跟踪、
│   │                       #   INSERT 语句构造（转义/hex/生成列剔除）
│   ├── SQLUtils.swift      #   标识符/字符串转义、多语句切分（引号/注释感知）
│   ├── Exporter.swift      #   CSV/JSON/SQL 流式导出，临时文件+原子替换
│   ├── Migrator.swift      #   跨库迁移：事务包裹、外键检查开关、视图 DEFINER 剥离
│   ├── ConnectionStore.swift
│   └── Models.swift
├── MyNavicat/              # SwiftUI 应用
│   ├── AppState.swift      #   全局状态（连接/库/表/标签页）
│   ├── ContentView.swift   #   侧栏 + 标签页容器 + 工具栏
│   ├── TableViews.swift    #   结构/数据网格
│   ├── QueryView.swift     #   查询编辑器
│   └── Sheets.swift        #   连接管理/导出/迁移面板
Tests/MyNavicatCoreTests/   # 16 个集成测试（真实连接 MySQL)
```

关键技术点：

- **mysql-nio** 纯 Swift 驱动，文本协议用于结果集（保留原始显示格式），预处理协议用于 DML/DDL 拿 `affectedRows`;`SET`/`BEGIN` 等不支持预处理的语句自动路由回文本协议
- **二进制安全**:BLOB/BINARY 按字符集标志识别，导出/迁移用 `X'hex'` 字面量，BIT 转无符号整数，往返不丢数据
- **迁移安全**：同连接同库 = 源时拒绝执行（否则会先 DROP 源表）；每表数据在一个事务里，失败整体回滚；复制期间 `FOREIGN_KEY_CHECKS=0`;GENERATED ALWAYS 列自动剔除

## 测试

```sh
swift test   # 默认连 127.0.0.1:3306 root/123456
# 用环境变量覆盖：
MYNAVICAT_HOST=... MYNAVICAT_PORT=... MYNAVICAT_USER=... MYNAVICAT_PASS=... swift test
```

测试会创建/销毁 `mynavicat_test_a`、`mynavicat_test_b` 两个临时库，覆盖：连接、元数据、结构、分页、DML、中文/NULL/BLOB/BIT 往返、三种格式导出、SQL 重放、跨库迁移、生成列、同库防护。

## 已知限制

- 大表导出/迁移使用 `LIMIT/OFFSET` 分页；源表有并发写入时可能重行/漏行（大表建议低峰期操作）
- 密码明文存储在 `~/Library/Application Support/MyNavicat/connections.json`（已设 0600 权限，后续可换 Keychain)
- 查询结果为空时不显示表头（mysql-nio 空结果集不携带列元数据）
- 迁移范围不含触发器/存储过程/事件
- 多语句切分不支持 `DELIMITER`（存储过程脚本）

## 路线图

- [ ] PostgreSQL 支持
- [ ] 数据编辑（单元格增删改）
- [ ] 收藏查询 / 查询历史
- [ ] Keychain 存储密码
- [ ] SSH 隧道连接
