/**
 * dsh-collab-mode —— 把 ZCode 侧那套「协作模式」搬到 DeepSeek Harness。
 *
 * 本插件提供三样东西（五个角色子智能体工具由本包的 bundle patch
 * `cordis.patch.yml` 里的五行 `@deepseek-ai/dsh-tool-subagent` 提供）：
 *
 *   1. 协作纪律系统提示段（`ctx.systemPrompt.section`），正文来自仓库 `content/collab-rules.md`。
 *   2. 改动前拦截 `tools/pre-execute`：本会话未声明生产文件累计到阈值 → deny，并列出文件名。
 *   3. 审计 `tools/post-execute`：每次工具调用追加一行 JSON 日志（ts/sid/tool/target/ok/latency）。
 *   4. 轮次结束告警 `agent/turn-stopping`：有未声明改动 → 通过 `agent.steer` 告警并列出文件名；否则静默。
 *
 * 钩子走 DSH 的代码级事件，不依赖 `@deepseek-ai/dsh-hooks-claude-code` 适配器，
 * 也不复用 ZCode 的 PowerShell 脚本（任务书第三节设计决策 1）。
 *
 * 本文件刻意零外部依赖：只用 node: 内置模块，因此在 `link:` 安装下也能正常解析，
 * 不需要在插件仓库里再装一份 `@deepseek-ai/*`。
 *
 * @module dsh-collab-mode
 */
import { randomUUID } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, parse, resolve } from 'node:path'
import { RULES_TEXT } from './generated-content.js'

export const name = 'collab-mode'
export const inject = ['tools', 'systemPrompt']

/** 简报文件名：与本仓库规则文本、ZCode 侧 `enforce-flow.ps1` 保持一致。 */
const BRIEF_MAIN = 'current-task.md'
const BRIEF_PREFIX = 'task-'
const BRIEF_SUFFIX = '.md'

/** 计入统计的工具：只有这两个有「目标文件」语义。 */
const WRITE_TOOLS = new Set(['edit', 'write'])

/** 拦截信息里最多列几个文件名，其余折成 (+N more)，避免拒绝信息过长。 */
const MAX_LISTED = 8

const DEFAULTS = {
  /** 改动前拦截总开关。 */
  gate: true,
  /** 审计日志总开关。 */
  audit: true,
  /** 轮次结束告警总开关。 */
  warnOnTurnEnd: true,
  /** 未声明生产文件累计到这个数就拦截／告警。 */
  declarationThreshold: 3,
  /** 系统提示段的名字，同层重名会抛错。 */
  rulesSection: 'collab-mode:rules',
  /** 系统提示段的排序位：400 = 在 persona prefix(0) 之后、PLAN_POLICY(500) 之前。 */
  rulesOrder: 400,
  /** 审计日志目录；默认 `$DSH_HOME/hooks`。 */
  logDir: undefined,
}

/* ────────────────────────── 配置 ────────────────────────── */

/** 校验并冻结配置。配置不合法直接抛错，不回退默认值 —— 静默降级比启动失败更难查。 */
function resolveConfig(raw) {
  if (raw === undefined || raw === null) return { ...DEFAULTS }
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error('collab-mode: config must be a mapping')
  }
  const cfg = { ...DEFAULTS, ...raw }
  for (const key of ['gate', 'audit', 'warnOnTurnEnd']) {
    if (typeof cfg[key] !== 'boolean') throw new Error(`collab-mode: \`${key}\` must be a boolean`)
  }
  if (!Number.isInteger(cfg.declarationThreshold) || cfg.declarationThreshold < 1) {
    throw new Error('collab-mode: `declarationThreshold` must be a positive integer')
  }
  if (typeof cfg.rulesSection !== 'string' || cfg.rulesSection === '') {
    throw new Error('collab-mode: `rulesSection` must be a non-empty string')
  }
  if (typeof cfg.rulesOrder !== 'number' || !Number.isFinite(cfg.rulesOrder)) {
    throw new Error('collab-mode: `rulesOrder` must be a finite number')
  }
  if (cfg.logDir !== undefined && (typeof cfg.logDir !== 'string' || cfg.logDir === '')) {
    throw new Error('collab-mode: `logDir` must be a non-empty string when set')
  }
  return cfg
}

/** `$DSH_HOME`（默认 `~/.dsh`）：与 DSH 自身解析 home 的方式保持一致。 */
function dshHome() {
  const fromEnv = process.env.DSH_HOME
  return typeof fromEnv === 'string' && fromEnv.trim() !== '' ? resolve(fromEnv) : join(homedir(), '.dsh')
}

