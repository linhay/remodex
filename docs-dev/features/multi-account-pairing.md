# 多账号配对与账号首页（Phase 1-2）

## 目标
- 支持基于配对配置的多账号管理（每个账号 = 一组 relay/session/mac 配置）。
- 设置页内可切换当前账号、编辑名称、删除非当前账号、扫码新增账号。
- 保持现有 Settings UI 风格（卡片、字体、颜色、按钮样式）。

## 已实现范围（Phase 1）
1. 服务层
- `CodexService` 增加账号列表与当前账号状态。
- 旧单账号 key 首次迁移为一个 `Migrated` 账号。
- 连接成功/失败写入账号诊断：`lastConnectedAt` / `lastErrorMessage`。
- 新增账号导出/导入接口（服务层预留）。

2. 数据隔离
- 消息历史按账号分桶（`CodexMessagePersistence(accountScope:)`）。
- AI change sets 按账号分桶（`AIChangeSetPersistence(accountScope:)`）。
- runtime 默认项与本地 archived/deleted 集合按账号 namespaced key 存储。

3. 设置页 UI
- Connection 区块新增 Accounts 列表，显示账号名、当前/连接状态、最近连接时间、最近错误。
- 支持账号切换（在线时立即重连，离线时仅切换上下文）。
- 支持账号重命名与删除（仅允许删除非当前账号）。
- 新增 Add 按钮，复用现有 QRScanner 流程创建账号。

## 非目标
- 不改后端协议与 QR payload。

## Phase 2（账号页导航重构）
1. 目标
- 账号页改为独立 `present` 层，不再依赖首页 `NavigationStack` push/pop。
- 避免“点击账号卡片后进入聊天，又被状态抖动弹回账号页”。

2. 实现
- `ContentView` 主页改为“聊天主壳常驻 + 账号页 `fullScreenCover`”双层结构。
- 进入聊天（点账号、通知跳转、线程恢复）时只做一件事：关闭账号页。
- 从侧边栏点 “Back to Accounts” 时，显式重新展示账号页。
- 移除账号页 push 路径和相关兜底逻辑（`homeNavigationPath` 等）。

3. 验收场景（BDD）
- 场景 A：点击账号卡片 -> 立即进入聊天壳 -> 不会自动回跳账号页。
- 场景 B：在聊天页点 “Back to Accounts” -> 账号页以独立层展示。
- 场景 C：通知/横幅打开线程 -> 聊天展示优先，账号页自动收起。

## 账号删除交互（补充）
1. 目标
- 账号删除入口放在账号卡片右上角 `...` 菜单。
- 删除操作必须二次确认，降低误删风险。

2. 实现
- 第一次确认使用 `confirmationDialog`，仅用于“继续删除”确认。
- 第二次确认使用 destructive `alert`，用户再次确认后才调用 `deleteRelayAccount`。
- 保持“当前账号不可删除”的既有约束不变（服务层兜底）。

3. 验收场景（BDD）
- 场景 D：在账号卡片右上角菜单点击 Delete -> 出现第一次确认。
- 场景 E：第一次确认点 Continue -> 出现第二次确认。
- 场景 F：未完成第二次确认时，不会触发账号删除。
