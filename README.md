# zcode-collab

ZCode 多模型子智能体协作模式：顶级模型编排 → 便宜模型执行 → 跨厂商模型独立审查。

> **模型完全自主**：本框架不绑定任何模型。安装时 AI 自动填一个可用的，之后你爱换哪个换哪个。唯一的经验建议：审查者别和执行者用同一个模型（自审等于没审）。

## 这是什么

一套在 ZCode 里落地的多智能体分工：你描述需求 → 主模型出方案、写任务简报 → **executor** 按简报干活 → **code-reviewer**（另一家厂商的模型）独立验收 → 主模型裁决。附 researcher 调研、vision-reader 识图、advisor 三人圆桌、双钢人决策前置。

核心价值两条：**独立验证**（干活的不验收，验收的和干活的不是一家）+ **省 token**（执行环节交给便宜模型）。

## 安装（拎包入住）

1. 下载本仓库（或 `git clone https://github.com/Amer-CN/zcode-collab.git`），把 `zcode-collab/` 目录放到 `~/.agents/skills/`（或 `~/.zcode/skills/`）下。
2. 对你的 ZCode 说：**「用 zcode-collab Skill，把多模型协作模式给我装上。」**
3. 重启 ZCode（或新开会话），生效。

AI 会自动：备份老配置 → 读你本机可用模型 → 统一填入 → 写规则文件和 agent 文件 → 读回校验。全程不需要你碰设置、不需要理解原理。

查版本：`zcode-collab/VERSION`。升级：拉新版覆盖本目录即可。

## 日常用法

- 粘贴现成方案 → 自动执行 + 汇报（审查交给给你方案的 AI）
- 大白话描述需求 → 自动走完整四步
- 纯讨论、小改动 → 直接做
- 说「圆桌」「大家怎么看」→ 三家顾问同时出意见
- 决策类问题（该不该做 / 选哪个）→ 自动走双钢人简版结论
- 跑偏了 → 说「回滚到基线提交」；小事别啰嗦 → 说「直接做」

## 目录结构

```
zcode-collab/
├── SKILL.md                  # Skill 主体：部署流程 + 日常答疑 + 双钢人决策流程
├── VERSION                   # 版本号（当前 1.0.0）
├── LICENSE                   # MIT
└── references/
    ├── global-agents.md      # 全局协作规则全文
    ├── agent-executor.md     # 施工队提示词
    ├── agent-code-reviewer.md# 监理提示词（只读）
    ├── agent-researcher.md   # 调研员提示词
    ├── agent-vision-reader.md# 识图员提示词
    ├── agent-advisor.md      # 圆桌三席共用模板
    └── decision-full.md      # 决策完整版 12 段模板
```

## 来源与许可

源自 3 周实战迭代的个人配置（2026-08 部署，经 22 文件重构与多起真实事故验证）。MIT License。决策方法参考开源项目 dual-steelman-decision（MIT）。
