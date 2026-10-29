# Agent 组网协调模型

本文描述 agent 如何自行协调连接 hub、选择 target master，以及 master 带领 follower 迁移到新 master 的目标模型。

它不是强一致协议。目标是：

- 与 agent 启动顺序无关
- 与网络拓扑细节无关
- 允许短暂多个 master
- 通过本地探测、LinkMutex 和重试最终收敛
- follower 不连 hub，避免多级中继

## 1. 角色

本地角色只有两种：

```text
master
follower
```

不再有 `candidate`。

- agent 连上 hub 后就是 master，即使它当前有 0 个 follower
- master 可以自主上报，也可以中继 follower 的数据、命令和结果
- follower 已断开 hub，只连自己的 target master
- follower 永远不接受其他 agent 的连接

## 2. 连接准入

物理 listener 只接受同时满足以下条件的连接：

```text
hubConnected == true
role == master
```

因此：

- follower 不接受连接，不会形成 follower → follower 的多级跳转
- 只有 hub-connected master 是中继节点
- 一个 follower 最多经过一层 master 到达 hub
- master 可以有 0 个 follower

`hubConnected` 与 `role` 是独立状态：

```text
hubConnected  // 是否连着 hub
role          // master | follower
```

master 连接 target 成为 follower 后，`role` 变为 follower，`hubConnected` 变为 false，listener 同时停止接受连接。

## 3. LinkMutex

hub 按 `(project, group)` 保存一条互斥记录：

```text
LinkMutex {
  owner
  target
  expires
}
```

它不是“当前 master”，也不是租约。

它只表示：

```text
owner 正在尝试连接 target
```

规则：

- 同一时刻每个 group 只有一条 LinkMutex
- 只有 owner 可以使用和删除
- 非 owner 即使发现 target 可达，也不能使用这条记录
- 非 owner 不能删除
- owner 断开 hub 后，hub 兜底清理
- `expires` 用于 owner 写入后异常失联的兜底
- TTL 由 agent 按组规模计算：`60 + 5 * groupIps.length` 秒，hub 限制在 60–300 秒
- target 不可达时，owner 应释放或断开，不能长期占用
- follower 没有 hub 连接，不参与 LinkMutex 竞争

## 4. 新 agent 启动

```text
连接 hub
  → role = master
  → 上报自身状态
  → 探测组内候选
```

选择 target：

```text
target 是自己（或没有更小的可达 master）：
  直接保持 master
  不写 LinkMutex
  不需要“首次选主”

target 是其他 master：
  申请 LinkMutex(owner=自己, target=B)
  granted：
    连接 B
    断开 hub
    role = follower
  denied：
    保持 master
    等待下一个周期
```

LinkMutex 只用于“主动跟随某个 target”的连接动作，不是首次注册，也不是当前 master 的登记。

如果连接 target 成功：

```text
断开 hub
由 hub 清理 owner 的 LinkMutex
role = follower
```

如果 target 不可达：

```text
owner 释放或断开
回到 master
退避后重新尝试
```

## 5. Master 的选择

推荐依据：

```text
当前连着 hub 的 master 中
rank 最小且可达的那个
```

rank 来自 hosts 列表顺序。

新 agent 发现已有非自己的 LinkMutex 时：

- 不覆盖
- 不使用别人的 target
- 等待 owner 完成或过期

这是严格串行化，不追求并行连接。

## 6. A 带领 follower 迁移到 B

A 是当前 master，N 个 follower。A 想迁移到 B。

### 前置条件

- B 必须连着 hub
- B 必须是 master
- B 必须与 A 属于同一个 group；hub 的 LinkMutex 会拒绝跨组 target
- B 能接受连接
- A 能探测到 B
- 每个 follower 都能探测到 B

### 连通性探测

A 先自己做：

```text
A probe B
```

然后通过现有 master-follower 连接，逐个让 follower 探测 B：

```text
A → follower：probe target=B
follower：带 token 和 X-Bas-Agent 请求 B 的 /probe
B：校验 role=master、hubConnected、!migrating、followerIps、来源 IP
follower → A：成功/失败
```

任何 follower 失败，A 不迁移，保持现状。

### 串行迁移

A 保持 hub 连接和 master 身份，暂停接受新 follower，然后一次只迁移一个 follower。

```text
A 对所有 follower 发送 probe target=B
A 确认全部 follower 可达 B
A 写 LinkMutex(owner=A, target=B)
A 通知 follower1：migrate-to B
follower1 探测 B
follower1 连接 B
follower1 回 ack，或关闭到 A 的旧连接
A 确认 follower1 已迁移
A 再通知 follower2
...
```

先写 LinkMutex 是为了在 A 仍持锁时阻止其他 master 同时向 B 迁移。
A 不需要等所有 follower 完成后才申请锁；锁在 A 断开 hub 时由 hub 清理。