/* ────────────────────────── 路径与简报 ────────────────────────── */

/**
 * 归一化成和 ZCode 侧同一种形式：绝对路径、反斜杠、去掉尾部分隔符、小写。
 * Windows 路径大小写不敏感，统一小写才能去重与比较。
 * @returns 归一化路径，无法解析时返回 null。
 */
function normalizePath(target, cwd) {
  if (typeof target !== 'string' || target.trim() === '') return null
  let abs
  try {
    abs = resolve(cwd ?? process.cwd(), target)
  } catch {
    return null
  }
  let out = abs.replace(/\//g, '\\')
  while (out.length > 3 && out.endsWith('\\')) out = out.slice(0, -1)
  return out.toLowerCase()
}

/**
 * 不计入统计的路径（与 ZCode 侧 enforce-flow.ps1 的豁免一致，另加 `.git/`）：
 *   - `$DSH_HOME` 治理树（规则、设置、会话、插件源）——本协作系统自己的配置树
 *   - 任何 `.work/` 下的文件（简报、报告、决策备忘录）
 *   - `.git/` 内部文件（提交信息临时文件、锁）
 */
function isExcluded(normPath, homeNorm) {
  if (normPath === null) return true
  if (/[\\/]\.work[\\/]/.test(normPath)) return true
  if (/[\\/]\.git[\\/]/.test(normPath)) return true
  if (homeNorm !== null && (normPath === homeNorm || normPath.startsWith(`${homeNorm}\\`))) return true
  return false
}

/**
 * 找简报文件：从起点目录逐级向上，第一个含 `current-task.md` 或 `task-*.md`
 * 的 `.work/` 目录即命中（与 ZCode 侧 Get-BriefFiles 同语义）。
 * @returns 命中目录下的简报文件绝对路径数组；没有则空数组。
 */
function briefFilesFrom(startDir) {
  if (typeof startDir !== 'string' || startDir === '') return []
  let probe
  try {
    probe = resolve(startDir)
  } catch {
    return []
  }
  for (;;) {
    const workDir = join(probe, '.work')
    if (existsSync(workDir)) {
      let entries = []
      try {
        entries = readdirSync(workDir)
      } catch {
        entries = []
      }
      const hits = entries.filter(
        (entry) => entry === BRIEF_MAIN || (entry.startsWith(BRIEF_PREFIX) && entry.endsWith(BRIEF_SUFFIX)),
      )
      if (hits.length > 0) return hits.map((entry) => join(workDir, entry))
    }
    const parent = dirname(probe)
    if (parent === probe) return []
    probe = parent
  }
}

/**
 * 简报集合 = 「会话工作目录树」∪「目标文件自己所在目录树」。
 * 文件可能合法地活在会话项目之外（例如用户级插件树），两棵树都查才不会误拦。
 */
function collectBriefs(cwd, targetPaths) {
  const out = []
  const seen = new Set()
  const roots = [cwd]
  for (const p of targetPaths) roots.push(dirname(p))
  for (const root of roots) {
    for (const file of briefFilesFrom(root)) {
      const key = file.toLowerCase()
      if (seen.has(key)) continue
      seen.add(key)
      out.push(file)
    }
  }
  return out
}

/**
 * 覆盖判定：取文件名（leaf）在简报全文里做**子串**匹配，命中即视为已声明。
 * 与 ZCode 侧 Test-Declared 一致（`-match` 本身大小写不敏感）。
 * @param cache - 同一次判定内的简报正文缓存，调用方每次判定新建。
 */
function isDeclared(normPath, briefs, cache) {
  const leaf = parse(normPath).base
  if (!leaf) return false
  const needle = leaf.toLowerCase()
  for (const file of briefs) {
    let text = cache.get(file)
    if (text === undefined) {
      try {
        text = readFileSync(file, 'utf8').toLowerCase()
      } catch {
        text = null
      }
      cache.set(file, text)
    }
    if (text !== null && text.includes(needle)) return true
  }
  return false
}

/** 未声明文件清单：已归一化路径 → 文件名，按 MAX_LISTED 截断成一段可读文本。 */
function listNames(paths) {
  const names = paths.map((p) => parse(p).base)
  const shown = names.slice(0, MAX_LISTED)
  const rest = names.length - shown.length
  return rest > 0 ? `${shown.join(', ')} (+${rest} more)` : shown.join(', ')
}

/* ────────────────────────── 会话状态 ────────────────────────── */

/** sessionId -> { seen, changed, warnedKeys }。会话级内存状态，进程重启即清空。 */
const states = new Map()

function sessionIdOf(agent) {
  const fromSession = agent?.session?.header?.id
  if (typeof fromSession === 'string' && fromSession !== '') return fromSession
  const fromAgent = agent?.id
  return typeof fromAgent === 'string' && fromAgent !== '' ? fromAgent : null
}

function cwdOf(agent) {
  const cwd = agent?.session?.header?.cwd
  return typeof cwd === 'string' && cwd !== '' ? cwd : process.cwd()
}

function stateFor(agent) {
  const id = sessionIdOf(agent)
  if (id === null) return null
  let state = states.get(id)
  if (state === undefined) {
    state = { seen: new Set(), changed: new Set(), warnedKeys: new Set() }
    states.set(id, state)
  }
  return state
}

/**
 * 只要已存在的状态，不因为一次读取就新建（否则空会话也会留状态）。
 * ⚠ 返回 `undefined` 表示「这个会话没有状态」——调用方必须判 undefined，
 * 不能判 null：`Map.get` 未命中给的是 undefined，把它当成 null 漏过去会在
 * `agent/turn-stopping` 里抛异常，直接把子智能体那一轮打成 error。
 */
function existingState(agent) {
  const id = sessionIdOf(agent)
  if (id === null) return undefined
  return states.get(id)
}

/* ────────────────────────── 消息与日志 ────────────────────────── */

/**
 * 构造一条插件来源的 user 消息。
 * 等价于 `createUserMessage`（`@deepseek-ai/dsh-llm`）：补 role、给一个新 id、冻结。
 * 这里自己构造是为了让本插件零外部依赖，字段与官方 helper 完全一致。
 */
function pluginMessage(text) {
  return Object.freeze({
    id: randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    source: { kind: 'plugin', plugin: 'collab-mode' },
  })
}

/** 会话 id 里不能出现在文件名中的字符一律替换（与 ZCode 侧同规则）。 */
function safeSessionId(sid) {
  const safe = String(sid).replace(/[^a-zA-Z0-9_-]/g, '_')
  return safe.length > 60 ? safe.slice(0, 60) : safe
}

/** 工具调用的「目标」：文件路径优先，其次命令，其次子智能体任务的描述。 */
function targetOf(exec) {
  const args = exec.arguments
  if (args === null || typeof args !== 'object') return ''
  if (typeof args.file_path === 'string') return args.file_path
  if (typeof args.path === 'string') return args.path
  if (typeof args.command === 'string') return args.command.length > 200 ? `${args.command.slice(0, 200)}...` : args.command
  if (typeof args.description === 'string') return args.description
  return ''
}

/* ────────────────────────── 插件本体 ────────────────────────── */

/**
 * @param ctx - 拥有这些注册的上下文（本插件挂在 Host 平面）。
 * @param rawConfig - bundle patch 里那一行的 `config`。
 */
export function apply(ctx, rawConfig) {
  const cfg = resolveConfig(rawConfig)
  const homeNorm = normalizePath(dshHome())
  const logDir = cfg.logDir ?? join(dshHome(), 'hooks')
  /** callId -> 起始时间戳，用来算耗时（工具事件不带耗时字段）。 */
  const startedAt = new Map()

  ctx.logger?.info(
    `collab-mode: active — gate=${cfg.gate} audit=${cfg.audit} warnOnTurnEnd=${cfg.warnOnTurnEnd} ` +
      `threshold=${cfg.declarationThreshold} logDir=${logDir}`,
  )

  /* ---- 1. 协作纪律提示段 ---- */
  ctx.systemPrompt.section({
    name: cfg.rulesSection,
    order: cfg.rulesOrder,
    text: RULES_TEXT,
  })

  /* ---- 2. 审计日志 ---- */
  let auditDirReady = false

  /** 往 `<logDir>/activity-<sid>.log` 追加一行 JSON；失败静默，绝不打断工具链。 */
  function appendAudit(sid, record) {
    if (!cfg.audit) return
    try {
      if (!auditDirReady) {
        mkdirSync(logDir, { recursive: true })
        auditDirReady = true
      }
      const line = `${JSON.stringify(record)}\n`
      appendFileSync(join(logDir, `activity-${safeSessionId(sid)}.log`), line, { encoding: 'utf8' })
    } catch {
      /* 审计失败不影响工具执行 */
    }
  }

  /* ---- 3. 改动前拦截 ---- */
  ctx.on('tools/pre-execute', async (exec, next) => {
    startedAt.set(exec.callId, Date.now())
    if (startedAt.size > 5000) startedAt.clear()

    if (!cfg.gate) return next()
    if (!WRITE_TOOLS.has(exec.name)) return next()

    const state = stateFor(exec.agent)
    if (state === null) return next()

    const args = exec.arguments
    const rawTarget = args !== null && typeof args === 'object' && typeof args.file_path === 'string' ? args.file_path : ''
    if (rawTarget.trim() === '') return next()

    const cwd = cwdOf(exec.agent)
    const target = normalizePath(rawTarget, cwd)
    if (isExcluded(target, homeNorm)) return next()

    state.seen.add(target)

    const briefs = collectBriefs(cwd, [target])
    const cache = new Map()
    if (isDeclared(target, briefs, cache)) return next()

    const undeclared = [...state.seen].filter((p) => !isDeclared(p, briefs, cache))
    if (undeclared.length < cfg.declarationThreshold) return next()

    return {
      kind: 'deny',
      reason:
        `FLOW_GATE: 本会话已改动 ${undeclared.length} 个没有任何任务简报声明的生产文件，本次 ${exec.name} 被拒绝。` +
        `未声明：${listNames(undeclared)} 。` +
        `按协作纪律，累计改动 ≥${cfg.declarationThreshold} 个文件必须走 B 类流程：` +
        `写 .work/task-<关键词>.md（并行会话各用各的文件）列出你要动的文件，再用 executor 执行、code-reviewer 审查。` +
        `把这些文件名登记进简报后即可继续。` +
        `[cwd=${cwd} briefs=${briefs.length} threshold=${cfg.declarationThreshold}]`,
    }
  })

  /* ---- 4. 审计：每次工具调用一行 ---- */
  ctx.on('tools/post-execute', async (exec, result, next) => {
    const started = startedAt.get(exec.callId)
    startedAt.delete(exec.callId)
    const latency = started === undefined ? 0 : Date.now() - started
    const sid = sessionIdOf(exec.agent) ?? 'unknown'
    const ok = result?.isError !== true

    appendAudit(sid, {
      ts: new Date().toISOString(),
      sid: safeSessionId(sid),
      tool: exec.name,
      target: targetOf(exec),
      ok,
      latency,
    })

    // 成功的写操作登记进「本会话已改动」，供轮次结束告警使用。
    if (ok && WRITE_TOOLS.has(exec.name)) {
      const state = stateFor(exec.agent)
      const args = exec.arguments
      const rawTarget =
        args !== null && typeof args === 'object' && typeof args.file_path === 'string' ? args.file_path : ''
      if (state !== null && rawTarget.trim() !== '') {
        const target = normalizePath(rawTarget, cwdOf(exec.agent))
        if (!isExcluded(target, homeNorm)) state.changed.add(target)
      }
    }

    return next()
  })

  /* ---- 5. 轮次结束告警 ---- */
  ctx.on('agent/turn-stopping', async ({ agent, turn }) => {
    if (!cfg.warnOnTurnEnd) return

    const state = existingState(agent)
    if (state === undefined || state.changed.size === 0) return

    const cwd = cwdOf(agent)
    const briefs = collectBriefs(cwd, state.changed)
    const cache = new Map()
    const undeclared = [...state.changed].filter((p) => !isDeclared(p, briefs, cache))
    if (undeclared.length < cfg.declarationThreshold) return

    // 同一组未声明文件只告警一次：状态没变化就不再重复，避免每轮结束都刷屏。
    const key = [...undeclared].sort().join('|')
    if (state.warnedKeys.has(key)) return
    state.warnedKeys.add(key)

    const text =
      `FLOW_DRIFT: 本会话已改动 ${undeclared.length} 个没有任何任务简报声明的生产文件，本轮结束前请先补简报。` +
      `未声明：${listNames(undeclared)} 。` +
      `把这些文件名登记进 .work/task-<关键词>.md（或 .work/current-task.md）后即可继续；` +
      `若这几个文件本来就该由 executor 执行，请走 B 类流程。` +
      `[turn=${turn} cwd=${cwd} briefs=${briefs.length}]`

    appendAudit(sessionIdOf(agent) ?? 'unknown', {
      ts: new Date().toISOString(),
      sid: safeSessionId(sessionIdOf(agent) ?? 'unknown'),
      tool: 'collab-mode:turn-warning',
      target: listNames(undeclared),
      ok: false,
      latency: 0,
    })

    // steer = 拦下这次收尾：驱动会重读收件箱，多走一步让模型处理这条告警。
    agent.steer(pluginMessage(text))
  })
}
