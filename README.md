<p align="center">
  <img src="assets/images/banner.png" alt="Deadline-Carl — The Token Burner" width="100%">
</p>

<h1 align="center">Deadline-Carl</h1>

<p align="center"><strong>让 Codex 长任务有时间感、有证据、能恢复。</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.4.0-EF6C00" alt="Version 3.4.0">
  <img src="https://img.shields.io/badge/platform-Windows-0078D4" alt="Platform Windows">
  <img src="https://img.shields.io/badge/PowerShell-7%20recommended-5391FE" alt="PowerShell 7 recommended">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-2E7D32" alt="Apache-2.0 license"></a>
</p>

Deadline-Carl 是一个可直接安装的 Codex Skill，面向 Windows 上耗时较长、不能一次做完的仓库任务。它把需求冻结、代码实现、证据整理、独立验证和失败修复串成一条可恢复的工作流，再用外部 PowerShell 监督器管理时间、进程和检查点。

它坚持一条很朴素的原则：还在运行，不等于已经完成；实现完了，也不等于验证通过。

## 为什么需要 Deadline-Carl

普通的长时间 AI 编码任务很容易遇到几类问题：会话中断后不知道做到哪了，执行者根据自己的修改宣布成功，或者临近截止时间仍在扩展范围，最后留下一个无法交付的半成品。

Deadline-Carl 把这些隐含状态写进仓库，并用脚本执行硬约束：

- 任务开始前冻结验收标准和工作项，后续不能悄悄缩小范围
- 实现者负责写代码和证据，新的验证者负责重新检查
- 状态保存在磁盘上，Codex 或监督器中断后可以继续
- 时间变少时调整优先级，但不降低 PASS 标准
- 实现、独立验证和验收进度分开计算
- 临时测试输出与正式验收证据隔离，Verifier 不能覆盖已经归档的 `raw/`
- 每轮把当前阶段的精确写入白名单和机器可读路径策略交给 Worker，辅助 Skill 不能扩大正式工件范围
- 误建的新文件会保留到可恢复隔离区后重试；修改或删除受保护工件仍立即阻塞
- 自动忽略 PID、心跳和日志等本机状态，同时检查宽泛 ignore 和已跟踪运行文件
- 预算耗尽或工作无法完成时，如实交付缺口，不把部分完成包装成成功

| 常见做法 | Deadline-Carl |
| --- | --- |
| 从聊天记录猜测进度 | 从仓库中的计划、进度、证据和运行时状态读取 |
| 实现者自己宣布完成 | 新的验证者逐条复查验收标准 |
| 重启后从头开始 | 从最后一个未完成阶段恢复 |
| 迭代次数被当成完成度 | 实现、验证、验收和执行容量分别报告 |
| 时间紧张时随意砍需求 | 只改变交付顺序，不改变验收语义 |

## 适合什么任务

适合：

- 跨多个文件或模块的功能开发
- 需要测试、构建、截图或其他证据的交付
- 可能运行数小时、需要人工中断后继续的任务
- 有明确截止时间或有效工作时长限制的任务
- 需要审计“做了什么、如何证明、还有什么没完成”的任务

不适合：

- 一次就能完成的小修改
- 只需要解释、评审或诊断的只读请求
- 定时任务、系统服务或开机启动任务
- 没有 Git 仓库的临时目录
- 希望跳过验证、直接获得“完成”结论的工作流

## 工作原理

Deadline-Carl 有两层：

1. 证明循环负责需求、实现和验收语义。它冻结规格，记录逐项证据，并让新的验证者决定 PASS、FAIL 或 UNKNOWN。
2. PowerShell 监督器负责运行时。它启动新的 `codex exec` 进程，记录心跳和检查点，限制时间与迭代次数，并在中断后恢复。

<p align="center">
  <img src="assets/images/proof-loop-diagram.png" alt="Deadline-Carl proof loop" width="100%">
</p>

### 证明阶段

| 阶段 | 做什么 | 进入下一阶段的条件 |
| --- | --- | --- |
| `freeze` | 冻结任务说明、验收标准和不可变工作项 | 规格与计划结构有效 |
| `build` | 实现冻结的工作项并运行相关检查 | 所有强制工作项标记为已实现 |
| `evidence` | 整理逐条验收证据和原始输出 | 证据包结构有效 |
| `verify` | 新会话重新检查代码，同时覆盖判定和问题报告 | 全部验收项 PASS 且零问题报告有效才能完成 |
| `fix` | 复核失败条件并做最小修复 | 修复和证据准备好后再次独立验证 |

