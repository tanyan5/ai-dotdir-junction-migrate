# ai-dotdir-junction-migrate

一个 Windows 专用的 **C 盘瘦身工具**：把各种 AI 编程工具（Cursor、Qoder、Trae、WebStorm、Codex、CodeGeeX、Tabnine、JetBrains 全家桶……）占用巨大的数据目录，通过 **NTFS junction（目录连接点）** 迁移到其它固定磁盘（如 D 盘），C 盘原路径依旧可用，工具无感。

> 这是一个 [WorkBuddy](https://www.workbuddy.cn) 技能（Skill）。安装后，直接用自然语言让 AI 助手帮你迁移即可，无需手动敲命令。

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

把本仓库克隆/下载后，将整个文件夹放到 WorkBuddy 的用户技能目录：

```
%USERPROFILE%\.workbuddy\skills\ai-dotdir-junction-migrate\
├── SKILL.md
├── README.md
└── scripts\
    ├── cursor_migrate_globalstorage.ps1   # Cursor 专用（globalStorage）
    ├── junction_migrate.ps1               # 通用单目录迁移
    ├── junction_rollback.ps1              # 回退 / 扫描 / 清理遗留备份
    └── migrate_all_ai_dirs.ps1            # 批量迁移封装器
```

PowerShell 一键安装：

```powershell
git clone https://github.com/tanyan5/ai-dotdir-junction-migrate.git `
  "$env:USERPROFILE\.workbuddy\skills\ai-dotdir-junction-migrate"
```

装好后，直接对你的 WorkBuddy 说：「帮我把 Cursor 的数据迁到 D 盘」「把 .qoder-cn 软链到 D 盘」「列出我迁移过哪些目录」，助手会自动加载本技能并运行脚本。

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

- **绝不要用 `rmdir /s` 或 `Remove-Item -Recurse` 删除 junction**——那会顺着链接把另一块盘上的**真实数据一起删掉**。删链接只用 `cmd /c rmdir "<路径>"`（不带 `/s`），或直接用本仓库的 `junction_rollback.ps1`。
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