**follower 不需要获取 hub 上的 LinkMutex。**

它们已经断开 hub，没有能力写或删除 LinkMutex。
“一次只连接一个”由 A 的迁移队列保证，而不是 follower 抢锁。

### A 自己迁移

所有 follower 迁移成功后：

```text
A 写 LinkMutex(owner=A, target=B)
A 断开 hub
hub 清理 owner=A 的 LinkMutex
A 连接 B
A 成为 follower
```

A 不需要先变成 follower 再删除 mutex，因为断开 hub 后 hub 会清理。

### N=0

没有 follower 时：

```text
A 探测 B 成功
A 写 LinkMutex(owner=A, target=B)
A 断开 hub
hub 清理 mutex
A 连接 B
```

没有 follower 迁移队列。

## 7. 失败与收敛

系统接受短暂不一致，不做强一致。

| 场景 | 行为 |
|---|---|
| follower 探测 B 失败 | A 不迁移，保持 master |
| follower 迁移中失败 | 停止后续迁移；成功者留在 B，失败者留在 A，下个周期重试 |
| A 断开 hub 后连不上 B | A 回 hub，重新成为 master |
| owner 写完 mutex 后失联 | hub 清理或 expires 兜底 |
| 非 owner 看到 mutex | 等待，不覆盖、不删除 |
| target 不可达 | owner 释放；其他 agent 退避重试 |
| 多个 master 短暂并存 | 允许；通过 LinkMutex、探测和重连收敛 |
| B 在迁移后失联 | follower 回 hub，重新成为 master 并竞争 |

### 最终一致性

目标是：

```text
每个 follower 最终连接到一个可达的 target
每个 group 最终只有一个被推荐的 target
```

不保证：

- 任意时刻只有一个 master
- 迁移零中断
- 所有 agent 同时看到相同状态

## 8. 不变量

1. 本地角色只有 master/follower。
2. 只有 `hubConnected && master` 接受连接。
3. follower 不接受连接。
4. 每个 `(project, group)` 最多一条 LinkMutex。
5. 只有 owner 能使用和删除 LinkMutex。
6. hub 在 owner 断开时清理。
7. 非 owner 看到 target 可达也不能使用。
8. follower 不参与 LinkMutex 竞争。
9. A 只有在 follower 联通性检查全部通过后才发起整组迁移。
10. 迁移队列由 A 串行控制，一次一个 follower。

## 9. 与启动顺序、网络拓扑的关系

### 启动顺序无关

- 任意 agent 先启动都可以成为 master
- 第一个启动的 agent 直接保持 master，不写 LinkMutex
- 后启动的 agent 探测到它后，把 target 指向它，再申请 LinkMutex
- 并发申请时只有 owner 能建立连接，其他 agent 等待
- 不需要预选固定 master

### 网络拓扑无关

- 不看全局拓扑图
- 每个 agent 只做局部探测
- A 只要求自己和当前 follower 能到 B
- 不可达的 follower 会阻止迁移，不会造成整组失联

### 自行收敛

- 失败回 hub，重新成为 master
- mutex 过期或 owner 断开后重新竞争
- 没有中心调度器决定拓扑

## 10. 实现状态

已实现：

- 本地角色只有 `master` / `follower`
- hub-connected master 才接受连接
- hub 上的 `LinkMutex(owner, target, expires)` 与 owner 清理
- 新 agent 跟随其他 target 时通过 `link:claim` 串行连接
- master 每 300 秒扫描组内候选
- A 对 follower 到候选 master 的 `migrate:probe`
- A 写 LinkMutex 后串行 `migrate:to` 每个 follower
- 全部完成后 A 断开 hub、连接新 target
- 更小 rank 后加入由下一个 master 周期任务自然发现，不需要事件监听

已知限制：

- follower 迁移到一半失败时不做回滚；已迁移者留在新 target，未迁移者留在 A，A 释放 LinkMutex 并保持 master，下个周期重试
- 迁移探测超时为 2 秒，迁移执行超时为 3 秒
- 迁移任务在独立 fiber 中运行，不再阻塞 master 的 hub 消息循环
- 迁移/探测 result 在内存中保留 30 秒，过期后丢弃
- LinkMutex TTL 随组内 agent 数量线性增长，避免 follower 多时迁移期间锁提前过期
- LinkMutex claim 成功后异常退出会自动 release，避免锁一直占着到 TTL
- `/probe` 已覆盖鉴权、follower 分配、来源 IP、master/hubConnected 和 `migrating`；尚未真正执行 WebSocket `/agent` Upgrade
- 没有强一致的全局拓扑视图

当前周期为 300 秒，实现中固定在 `rebalanceInterval`。
