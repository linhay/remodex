# 设置页支持双源切换（LAN / Public Relay）

## 背景
- 当前已支持双源候选（LAN relay + Public relay）并在连接阶段自动排序。
- 现状只有自动策略，用户无法在设置页显式切换优先源。

## 目标
- 在设置页 Connection 区块新增“Relay Source”切换。
- 切换后持久化到本地，并在后续连接/重连时生效。

## 非目标
- 不修改 QR payload 协议。
- 不新增后端接口。
- 不改变现有断线自动重连机制与错误提示文案。

## BDD 场景
1. 当用户将 Relay Source 设为 `LAN first` 时：
   - 连接候选顺序应优先 LAN，再尝试 Public。
2. 当用户将 Relay Source 设为 `Public first` 时：
   - 连接候选顺序应优先 Public，再尝试 LAN。
3. 当用户将 Relay Source 设为 `Auto` 时：
   - 保持现有策略（优先可达 LAN；否则 Public 优先）。
4. 重新启动 App 后：
   - 设置项应保持为上次选择值。

## 验收标准
- 设置页可见并可切换 `Auto` / `LAN first` / `Public first`。
- 连接候选 URL 排序与选择一致。
- 单元测试覆盖上述三种策略排序行为。
