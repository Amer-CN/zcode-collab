#!/usr/bin/env node
/**
 * 构建脚本：把 `content/` 下的单一来源内容内联成两份产物。
 *
 *   content/collab-rules.md   -> lib/generated-content.js  （系统提示段正文）
 *   content/roles/<角色>.md    -> cordis.patch.yml          （每个角色一行的 persona）
 *
 * 改完 `content/` 必须重新运行 `node build.mjs`（等价于 `npm run build`）。
 * 两份产物都是生成物，禁止手改 —— 手改会在下一次构建时被覆盖，并让 ZCode 侧
 * 的同步失去意义（任务书设计决策 3：内容单一来源）。
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))

/** 读一份内容文件，统一换行并保证结尾恰好一个换行。 */
function readContent(rel) {
  const text = readFileSync(join(root, rel), 'utf8').replace(/\r\n/g, '\n').trimEnd()
  return text.endsWith('\n') ? text : `${text}\n`
}

/**
 * 只读角色要从子智能体工具集里摘掉的写操作工具名。
 *
 * ⚠ 这些名字必须真实存在：`@deepseek-ai/dsh-tools` 的 `restrict()` 遇到未知工具名
 * 会直接抛错，子智能体就起不来。名单按本机 DSH 0.1.5-rc.1（web profile）实测的
 * 可见工具集确定，不含 Windows 上被 disabled 的 `bash`。
 *
 * ⚠ `subagent` 刻意不在名单里：本机预设把那一行配成 `modelSelectionSettings: true`，
 * 该工具会被注册进**每个 agent 自己的层**，而 `restrict()` 只认继承来的名字、
 * 明确拒绝「scope-local 名字」（见 dsh-tools 的 view()：restrictableNames 只收
 * global + 祖先层）。实测把 `subagent` 放进去会让每次委派都抛
 * `tools.restrict() names unknown global tool "subagent"`。
 * 后果：只读角色自己派不了孙代以外的写操作不受影响，但**孙代**若由该子智能体
 * 经预设的 `subagent` 工具派出，不会继承这里的 toolFilter，因此不受只读约束。
 * 详见 README「已知边界」。
 */
const MUTATING_TOOLS = [
  'write',
  'edit',
  'pwsh',
  'job_kill',
  'create_goal',
  'update_goal',
  'cordis_define',
  'cordis_run',
  'cordis_stop',
  'cordis_undefine',
  'exit_plan_mode',
  'send_message',
  'interrupt_agent',
  'workflow',
  'ralph',
  'subagent_fork',
  'todo_write',
]

/**
 * 五个角色。`readonly: true` 的角色通过 `toolFilter.deny` 摘掉全部写操作工具，
 * 权限由 DSH 的工具注册表强制（不是写在提示词里求模型自觉）。
 *
 * `maxDepth: 1`：角色子智能体自己不能再往下派子智能体（子智能体继承父会话预设，
 * 不设上限就会递归）。
 *
 * `backgroundMode: one-shot`：默认前台等待并直接返回结果 —— 走流程时主智能体
 * 需要拿到执行/审查结论才能裁决。
 */
const ROLES = [
  { id: 'executor', tool: 'executor', file: 'content/roles/executor.md', readonly: false },
  { id: 'code-reviewer', tool: 'code-reviewer', file: 'content/roles/code-reviewer.md', readonly: true },
  { id: 'researcher', tool: 'researcher', file: 'content/roles/researcher.md', readonly: true },
  { id: 'advisor', tool: 'advisor', file: 'content/roles/advisor.md', readonly: true },
  { id: 'vision-reader', tool: 'vision-reader', file: 'content/roles/vision-reader.md', readonly: true },
]

/** 把一个多行文本渲染成 YAML 的 `|-` 块标量（保留换行、不保留结尾换行）。 */
function blockScalar(text, indent) {
  const pad = ' '.repeat(indent)
  const lines = text.replace(/\r\n/g, '\n').replace(/\s+$/, '').split('\n')
  const body = lines.map((line) => (line === '' ? '' : pad + line)).join('\n')
  return `|-\n${body}`
}

/* ---------- 产物一：lib/generated-content.js ---------- */

const rules = readContent('content/collab-rules.md')
const generatedJs = `// 本文件由 build.mjs 从 content/collab-rules.md 生成，请勿手改。
// 重新生成：node build.mjs
export const RULES_TEXT = ${JSON.stringify(rules)}
`
writeFileSync(join(root, 'lib/generated-content.js'), generatedJs, 'utf8')

/* ---------- 产物二：cordis.patch.yml ---------- */

const parts = []
parts.push(`# dsh-collab-mode bundle patch —— 本文件由 build.mjs 生成，请勿手改。
# 重新生成：node build.mjs
#
# 这一层挂在 Host 平面（profile root → dsh-base → dsh-web-app → 本 bundle →
# profile 自己的 cordis.patch.yml → home 补丁 → --patch 覆盖层），因此五个角色
# 工具对每个会话可见，不依赖会话选了哪个 agent preset。
#
# 覆盖某一行的配置：在更靠后的层（例如 ~/.dsh/profiles/web/cordis.patch.yml）
# 按 id 覆盖即可，注意 DSH 的 patch 语义是「整行替换 config」，被覆盖的行要
# 重述它拥有的每一个键。给某个角色换模型：
#
#   - id: collab-researcher
#     config:
#       provider: spawn
#       toolName: researcher
#       backgroundMode: one-shot
#       maxDepth: 1
#       agentOptions:
#         provider: <供应商>
#         model: <模型 id>
#       toolFilter:
#         deny: [...]
#       persona: |-
#         ...
#
# 只改模型不想重述 persona 时，把本文件对应的 persona 块原样抄回去即可。

- insert:
    # 提示段与三个钩子的宿主行。
    - id: collab-mode
      name: 'dsh-collab-mode'
`)

for (const role of ROLES) {
  const persona = readContent(role.file)
  parts.push(`
    # 角色：${role.tool}${role.readonly ? '（只读）' : '（可写）'}
    - id: collab-${role.id}
      name: '@deepseek-ai/dsh-tool-subagent'
      config:
        provider: spawn
        toolName: ${role.tool}
        backgroundMode: one-shot
        maxDepth: 1
        persona: ${blockScalar(persona, 10)}
`)
  if (role.readonly) {
    parts.push(`        toolFilter:
          deny:
`)
    for (const name of MUTATING_TOOLS) parts.push(`            - ${name}\n`)
  }
}

writeFileSync(join(root, 'cordis.patch.yml'), parts.join(''), 'utf8')

console.log(
  `dsh-collab-mode: generated lib/generated-content.js (${rules.length} chars of rules) ` +
    `and cordis.patch.yml (${ROLES.length} role rows, ${MUTATING_TOOLS.length} denied tools per read-only role)`,
)
