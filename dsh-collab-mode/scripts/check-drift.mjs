#!/usr/bin/env node
/**
 * 防漂移自检：断言「内容单一来源」在机制上成立。
 *
 * 为什么需要它：v0.3.0 之前，角色清单在 `build.mjs`、正文在 `content/roles/*.md`、
 * ZCode skill 侧另有一份手写搬运的副本 —— 手工同步两份文本，丢了规则也没人发现。
 * 本脚本把「三处角色数必须相等」「manifest 声明的文件必须存在且非空」
 * 「生成物不得被手工编辑」变成可执行的断言。
 *
 * 运行：node scripts/check-drift.mjs      （退出码非 0 表示有漂移）
 */
import { existsSync, readFileSync, statSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))

let passed = 0
const failures = []

function check(name, condition, detail) {
  if (condition) {
    passed += 1
    console.log(`  PASS  ${name}`)
  } else {
    failures.push(name)
    console.log(`  FAIL  ${name}${detail === undefined ? '' : ` — ${detail}`}`)
  }
}

console.log('dsh-collab-mode 防漂移自检\n')

/* ---- 1. manifest 本身 ---- */

const manifestPath = join(root, 'content', 'manifest.json')
check('content/manifest.json 存在', existsSync(manifestPath), manifestPath)

let manifest
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
} catch (error) {
  check('content/manifest.json 可解析', false, String(error && error.message))
  console.log(`\n结果：${passed} 项通过，${failures.length} 项失败`)
  console.log(`失败项：${failures.join(' / ')}`)
  process.exitCode = 1
  process.exit(1)
}
check('content/manifest.json 可解析', true)
check('manifest.version 非空', typeof manifest.version === 'string' && manifest.version !== '', String(manifest.version))
check('manifest.rules.file 已声明', typeof manifest.rules?.file === 'string' && manifest.rules.file !== '')
check('manifest.roles 是非空数组', Array.isArray(manifest.roles) && manifest.roles.length > 0, String(manifest.roles?.length))

/* ---- 2. 每个 roles[].file 存在且非空 ---- */

console.log('\n[1] manifest 声明的文件存在且非空')
const roleFiles = []
for (const role of manifest.roles) {
  const abs = join(root, 'content', role.file)
  const exists = existsSync(abs)
  check(`roles[${role.key}].file 存在（${role.file}）`, exists, abs)
  if (!exists) continue
  const size = statSync(abs).size
  check(`roles[${role.key}].file 非空（${size} 字节）`, size > 0, `${size} 字节`)
  roleFiles.push(abs)
}
{
  const rulesAbs = join(root, 'content', manifest.rules.file)
  check(`rules.file 存在（${manifest.rules.file}）`, existsSync(rulesAbs), rulesAbs)
  if (existsSync(rulesAbs)) {
    const size = statSync(rulesAbs).size
    check(`rules.file 非空（${size} 字节）`, size > 0, `${size} 字节`)
  }
}

/* ---- 3. 三处角色数必须相等 ---- */

console.log('\n[2] 三处角色数相等：manifest == content/roles/*.md == 生成物 ROLES == 面板 ROLE_ROWS')

const manifestKeys = manifest.roles.map((r) => r.key).sort()

// content/roles/ 目录里实际存在的 .md 文件数
const { readdirSync } = await import('node:fs')
const onDisk = readdirSync(join(root, 'content', 'roles'))
  .filter((f) => f.endsWith('.md'))
  .map((f) => f.replace(/\.md$/, ''))
  .sort()
check('content/roles/*.md 数量 == manifest.roles 数量', onDisk.length === manifestKeys.length, `磁盘 ${onDisk.length} vs manifest ${manifestKeys.length}`)
check('content/roles/*.md 文件名集合 == manifest keys', JSON.stringify(onDisk) === JSON.stringify(manifestKeys), `磁盘 ${onDisk.join(',')} vs manifest ${manifestKeys.join(',')}`)