最终完成需要同时满足：运行时记录 `completed: true`、独立验证结果为 `PASS`、证明包结构校验通过。

### 截止时间阶段

默认的 `deadline-aware` 模式比较“剩余时间”与“预计剩余工作＋验证修复＋风险预留”，不再按固定时间百分比切换：

| 策略 | 判断依据 | 工作方式 |
| --- | --- | --- |
| `polish`（精修） | 必需实现已完成，验证、风险和一项提升都放得下 | 执行冻结范围内的一次限时提升，再收集证据和独立验证 |
| `craft`（正常实施） | 完整交付与保守预留能够完成 | 正常质量实现全部要求 |
| `focus`（聚焦交付） | 完整交付有风险，或估算尚不可靠 | 简化实现，优先必需功能与高风险问题 |
| `ship`（保核心） | 全部要求预计放不下，但核心和检查能完成 | 交付可用闭环，如实列出必需功能缺口 |
| `last-call`（保成果） | 连核心或最少验证迭代都难以完成 | 保存稳定成果，有价值时交付接口/骨架，明确未实现内容 |

这些阶段只影响工作顺序。进入 `last-call` 也不会让未完成的验收项自动通过。

每轮 Worker 返回剩余工作区间、置信度、依据和预计迭代数。监督器结合实际耗时、估时偏差和检查成本修正判断；升级需连续两次新估算支持，降级无需等待。没有可靠估算时采取保守策略，不能仅因为时间多就精修。

精修不是擅自扩大需求。例如明确要求“简单几何体敌人”，可以提升受击反馈和辨识度，但不能自行改成复杂美术风格。允许的提升方向在需求冻结时记录；当前版本每个任务最多一次限时精修，避免无限优化。有余量且没有值得做的提升时，提前完成。

可在初始化时增加 `-DeadlineUtc '2026-09-05T18:00:00+08:00'`。实际可用时间取“剩余活跃预算”和“距绝对截止时间”中较小者。暂停不扣活跃时间，但绝对截止时间继续流逝；`extend` 不会自动延后截止时间。

### 时间都用到哪里了？

`status` 返回最近 10 段策略历史、5 轮迭代记录及完整耗时汇总，`history -RepoRoot <仓库> -TaskId <任务>` 返回完整记录。每段历史记录起止 UTC 时间、策略、工作阶段、实际活跃时长、切换原因及当时估算。暂停与恢复分段记录，等待开销单独列出；旧版没有记录的历史不会被补造。

可以直接问：“这次 Loop 在各策略下分别用了多久？预算是充裕还是不足？”Skill 会整理时间线、各策略耗时、剩余余量和结束原因。时间用完可能源于阻塞或反复失败，不能直接断言预算太少；提前完成也不意味着预算浪费。详细字段和判断公式见 [动态预算与历史记录](references/ADAPTIVE_BUDGET.md)。

### 进度怎么计算

Deadline-Carl 不给出一个含糊的“总体百分比”，而是分别报告：

- 实现进度：已实现工作项 / 冻结工作项总数
- 独立验证：已被新验证者确认的工作项 / 工作项总数
- 验收进度：PASS 的验收标准 / 验收标准总数
- 迭代容量：已启动迭代 / 最大迭代数，只代表剩余执行机会

例如，实现进度 `8/10`、独立验证 `5/10` 表示 8 项已经写完，但只有 5 项经过新的验证者确认，任务仍不能宣告完成。

## 环境要求

- Windows
- PowerShell 7（`pwsh`）优先；脚本也会尝试 Windows PowerShell
- Python 3.10 或更高版本
- Git 仓库
- 已安装并登录的 Codex CLI

安装后可以先运行 `doctor` 检查 Python、Codex CLI、登录状态和包文件。

## 安装

克隆仓库并运行安装脚本：

```powershell
git clone https://github.com/xcymm3/Deadline-Carl.git
Set-Location .\Deadline-Carl
pwsh -NoProfile -File .\scripts\install_skill.ps1
```

安装完成后重启 Codex，让新的 Skill 元数据被发现。

