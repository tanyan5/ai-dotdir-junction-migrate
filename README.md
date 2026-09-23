# ai-dotdir-junction-migrate

一个 **Windows 专用** 的 **C 盘瘦身工具**：把各种 AI 编程工具（Cursor、Qoder、Trae、WebStorm、Codex、CodeGeeX、Tabnine、JetBrains 全家桶……）占用巨大的数据目录，通过 **NTFS junction（目录连接点）** 迁移到其它固定磁盘（如 D 盘），C 盘原路径依旧可用，工具无感。

> 本技能遵循开放的 **Agent Skills 标准**（一个文件夹 + `SKILL.md` + `scripts/`），因此在 **WorkBuddy、Cursor、Codex CLI、Claude Code、Gemini CLI、Qoder、Trae、Windsurf** 等支持该标准的工具里都能直接使用——装一次，多处可用。安装后只需用自然语言说出需求，AI 助手会自动加载本技能并运行脚本，无需手动敲命令。
>
> ⚠️ **仅限 Windows**（Windows 10/11 + NTFS）。脚本依赖 PowerShell 5.1、`robocopy` 和 NTFS junction，macOS / Linux 上无法运行。

---

## 功能

| 能力 | 说明 |
|---|---|
| **迁移** | 把大目录复制到目标盘 → 校验一致 → 清空 C 盘原目录 → 建立 junction。全程幂等，失败绝不删源数据，可安全重跑。 |
| **回退** | 删除 junction（只删链接、不动数据）→ 把数据拷回 C 盘原路径 → 校验。数据永不丢失。 |
| **自动发现** | `-Scan` 自动列出本机所有"跨盘 junction 迁移"，一个月后想还原也不用记路径。 |
| **批量迁移** | `migrate_all_ai_dirs.ps1` 内置 14 个常见 AI 工具目录，可交互勾选（`1,3,5-8` / `all`）或 `-All` 一键迁移。 |
| **清理残留** | 检测已卸载应用留下的数据目录，可一键送进回收站。 |

**覆盖的目录**（示例）：`.qoder`、`.qoder-cn`、`.trae`、`.trae-cn`、`.tabnine`、`.WebStorm`、`.codex`、`.codegeex`、`.dsh`、`Roaming\Trae`、`Roaming\Qoder`、`Local\JetBrains`、`Roaming\Cursor\User\globalStorage` 等。

---

## 安装

技能目录结构（一个文件夹 + `SKILL.md` + `scripts/`）：

```
ai-dotdir-junction-migrate\
├── SKILL.md
├── README.md
└── scripts\
    ├── cursor_migrate_globalstorage.ps1   # Cursor 专用（globalStorage）
    ├── junction_migrate.ps1               # 通用单目录迁移
    ├── junction_rollback.ps1              # 回退 / 扫描 / 清理遗留备份
    └── migrate_all_ai_dirs.ps1            # 批量迁移封装器
```

### 方式一：通用安装（推荐，一次装好所有支持 Agent Skills 的工具）

```powershell
npx skills add tanyan5/ai-dotdir-junction-migrate -g
```

它会装到通用目录 `%USERPROFILE%\.agents\skills\`，**Cursor、Codex CLI、Claude Code、Gemini CLI、Qoder、Trae、Windsurf 等都会读取这个目录**，无需逐个安装。之后可用 `npx skills ls -g` 查看、`npx skills update` 更新。

### 方式二：手动放入某个工具的技能目录

克隆后把整个文件夹放进目标工具的技能目录即可（各工具只读自己那份）：

```powershell
git clone https://github.com/tanyan5/ai-dotdir-junction-migrate.git `
  "$env:USERPROFILE\.workbuddy\skills\ai-dotdir-junction-migrate"