// 生成物 lib/generated-content.js 的 ROLES
const generated = await import(new URL('../lib/generated-content.js', import.meta.url).href)
const generatedKeys = generated.ROLES.map((r) => r.key).sort()
check('生成物 ROLES 数量 == manifest.roles 数量', generatedKeys.length === manifestKeys.length, `生成物 ${generatedKeys.length} vs manifest ${manifestKeys.length}`)
check('生成物 ROLES keys == manifest keys', JSON.stringify(generatedKeys) === JSON.stringify(manifestKeys), `生成物 ${generatedKeys.join(',')}`)

// 面板 ROLE_ROWS（lib/client.js 里那张表）
const clientSource = readFileSync(join(root, 'lib', 'client.js'), 'utf8')
const roleRowsBlock = clientSource.match(/const ROLE_ROWS = \[([\s\S]*?)\n\s*\]/)
check('lib/client.js 里能找到 ROLE_ROWS 表', roleRowsBlock !== null, 'not found')
if (roleRowsBlock !== null) {
  const clientKeys = [...roleRowsBlock[1].matchAll(/key:\s*'([^']+)'/g)].map((m) => m[1]).sort()
  check('面板 ROLE_ROWS 数量 == manifest.roles 数量', clientKeys.length === manifestKeys.length, `面板 ${clientKeys.length} vs manifest ${manifestKeys.length}`)
  check('面板 ROLE_ROWS keys == manifest keys', JSON.stringify(clientKeys) === JSON.stringify(manifestKeys), `面板 ${clientKeys.join(',')}`)
}

/* ---- 4. 生成物不得被手工编辑（用「重新构建后字节一致」判定） ---- */

console.log('\n[3] 生成物与 content/ 同步（重新构建后字节一致）')

const generatedPath = join(root, 'lib', 'generated-content.js')
const patchPath = join(root, 'cordis.patch.yml')
const before = {
  generated: createHash('sha256').update(readFileSync(generatedPath)).digest('hex'),
  patch: createHash('sha256').update(readFileSync(patchPath)).digest('hex'),
}

// 用一个子进程跑构建，避免本进程的模块缓存影响判定
const { spawnSync } = await import('node:child_process')
const built = spawnSync(process.execPath, [join(root, 'build.mjs')], { cwd: root, encoding: 'utf8' })
check('node build.mjs 退出码为 0', built.status === 0, `status=${built.status} ${built.stderr ?? ''}`)

const after = {
  generated: createHash('sha256').update(readFileSync(generatedPath)).digest('hex'),
  patch: createHash('sha256').update(readFileSync(patchPath)).digest('hex'),
}
check('lib/generated-content.js 与 content/ 一致（未被手工编辑）', before.generated === after.generated, `${before.generated.slice(0, 16)} -> ${after.generated.slice(0, 16)}`)
check('cordis.patch.yml 与 content/ 一致（未被手工编辑）', before.patch === after.patch, `${before.patch.slice(0, 16)} -> ${after.patch.slice(0, 16)}`)

/* ---- 5. 生成物文件头必须带「请勿手改」告示 ---- */

console.log('\n[4] 生成物文件头带告示')
for (const [label, path] of [
  ['lib/generated-content.js', generatedPath],
  ['cordis.patch.yml', patchPath],
]) {
  const head = readFileSync(path, 'utf8').split('\n').slice(0, 3).join('\n')
  check(`${label} 文件头含「请勿手改」`, head.includes('请勿手改'), head.split('\n')[0])
}

/* ---- 6. ZCode 侧平台信息齐备 ---- */

console.log('\n[5] 每个角色的 zcode 块字段齐备')
for (const role of manifest.roles) {
  const z = role.zcode
  check(`roles[${role.key}].zcode.description 非空`, typeof z?.description === 'string' && z.description !== '')
  check(`roles[${role.key}].zcode.color 非空`, typeof z?.color === 'string' && z.color !== '')
  check(`roles[${role.key}].zcode.tools 是非空数组`, Array.isArray(z?.tools) && z.tools.length > 0, String(z?.tools?.length))
  check(`roles[${role.key}].zcode.injectAgentsMd 是布尔`, typeof z?.injectAgentsMd === 'boolean', String(z?.injectAgentsMd))
}

console.log(`\n结果：${passed} 项通过，${failures.length} 项失败`)
if (failures.length > 0) {
  console.log(`失败项：${failures.join(' / ')}`)
  process.exitCode = 1
}