默认安装位置：

- 设置了 `CODEX_HOME`：`$CODEX_HOME\skills\deadline-carl`
- 未设置 `CODEX_HOME`：`$HOME\.codex\skills\deadline-carl`

覆盖已有安装时使用 `-Force`：

```powershell
pwsh -NoProfile -File .\scripts\install_skill.ps1 -Force
```

安装器不会直接删除旧版本。已有的 `deadline-carl` 或旧名称 `codex-durable-loop` 会先移动到带时间戳的备份目录。

Codex Skill 的通用结构和工作方式可参考 [OpenAI 官方 Build skills 文档](https://developers.openai.com/codex/build-skills)。

## 快速开始

### 在 Codex 中调用

Deadline-Carl 默认只在明确调用时启用。下面的请求同时给出了仓库、任务、预算，并明确授权启动后台监督器：

```text
$deadline-carl 请在 D:\work\my-app 中完成用户登录限流功能。
冻结可验证的工作项，设置 180 分钟有效工作预算，初始化并启动可恢复循环。
```

如果只想初始化证明文件而不启动后台循环，应明确写出：

```text
$deadline-carl 请为 D:\work\my-app 中的登录限流任务初始化证明文件，不要启动监督器。
```

### 直接运行脚本

先定位已安装 Skill：

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$skill = Join-Path $codexHome 'skills\deadline-carl'
```

检查环境：

```powershell
& "$skill\scripts\durable_loop.ps1" doctor -RepoRoot D:\work\my-app
```

初始化任务：

```powershell
& "$skill\scripts\durable_loop.ps1" init `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit `
  -TaskText "实现登录限流，并证明所有验收标准。" `
  -ActiveBudgetMinutes 180 `
  -IterationTimeoutMinutes 20 `
  -MaxIterations 24 `
  -DeliveryMode deadline-aware
```

启动监督器：

```powershell
& "$skill\scripts\durable_loop.ps1" start `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

`start` 会启动隐藏的 PowerShell 监督器并立即返回状态。任务继续在后台运行。

## 常用命令

以下示例沿用前文的 `$skill`、仓库和任务 ID。

### 查询进度

```powershell
& "$skill\scripts\durable_loop.ps1" status `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

脚本返回机器可读 JSON。通过 Skill 直接询问时，Codex 会整理为更适合阅读的状态：

```text
当前状态：进行中，正在实现冻结的工作项
任务：feature-login-rate-limit（D:\work\my-app）
- 实现进度：8/10
- 独立验证：5/10
- 验收进度：3/6 通过（1 失败，2 未确认）
- 时间预算：剩余 47 分钟（39%，聚焦交付阶段）
- 剩余工作估算：40～65 分钟，置信度中等；保守估算超出余量，暂不精修
- 最近进展：已完成限流存储层，正在补充接口集成
- 阻塞或缺口：AC4 的并发测试尚未通过
- 下一步：完成剩余工作项并重新整理证据
```

### 写入检查点

```powershell
& "$skill\scripts\durable_loop.ps1" checkpoint `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

### 安全停止

```powershell
& "$skill\scripts\durable_loop.ps1" stop `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

当前 Worker 可以完成手上的迭代，但监督器不会再启动下一次迭代。任务文件、日志和 Git 工作区会保留。

### 恢复任务

```powershell
& "$skill\scripts\durable_loop.ps1" start `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

`start` 是恢复，不是重置。它不会补满时间，也不会删除代码或证明文件。如果旧监督器消失但 Worker 仍在运行，新监督器会接管该 Worker。

### 增加时间预算

先停止监督器，再显式增加有效工作时间：

```powershell
& "$skill\scripts\durable_loop.ps1" extend `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit `
  -AdditionalBudgetMinutes 120
```

增加预算会保留已消耗时间、当前阶段、日志和 Git 状态。它不会增加最大迭代次数。

## 常用参数

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `ActiveBudgetMinutes` | `720` | 监督器运行期间可消耗的有效工作分钟数 |
| `IterationTimeoutMinutes` | `25` | 单次 Worker 迭代的超时限制 |
| `MaxIterations` | `30` | 最多启动多少次 Worker |
| `RetryDelaySeconds` | `20` | 可恢复失败后的重试间隔 |
| `CliUnavailableTimeoutMinutes` | `30` | Codex CLI 更新或暂时不可用时的等待窗口 |
| `MaxConsecutiveFailures` | `6` | 连续失败达到该值后阻塞任务 |
| `DeliveryMode` | `deadline-aware` | `deadline-aware` 或 `proof-first` |
| `Model` | 空 | 可选的 Codex 模型覆盖 |
| `CodexExecutable` | 自动发现 | 可选的 Codex CLI 路径覆盖 |

`proof-first` 保留时间和迭代硬限制，但不会根据剩余时间调整 Worker 的工作优先级。

## 状态与文件

证明文件保存在目标仓库：

```text
.agent/tasks/<TASK_ID>/
├── spec.md                 # 冻结的任务规格与验收标准
├── plan.json               # 不可变工作项分母
├── progress.json           # 实现状态、说明和证明引用
├── evidence.md             # 人类可读证据
├── evidence.json           # 结构化逐项证据
├── verdict.json            # 新验证者的判定
├── problems.md             # 每轮验证覆盖；PASS 为零问题报告，否则为详细问题
├── deadline-report.md      # 最后冲刺阶段的可选交付说明
└── raw/                    # 构建、测试、Lint 和截图等原始输出
```

监督器状态与日志单独保存：

```text
.agent/durable-loop/<TASK_ID>/
├── config.json
├── runtime.json
└── logs/
```

每个 Worker 还会获得独立的临时输出目录：

```text
.agent/deadline-carl-scratch/<TASK_ID>/iteration-<NNN>-<PHASE>/
```

该路径同时通过 `DEADLINE_CARL_OUTPUT_DIR` 环境变量提供。日常测试、截图、trace、coverage 和报告应先写入这里；只有 `evidence` 和 `fix` 阶段可以把选定结果复制进正式 `raw/`。

每轮还提供三个更明确的环境变量：

- `DEADLINE_CARL_FORMAL_TASK_DIR`：严格管理的 `.agent/tasks/<TASK_ID>/`
- `DEADLINE_CARL_SCRATCH_DIR`：本轮临时输出目录
- `DEADLINE_CARL_ALLOWED_TASK_WRITES`：当前阶段可写正式工件的 JSON 数组

辅助 Skill 要求“列出预计改动文件”时，应在 Worker 消息中说明；需要临时落盘时写入 `auxiliary/<skill>/`。像 Hallmark 的 `tokens.css`、`.hallmark/preflight.json` 这类真正属于当前产品范围的文件仍写入正常项目树，而不是正式任务账本或 scratch。

`init` 会在项目根 `.gitignore` 中幂等维护以下精确规则，保留项目已有内容：

```gitignore
# deadline-carl:local-state:start
/.agent/durable-loop/
/.agent/deadline-carl-scratch/
/.agent/tasks/*/.init-in-progress
# deadline-carl:local-state:end
```

不要忽略整个 `.agent/`，否则规格、计划、证据和验证结论也会被隐藏。

Worker 不允许编辑监督器目录。`runtime.json` 由监督器原子更新，记录当前阶段、剩余时间、心跳、进程身份、失败次数和完成状态。

Supervisor 会比较每轮前后的任务工件哈希并执行阶段写入边界。若违规全部是新建文件（例如 build 阶段误建 `ui-build-plan.md`），它会把文件移动到本轮 scratch 的隔离目录，写入包含原路径、目标路径、SHA-256、原因和时间的 `manifest.json`，将该轮计为失败并重试同一阶段。连续发生仍会达到失败上限而阻塞。若 `verify` 覆盖 `raw/`，或出现修改、删除、路径不安全、混合违规，则立即 blocked，不自动回退源码或正式证据。

旧版本留下的 created-only 阻塞可在停止状态下修复：

```powershell
& "$skill\scripts\durable_loop.ps1" repair-boundary `
  -RepoRoot D:\work\my-app `
  -TaskId feature-login-rate-limit
```

命令只隔离仍存在的 `created:` 文件并清除 blocker，不会启动 Loop。随后用普通 `start` 恢复。它拒绝 `modified:`、`deleted:`、文件缺失、越界路径和正在运行的任务；这些情况必须人工检查。详细规则见 [写入边界与恢复](references/WRITE_BOUNDARIES.md)。`gitHygiene` 同时报告 ignore 是否生效、正式工件是否被宽泛规则隐藏，以及本地状态是否已经被 Git 跟踪。

## 安全边界

- 不注册 Windows Scheduled Task、系统服务或开机启动项
- 不在未经明确授权时启动后台循环
- 不使用无限制的自动批准模式
- 不在恢复时重置、清理或覆盖 Git 工作区
- created-only 越界文件可恢复隔离并重试；修改、删除或不安全越界立即停止
- 超时后终止对应 Worker 进程树，避免留下失控子进程
- 只有全部验收项由新验证者确认后才能标记完成
- 预算不足时保留可用核心并记录缺口，不伪造 PASS

## 故障排查

### `doctor` 返回 `ready: false`

检查输出中的 `pythonPath`、`codexPath`、`codexAuthenticated` 和三个包文件字段。常见原因是 Python 版本不足、Codex CLI 不在 `PATH`，或 Codex 尚未登录。

### Codex 没有发现 Skill

确认安装目录下存在 `deadline-carl\SKILL.md`，然后重启 Codex。若设置了 `CODEX_HOME`，确认安装脚本和 Codex 使用的是同一个目录。

### 安装时提示目录已存在

使用 `-Force`。安装器会先备份现有目录，再放入新版本。

### Codex Desktop 更新时任务中断

更新完成后再次运行同一个 `start` 命令。监督器会读取磁盘状态，从最后一个未完成阶段继续。

### 时间预算耗尽

先查看 `status` 中的 `stopReason` 和未通过项。如果确实需要更多时间，停止任务后使用 `extend`。不要通过重新初始化任务来绕过已有消耗记录。

### 最大迭代次数耗尽

增加时间不会增加迭代次数。先检查连续失败原因和日志，再决定是否以新的、边界更清晰的任务重新初始化。

### `ui-build-plan.md` 等辅助文档触发写入边界

v3.4 起，新运行会自动把这类 created-only 文件隔离到 scratch 并重试，不需要丢弃源码改动。若这是旧运行留下的 blocked 状态，先执行 `repair-boundary`，检查返回的 manifest，再普通 `start`。如果诊断含 `modified:` 或 `deleted:`，不要强行修复；先人工恢复或确认正式工件。

## 开发与验证

修改 Skill 后运行：

```powershell
python .\scripts\verify_package.py
pwsh -NoProfile -File .\scripts\test_boundary_recovery.ps1
pwsh -NoProfile -File .\scripts\test_durable_loop.ps1
```

测试会在临时 Git 仓库中检查任务初始化、计划冻结、进度门禁、中断接管、独立验证、安装与自更新流程。

主要目录：

```text
agents/       Codex 界面元数据
assets/       提示词、模板、schema 和图片
references/   阶段命令、运行时与证明协议说明
scripts/      安装器、监督器、任务辅助程序和测试
SKILL.md      Codex 加载的 Skill 入口
```

更详细的协议说明见：

- [SKILL.md](SKILL.md)：完整运行规则
- [COMMANDS.md](references/COMMANDS.md)：各阶段职责和提示词
- [DURABLE_RUNTIME.md](references/DURABLE_RUNTIME.md)：监督器状态与恢复语义
- [WRITE_BOUNDARIES.md](references/WRITE_BOUNDARIES.md)：阶段写入白名单、隔离与修复规则
- [SCHEMAS.md](references/SCHEMAS.md)：计划、进度、证据和判定结构
- [VERIFICATION.md](VERIFICATION.md)：包验证范围

## 参与贡献

欢迎提交 Issue 和 Pull Request。改动应保持单一职责，不应削弱验收标准或恢复语义。提交前请运行包验证和端到端测试，并避免把测试生成物加入仓库。

提交信息使用 Conventional Commits，例如：

```text
feat: 添加新的恢复策略
fix: 修复状态输出缺失验收项
docs: 完善安装说明
```

## 许可证与来源

Deadline-Carl 使用 [Apache License 2.0](LICENSE)。第三方来源和衍生说明见 [NOTICE](NOTICE)。

本项目基于 [repo-task-proof-loop](https://github.com/DenisSergeevitch/repo-task-proof-loop) 的规格、证据和独立验证工作流，并增加了 Windows PowerShell 监督器、时间压力调度、进程恢复和安装集成。
