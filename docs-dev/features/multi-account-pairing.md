# 多账号配对（Phase 1）

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
- 不替换首页信息架构（首页账号列表为 Phase 2）。
- 不改后端协议与 QR payload。