```

| 工具 | 技能目录 |
|---|---|
| 通用（被多数工具共享） | `%USERPROFILE%\.agents\skills\` |
| WorkBuddy | `%USERPROFILE%\.workbuddy\skills\` |
| Cursor | `%USERPROFILE%\.cursor\skills\` |
| Codex CLI | `%USERPROFILE%\.codex\skills\` |
| Claude Code | `%USERPROFILE%\.claude\skills\` |

> Cursor / Codex 只在**启动时**扫描技能目录，装完记得重启对应工具。

### 怎么用

装好后直接用自然语言提出需求即可，AI 助手会自动加载本技能并运行脚本：

> 「帮我把 Cursor 的数据迁到 D 盘」
> 「把 .qoder-cn 软链到 D 盘」
> 「列出我迁移过哪些目录」

### 斜杠快捷命令 `/dotdir-migrate`（可选）

技能本身已经能用 `/` + 技能名调起——Cursor 的 `/` 菜单支持搜索，打 `mig` 也能筛到 `ai-dotdir-junction-migrate`。但如果你想要一条更短、含义明确的固定命令，可以额外放一个**别名技能**：Agent Skills 标准**没有 aliases 字段**，**文件夹名就是斜杠命令名**，所以别名必须是独立的一份。

把下面这份内容存成 `%USERPROFILE%\.cursor\skills\dotdir-migrate\SKILL.md`（注意文件夹名必须和 `name` 完全一致）：

```markdown
---
name: dotdir-migrate
description: Shortcut alias for ai-dotdir-junction-migrate — migrate AI-tool dot-dirs off C: to another fixed disk via NTFS junctions (Windows only).
disable-model-invocation: true
---
# /dotdir-migrate
读取并遵循 `ai-dotdir-junction-migrate` 技能的 SKILL.md，按其
扫描 → 勾选 → 迁移 → 校验 流程执行，不要凭记忆自行发挥。
```

要点：

- `name` **必须**等于所在文件夹名，且只能用**小写字母、数字、连字符**（中文、下划线、空格都不行）。
- `disable-model-invocation: true` 让它变成**纯斜杠命令**：不自动加载、不占用上下文，只有你打 `/dotdir-migrate` 时才注入。
- 别名正文只写"指针"，**不要在别名里复制一遍实现**，否则两份内容迟早漂移。
- 各工具的别名文件位置：Cursor `~/.cursor/skills/<别名>/SKILL.md`、Claude Code `~/.claude/commands/<别名>.md`、Codex CLI `~/.codex/prompts/<别名>.md`、Gemini CLI `~/.gemini/commands/<别名>.toml`。
- ⚠️ 别把**同一个别名名**同时放进工具会扫描的两个目录（例如 `~/.cursor/skills/` 和 `~/.agents/skills/`），否则 `/` 菜单会出现两条重复项。
- 别名是**本机用户级**配置，**不会**随 `npx skills add` 一起安装，换机器要单独建一次。
- Cursor 小技巧：`/` 选中技能后按 `Alt+Enter`（Windows）可让它在整个会话常驻（custom mode）；`/loop` 可按间隔重复运行。

---

## 手动使用（可选）

迁移单个目录：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\junction_migrate.ps1 `
  -SourceDir "C:\Users\<你>\.qoder-cn" -TargetDir "D:\tool_tem\qoder-cn\.qoder-cn"
```

批量交互式迁移：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\migrate_all_ai_dirs.ps1
```

列出所有历史迁移（只读，不改动）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\junction_rollback.ps1 -Scan
```

回退某个迁移（保留 D 盘备份）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\junction_rollback.ps1 -SourceDir "C:\Users\<你>\.WebStorm"
```

---

## 安全须知（重要）

- **绝不要用 `rmdir /s` 或 `Remove-Item -Recurse` 删除 junction**——那会顺着链接把另一块盘上的**真实数据一起删掉**。删链接只用**非递归**的方式（二选一）：
  ```powershell
  [IO.Directory]::Delete("<junction 路径>", $false)   # 纯 PowerShell，只删重解析点
  ```
  或者直接用本仓库的 `junction_rollback.ps1`（会删链接 → 拷回数据 → 校验，一条龙）。
- 目标盘必须是**固定内置磁盘**，不要用 U 盘/可移动磁盘（拔盘即断链）。
- 迁移前**完全退出**目标应用（含托盘图标），否则文件被占用。
- 不要对 `.ssh` 这类安全敏感目录做 junction。
- 迁移后确认应用能正常启动，再考虑清理备份。

---

## 环境要求

- Windows 10/11
- PowerShell 5.1（系统自带）
- 目标盘为 NTFS
- 脚本为纯 ASCII，避免 PowerShell 5.1 编码解析问题

---

## 实现要点

- 复制与校验统一用 `robocopy`（长路径安全），**不用** `Get-ChildItem` 计数比对——PS 5.1 枚举会静默跳过 >260 字符的深层路径，导致误报。
- 清理 C 盘残留用 `robocopy /MIR` 空目录镜像（比 `Remove-Item -Recurse` 更能处理超长路径）。
- 排除 IDE 运行时锁文件（`.port`/`.lock`/`.pid`）——它们会被应用自动重建，无需迁移。

## License

未指定。若需开源协议（如 MIT / Apache-2.0），可自行添加 `LICENSE` 文件。
