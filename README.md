<p align="center"><img src="https://capsule-render.vercel.app/api?type=waving&color=0:1F4E79,100:0D2137&height=170&section=header&text=zcode-collab&fontSize=64&fontColor=ffffff&animation=fadeIn" width="100%"></p>

<div align="center">

#### ZCode 多模型子智能体协作模式：主模型编排 → executor 执行 → 跨厂商独立审查

**三句话装好 · AI 全自动部署 · 模型随你换 · 内化双钢人决策**

[![Typing SVG](https://readme-typing-svg.demolab.com?font=Fira+Code&size=20&pause=1200&color=1F4E79&center=true&vCenter=true&width=620&lines=%E4%B8%89%E5%8F%A5%E8%AF%9D%E8%A3%85%E5%8D%8F%E4%BD%9C%E6%A8%A1%E5%BC%8F%EF%BC%8C%E6%8B%8E%E5%8C%85%E5%85%A5%E4%BD%8F;%E6%89%A7%E8%A1%8C%E5%AE%A1%E6%9F%A5%E5%88%86%E5%AE%B6%EF%BC%8C%E7%9B%B2%E5%8C%BA%E4%B8%8D%E9%87%8D%E5%90%88;%E6%A8%A1%E5%9E%8B%E9%9A%8F%E4%BD%A0%E6%8D%A2%EF%BC%8C%E5%AE%A1%E6%9F%A5%E4%B8%8D%E5%AE%A1%E8%87%AA%E5%B7%B1%E4%BA%BA)](https://git.io/typing-svg)

[![Version](https://img.shields.io/badge/Version-v1.1.5-1F4E79?style=for-the-badge)](#-版本历史)
[![Subagents](https://img.shields.io/badge/子智能体-7个-3B82F6?style=for-the-badge)](#-能力矩阵)
[![License](https://img.shields.io/badge/License-MIT-10B981?style=for-the-badge)](./zcode-collab/LICENSE)
[![AgentSkills](https://img.shields.io/badge/AgentSkills-Standard-8B5CF6?style=for-the-badge)](https://agentskills.io)

</div>

---

你有顶级模型的订阅，但不想让最贵的模型干最费 token 的活？**zcode-collab
把多智能体分工装进 ZCode**：你描述需求，主模型出方案、写简报，便宜的模型
（executor）照简报施工，另一家厂商的模型（code-reviewer）独立验收，主模型
裁决。附调研员、识图员、三人圆桌顾问和双钢人决策前置——一个 Skill 全带上。

遵循 [Agent Skills](https://agentskills.io) 开放标准。**模型完全自主**：安装时
AI 只会填一个"确认可用"的模型，之后每个岗位用什么、什么时候换，全是你自己的事。

## 🍼 小白三分钟上手（第一次接触 Agent Skill？从这里开始）

**你不需要会编程。** 只需要一样东西：一个支持 Agent Skills 的 AI 工具
（ZCode、Claude Code、Codex 等 40+ 都行）。

**第一步：装。** 把这句话原样发给你的 AI 工具：

> 帮我安装这个 skill：https://github.com/Amer-CN/zcode-collab

**第二步：等 AI 干完。** 它会自动：备份老配置 → 读你本机有哪些模型 →
统一填一个能用的 → 写规则文件和 7 个子智能体 → 读回校验 → 告诉你怎么换模型。

**第三步：重启生效。** 重启 ZCode（或新开会话），说人话就能用：

> 帮我看看这个项目的 README 写了什么

就完了。不需要懂原理，不需要碰设置界面，不需要选模型。

## ✨ 能力矩阵

| 能力 | 说明 | 对应文件 |
|------|------|----------|
| 🧭 **模式判断** | A 外部方案 / B 完整四步 / C 直接答疑 / D 小改直做，自动分类 | zcode-collab/references/global-agents.md |
| 📋 **简报制度** | 基线哈希 + 允许/禁止文件 + 可验证验收标准，跑砸随时回滚 | 同上 |
| 🔨 **executor** | 施工队：照简报干活，禁顺手镀金，不做设计不审查 | zcode-collab/references/agent-executor.md |
| 🔍 **code-reviewer** | 监理：只认仓库实际改动，只判"够不够"，驳回须证据 | zcode-collab/references/agent-code-reviewer.md |
| 📚 **researcher** | 只读调研：本地代码库 + 互联网 + GitHub（有 MCP 就带） | zcode-collab/references/agent-researcher.md |
| 👁️ **vision-reader** | 识图员：主模型不支持看图时给它当眼睛（可选） | zcode-collab/references/agent-vision-reader.md |
| 🗣️ **advisor ×3** | 圆桌顾问：三家不同厂商同时出意见，主模型综合 | zcode-collab/references/agent-advisor.md |
| ⚖️ **双钢人决策** | "该不该做/选哪个"先走简版论证（crux + 反转条件 + 承诺窗口，≤300 字） | zcode-collab/SKILL.md + references/decision-full.md |

## 🚀 它怎么工作

```
你说需求 ── 主模型判断 A/B/C/D 模式
   │
   ├─ B 完整流程：出方案（3 行白话）→ 写简报（基线+范围+验收）
   │              → executor 施工 → code-reviewer 查仓库实际改动
   │              → 主模型裁决（驳回最多 2 轮）
   ├─ A 现成方案：跳过规划，执行完提交推送，审查交给给你方案的 AI
   ├─ C/D 讨论、小改：主模型直接做
   └─ 决策类问题：双钢人简版（≤300 字：crux/反转条件/承诺窗口）
```

**命脉只有一条**：干活的模型不参与验收，验收的模型和它不同厂商——
盲区不重合，错误互相抓住。其余所有搭配都随你。

## 📦 安装方式

### 方式一：Agent Skills 环境（ZCode / Claude Code / Codex）

```bash
git clone https://github.com/Amer-CN/zcode-collab.git
# 复制到你的技能目录：
cp -r zcode-collab/ ~/.agents/skills/zcode-collab/
# 或 Claude Code: ~/.claude/skills/
```

然后对你的 AI 说：**「用 zcode-collab Skill，把多模型协作模式给我装上。」**
装完重启 ZCode（或新开会话）即生效。

### 方式二：任意 LLM 作为系统知识

把 `zcode-collab/SKILL.md` + `references/global-agents.md` 全文塞进 system
prompt，agent 提示词按需取用。

## 🗂️ 仓库结构

<details>
<summary><b>目录树</b>（点击展开）</summary>

```
zcode-collab/
├── SKILL.md                      # Skill 主体：AI 自助安装 6 步 + 日常答疑 + 双钢人决策
├── VERSION                       # 版本号（当前 1.1.5）
├── LICENSE                       # MIT
└── references/
    ├── global-agents.md          # 全局协作规则全文（A/B/C/D 模式判断+四步流程+汇报纪律）
    ├── agent-executor.md         # executor 提示词 + frontmatter 模板
    ├── agent-code-reviewer.md    # code-reviewer 提示词 + frontmatter 模板
    ├── agent-researcher.md       # researcher 提示词 + frontmatter 模板
    ├── agent-vision-reader.md    # vision-reader 提示词 + frontmatter 模板
    ├── agent-advisor.md          # 圆桌三席共用提示词模板
    └── decision-full.md          # 双钢人完整版 12 段模板（重大决策才用）
```

</details>

## ⚙️ 模型怎么配（你说了算）

安装时 AI 只做一件事：从你本机**确认可用**的模型里选一个，7 个岗位统一填上。
之后怎么分，是你的自由——只有两条经验建议（不是规矩）：

| 建议 | 原因 |
|------|------|
| 审查者别和执行者用同一个模型 | 同一份权重自审，盲区 100% 重合，等于没审 |
| 圆桌三家（advisor-A/B/C）分属不同厂商 | 配成同一家，圆桌变复读机 |

除此之外：想让审查用旗舰、执行用便宜货——随你；想全用最贵的——也随你。
换模型就是设置界面里点一下下拉框，新会话生效。

## 📜 版本历史

<details>
<summary><b>当前 v1.1.5</b>（2026-09-11）· v1.0.0 → v1.1.5 完整明细点击展开</summary>

| 版本 | 内容 |
|------|------|
| v1.0.0（2026-09-06） | 首版：A/B/C/D 模式判断 + 简报制度 + 7 子智能体（executor/code-reviewer/researcher/vision-reader/advisor×3）+ 双钢人决策内化 + AI 自助安装流程（备份→探测模型→统一填入→读回校验，含字节账校验与备份恢复路径） |
| v1.1.0（2026-09-09） | 满血版：hooks/ 四钩子进包（enforce-flow/PostToolUse/stop-enforce/SessionStart，含安装合并指引）+ scripts/version_check.py 主动版本检查（super-official-writer 同口径：永不阻塞/只读/behind 提示）+ references 同步简报路径参数化与漂移守卫规则 + Agent Skills 触发描述补强 |
| v1.1.1（2026-09-09） | 钩子修复（并发会话实战暴露）：stop-enforce 简报识别从「只认 current-task.md」扩为「current-task.md + 全部 task-*.md，取并集覆盖」——修复「按钩子指示用 task-关键词.md 命名反而永远过不了校验」；文件计数排除 `.git/` 内部文件（提交信息临时文件不再误计为生产文件）。五轮回归通过（受影响会话放行、真阳性仍拦截） |
| v1.1.2（2026-09-10） | 钩子三处设计修正（跨窗口实战反馈）：① 计数排除一次性诊断目录（~/.zcode/tmp、系统 TEMP、node_modules/__pycache__ 等构建目录）——`~/.zcode/tmp` 下的一次性脚本不再被误计为生产文件；② 拦截文案列出**未申报的具体文件名**（Undeclared: a.cs, b.cs …），不再只给一个数字；③ 引入**真实派发信号**——post-tool-audit 记录 Agent 调用的 subagent_type，stop-enforce 见到 executor/code-reviewer 实际派发即放行（不再仅靠简报声明）；路径分隔符正反斜杠均已兼容 |
| v1.1.3（2026-09-10） | enforce-flow（PreToolUse）三处同族缺陷修复，口径与 stop-enforce 统一：① 简报识别扩为 current-task.md + 全部 task-*.md（原先只有 current-task.md 能重置，按 AGENTS.md 规定的 task-<关键词>.md 命名反而永远重置不了、第 3 个文件必拦，还会逼模型覆盖 canonical 简报槽位造成数据丢失）；② 计数排除 .git/（提交信息临时文件不再误计）；③ 门禁判定从「写过简报＝整会话永久豁免」改为**逐文件覆盖判定**——未申报文件累计 3 个即拦、拦时列名，把文件补进简报后立即放行（自愈），消除「一次重置＝永久放行」。24 项回归全过 |
| v1.1.4（2026-09-10） | 计数范围同源：`~/.zcode` 配置树在 stop-enforce 中也豁免（与 enforce-flow 一致）——协作系统自身的规则/子智能体/钩子改动不再被误计为「项目生产文件」。**代价已注明**：治理工具自身的改动不设机器门禁，依靠简报与审查纪律。两钩子的排除清单至此完全一致 |
| v1.1.5（2026-09-11） | enforce-flow「真实调用与手动运行结果不一致」修复：① **拦截文案附诊断串** `[cwd=… sid=… key=state-….json briefs=N]`（此前无法从外部反推钩子实际使用的 projectDir 与 state-key，排障只能靠猜）；② **字段拼写容错**——sessionId / session_id 两种拼写都接受（若真实载荷是 camelCase 而钩子只读 snake_case，同一载荷会落到不同 state-key，正是「真实=拦、手动=放」的成因）；cwd / project_dir / projectDir 同理，且缺 cwd 时回退到目标文件所在目录；③ **规范化统一**——路径统一 `GetFullPath`→反斜杠→去尾斜杠→小写，state-key 与简报查找共用同一函数；④ **双树简报查找**——被改文件可能在会话项目之外（如用户级插件目录），项目树与目标文件树两处都找简报（并集）。另：post-tool-audit 耗时字段容错（durationMs/duration_ms/duration/elapsedMs）。12 项回归全过 |

</details>

## 🙏 许可与致谢

- 双钢人决策方法参考开源项目 [dual-steelman-decision](https://github.com/Kujojolyne1992/dual-steelman-decision-skill)（MIT）
- 本仓库代码与配置 MIT License，各文件许可以 [LICENSE](./zcode-collab/LICENSE) 为准

<div align="center">

---

Made by [@Amer-CN](https://github.com/Amer-CN)

*配置来自 3 周真实项目实战迭代。仅供参考，按你自己的工作流调整。*

</div>
