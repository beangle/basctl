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
- target 不可达时，owner 应释放或断开，不能长期占用
- follower 没有 hub 连接，不参与 LinkMutex 竞争

## 4. 新 agent 启动

```text
连接 hub
  → role = master
  → 上报自身状态
  → 启动 master 周期任务
```

master 周期任务：

```text
查询 LinkMutex

没有 mutex：
  写入 owner=自己, target=选择的最小 rank master
  探测 target
  连接 target
  删除 mutex 或断开 hub

有 mutex 且 owner=自己：
  继续自己的连接流程

有 mutex 且 owner=别人：
  放弃自己的推荐
  退避等待
  不能使用这个 target
  不能删除这个 mutex
```

如果连接 target 成功：

```text
删除 LinkMutex
断开 hub
role = follower
```

如果 target 不可达：

```text
owner 删除 mutex
回到 master
退避后重新尝试
```

这样即使所有 agent 几乎同时启动，也只有 LinkMutex 的 owner 会建立到 target 的连接。

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
follower：探测 B 的 /health 和 /agent 握手
follower → A：成功/失败
```

任何 follower 失败，A 不迁移，保持现状。

### 串行迁移

A 保持 hub 连接和 master 身份，暂停接受新 follower，然后一次只迁移一个 follower。

```text
A 通知 follower1：migrate-to B
follower1 探测 B
follower1 连接 B
follower1 回 ack，或关闭到 A 的旧连接
A 确认 follower1 已迁移
A 再通知 follower2
...
```

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
| follower 迁移中失败 | 停止后续迁移；成功者留在 B，失败者回 hub |
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
- 第一个写入 LinkMutex 的 owner 发起连接
- 后启动的 agent 看到 owner 不是自己就等待
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

本文是目标模型。

当前实现仍有 `candidate` 内部角色，以及以 `GroupMaster` 为中心的推荐逻辑；后续需要按本文改为：

- 移除 candidate
- 增加 `hubConnected` 独立状态
- 将 `GroupMaster` 改为 `LinkMutex(owner, target, expires)`
- listener 只接受 hubConnected master
- master 周期任务增加 follower 探测与串行迁移
- follower 不获取 LinkMutex
