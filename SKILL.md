---
name: ai-dotdir-junction-migrate
description: "WINDOWS ONLY (NTFS). Migrate bulky AI-tool data directories (Cursor globalStorage, .qoder/.qoder-cn, .trae/.trae-cn, .tabnine, .WebStorm, .codex, .codegeex, .dsh, JetBrains caches, etc.) off the C: system drive to another fixed disk via NTFS junctions to reclaim C: space. Use when a user on Windows reports C: is nearly full and an AI IDE/tool is a large consumer, or asks to migrate/relocate/symlink/soft-link (junction) any AI-tool dot-dir to D: or another drive. Do NOT use on macOS/Linux: the bundled scripts are PowerShell + robocopy + NTFS junctions and cannot run there. Trigger keywords: Cursor, globalStorage, state.vscdb, qoder, trae, webstorm, codex, C盘满, 软连接, 迁移, junction, 释放C盘, Windows."
agent_created: true
---

# AI-Tool Dot-Dirs -> D: via NTFS Junction

## Platform (read first)
**Windows only (Windows 10/11, NTFS).** The bundled scripts are PowerShell 5.1 +
`robocopy` + NTFS junctions — none of that exists on macOS/Linux, so on those
platforms the skill may load but every script will fail. Do not trigger or offer
this skill on macOS/Linux; instead tell the user it is Windows-only and that
macOS needs a different approach (e.g. a real symlink / bind mount), which this
skill does NOT cover.

This skill follows the open **Agent Skills** standard (a folder with `SKILL.md` +
`scripts/`), so the same copy works in WorkBuddy, Cursor, Codex CLI, Claude Code,
Gemini CLI, Qoder, Trae, etc. — but the *runtime requirement* above still applies
to all of them: Windows only.

## When to use
- User reports the C: drive is running out of space and an AI coding tool (Cursor, Qoder, Trae, WebStorm, Codex, CodeGeeX, Tabnine, JetBrains, etc.) is a large consumer.
- User asks to move/relocate an AI tool's bulky data (Cursor `globalStorage`, `state.vscdb`, `.qoder`, `.trae`, `.WebStorm`, etc.) to D: or another fixed disk.
- User mentions "soft link / symlink / junction / 软连接" for any AI-tool directory.
- Covers all of: `.qoder`, `.qoder-cn`, `.trae`, `.trae-cn`, `.tabnine`, `.WebStorm`, `.codex`, `.codegeex`, `.dsh`, `Roaming\Trae`, `Roaming\Qoder`, `Local\JetBrains`, `Roaming\Cursor\User\globalStorage`, etc. The generic `junction_migrate.ps1` and the `migrate_all_ai_dirs.ps1` bundle cover these too.

## What it does
The migration keeps Cursor working through its original path while the real data
lives on another disk:
1. Copies `%APPDATA%\Cursor\User\globalStorage` to the target disk with `robocopy`
   (long-path + read-only safe).
2. Verifies the copy is in sync with `robocopy /L` (list-only). Never verify by
   comparing `Get-ChildItem` file counts/bytes: PS 5.1 enumeration silently
   drops long paths (>260 chars) and access-denied subtrees, undercounting the
   source while robocopy copies the real content -> bogus mismatches.
3. Wipes the C: leftover with `robocopy /MIR` (handles >260-char paths that
   PowerShell `Remove-Item -Recurse` cannot delete).
4. Creates an NTFS junction so `%APPDATA%\Cursor\User\globalStorage` points to the
   new location.
5. Verifies files are readable through the original C: path.

## Transient lock files (all bundled scripts)
JetBrains/VS Code-family IDEs keep lock files such as `system\.port` open with
exclusive access; robocopy cannot read them (error 1920). They are recreated by
the app on startup, so `junction_migrate.ps1` EXCLUDES `.port`, `.lock`, `.pid`,
`*.lock`, `*.pid` from the copy, from verification counts, and from the /MIR
wipe, and retries the copy once after 3 s. If the app was not fully quit, other
files may still be locked -> quit the app and re-run (idempotent).

## Prerequisites
- Fully quit Cursor, including the tray icon. The script aborts if a Cursor
  process is still running.
- The target disk MUST be a FIXED internal disk (not a USB stick / removable
  drive). A junction on removable media breaks when unplugged.

## How to run
Bundled script: `scripts/cursor_migrate_globalstorage.ps1`
Default target: `D:\CursorData\globalStorage`. Override with `-TargetPath`.

```powershell
# Default destination
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/cursor_migrate_globalstorage.ps1"

# Custom destination (recommended: point teammates at their own disk)
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/cursor_migrate_globalstorage.ps1" -TargetPath "E:\CursorData\globalStorage"
```

Any failure aborts WITHOUT deleting the C: source, so it is always safe to re-run.
If the migration was already done, the script detects the existing junction and
returns cleanly (idempotent).

Error handling: the scripts never call `exit` — they `throw` instead. An `exit`
inside a script invoked with `&` propagates to, and terminates, the CALLER (this
used to kill agent-driven runs and lose all their output). `throw` is catchable,
so wrap calls in `try/catch` when driving the scripts programmatically; running a
script with `powershell -File` still yields exit code 1 on failure.

## Safety notes (must tell the user)
- After migration, NEVER delete the junction with `rmdir /s` or
  `Remove-Item -Recurse` — that would erase the REAL data on D:.
- To remove a junction link safely in one line (pure PowerShell, no cmd.exe):
  `[IO.Directory]::Delete("<junction path>", $false)` — non-recursive, so it
  deletes only the reparse point and never descends into the target.
- Rollback is a dedicated script (see below), NOT a manual command.
- The scripts are pure ASCII (no Chinese in code) to avoid PowerShell 5.1 reading
  UTF-8-as-GBK parse errors.
- No script depends on `cmd.exe`: junctions are created with
  `New-Item -ItemType Junction` and removed with the non-recursive .NET delete
  above. So the whole flow also works in environments where cmd is blocked.

## Rollback (undo a migration)
Bundled script: `scripts/junction_rollback.ps1`. It is SAFE BY DESIGN:
1. Refuses to run unless the source path is an actual junction (ReparsePoint) —
   it never touches a real directory.
2. Removes ONLY the link with a non-recursive .NET delete
   (`[IO.Directory]::Delete($src, $false)`), which never descends into the target
   and therefore never deletes the data on the other disk. No `cmd.exe` needed.
3. Copies the data from the target BACK to the original path with robocopy (so the
   source is never lost), then verifies it is readable as a real directory.
4. If `-DeleteTarget` is passed, the D: backup is wiped too; otherwise it is kept
   as a free safety copy.

```powershell
# List EVERY migration you have ever done (no mutation) - use this a month later
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/junction_rollback.ps1" -Scan
# Undo .WebStorm migration, keep the D: backup copy
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/junction_rollback.ps1" -SourceDir "C:\Users\hello\.WebStorm"
# Undo AND remove the D: copy (use only after confirming the app works from C:)
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/junction_rollback.ps1" -SourceDir "C:\Users\hello\.WebStorm" -DeleteTarget
# ALREADY restored (C: is a real dir) but the D: backup lingers? Remove only the
# redundant D: copy (type the source path when prompted; C: never touched):
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/junction_rollback.ps1" -SourceDir "C:\Users\hello\.WebStorm" -TargetDir "D:\tool_tem\WebStorm\.WebStorm" -DeleteTarget
```

SAFETY: running rollback on an already-restored path does NOT touch the D: backup
by itself - it prints "NOT A JUNCTION ... Nothing to roll back" and returns. The
D: copy is only removed when you explicitly request `-DeleteTarget` AND the source
is still a junction (normal undo), OR with `-DeleteTarget -TargetDir` on a restored
path (leftover cleanup, with a type-to-confirm prompt).

`-Scan` finds every junction whose target is on a different disk (home scanned 1
level deep; Roaming / LocalAppData 3 levels deep, so nested links like
`Roaming\Cursor\User\globalStorage` are found; PS 5.1 does not descend into
junctions, so no loops) and prints `Source -> Target` for each, so you never
need to remember which dirs were migrated. From `migrate_all_ai_dirs.ps1` you can
also run `restore` interactively or `-Restore -Items "3,5"` (those list only the
bundled items; `-Scan` covers arbitrary migrations too).

PS 5.1 pitfall (bit us twice): always wrap collection-returning function calls in
`@()` at the call site - single-element arrays unwrap to scalars and `.Count`
becomes `$null`, so `-eq 0` / `-lt` checks silently misbehave. Do NOT also use
`return ,$arr` inside the function; combined they double-wrap and elements print
as `System.Object[]`.

From `migrate_all_ai_dirs.ps1` you can also roll back interactively (`restore 3,5`)
or in one shot (`-Restore -Items "3,5"`). Both only act on already-migrated
(junction) items and confirm with a `YES` prompt before doing anything.

## What is NOT migrated
Only `globalStorage` is moved. `CachedData` (extension / model cache, ~500 MB)
can be deleted separately while Cursor is closed and will be re-downloaded on
demand:
`Remove-Item "$env:APPDATA\Cursor\CachedData\*" -Recurse -Force`

## Generic tool for ANY directory (incl. other AI tools)
The same junction-migration pattern works for ANY bulky directory — not just
Cursor. A generic, parameterized version is bundled as
`scripts/junction_migrate.ps1`. Use it for other AI IDE dot-dirs such as
`.qoder`, `.trae`, `.tabnine`, `.WebStorm`, etc.

```powershell
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/junction_migrate.ps1" `
  -SourceDir "C:\Users\hello\.qoder-cn" -TargetDir "D:\AIData\qoder-cn"
```

### One-shot migration of all AI tool dirs
`scripts/migrate_all_ai_dirs.ps1` bundles the common set (home dot-dirs
`.qoder-cn .qoder .WebStorm .trae .trae-cn .tabnine` + AppData caches
`Roaming\Trae`, `Roaming\Trae CN`, `Roaming\Qoder`, `Local\JetBrains`) into one
run. Target layout: `D:\tool_tem\<appname>\<original-name>` (e.g.
`D:\tool_tem\qoder\.qoder`, `D:\tool_tem\Trae\Trae`). It checks for running
editors, verifies free space, prints the plan, then migrates each via the
generic script. Re-run is idempotent (completed dirs are skipped).
Cursor's `globalStorage` is migrated separately and is intentionally excluded
here to avoid disturbing that existing junction.

```powershell
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1"
# or choose another root disk:
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1" -TargetRoot "E:\tool_tem"
```

### Selecting which items to migrate (interactive or pre-set)
The `migrate_all_ai_dirs.ps1` script supports choosing a subset at runtime:
- **Interactive (default):** without `-Items`/`-All`, it prints a numbered list
  (with each item's size and `[done]` if already migrated), then prompts you to
  type a selection. Enter `1,3,5-8` (ranges allowed), `all`, or `q` to quit.
- **Pre-set (non-interactive):** pass `-Items` with indices and/or directory
  names (with or without the leading dot), e.g. `-Items "1,3,7-10"` or
  `-Items "qoder-cn,trae"`. Invalid/empty selections abort safely.
- **All at once:** `-All` migrates every candidate without prompting.

In the interactive prompt you can also issue two management commands (type them
instead of a migrate selection):
- `delete 4,7,8` — send the C: leftovers of **UNINSTALLED** apps (the script
  marks these `[app-NOT-installed]`) straight to the Recycle Bin. Requires typing
  `YES` to confirm. This is how you reclaim space from apps you no longer have.
- `restore 3,5` — undo a migration (remove the junction, copy data back to C:),
  only for already-migrated `[done]` items. Requires typing `YES` to confirm.

```powershell
# Interactive: you pick items from the numbered list
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1"
# Pick by index (note: already-migrated items are auto-skipped -> safe to include)
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1" -Items "1,3,7-10"
# Pick by directory name
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1" -Items "qoder-cn,trae"
# Non-interactive rollback of specific items (only already-migrated ones)
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/migrate_all_ai_dirs.ps1" -Restore -Items "3,5"
```

Rules of thumb for choosing what to migrate:
- Migrate only directories that are BIG (hundreds of MB+). Tiny dirs (<10 MB) are
  not worth the junction overhead and risk.
- The owning application must be FULLY closed during migration (incl. tray icons),
  or the source files are locked.
- Do NOT junction security-sensitive dirs like `.ssh` (zero size benefit, and SSH
  clients check ACLs — keep it on C:).
- The target disk MUST be fixed/internal (not a USB stick).
- Always verify the app still works after migrating before deleting the junction.
- The same "do not rmdir /s the junction" warning applies to every junction.

## Shortcut: a short slash alias (e.g. `/mig`)
Agents on the Agent Skills standard let you type `/` in chat and search skills by
name, so `/ai-dotdir-junction-migrate` already invokes this skill. For a shorter
trigger, add a tiny **alias skill**: a folder whose NAME is the shortcut, holding
only a pointer back here.

```markdown
<!-- ~/.cursor/skills/mig/SKILL.md  — folder name == frontmatter `name` == the slash command -->
---
name: mig
description: Shortcut alias for ai-dotdir-junction-migrate (Windows C: space reclaim via junctions).
disable-model-invocation: true   # behaves like a slash command: never auto-loaded, costs no context
---
# /mig
Read and follow the `ai-dotdir-junction-migrate` SKILL.md, then execute its
scan -> pick -> migrate -> verify workflow. Never improvise from memory.
```

Rules that bite if ignored:
- `name` MUST equal the parent folder name, and may contain only lowercase
  letters, digits and hyphens — no Chinese, no underscores, no spaces.
- `disable-model-invocation: true` is what makes it a pure command (only loads
  when you type `/mig`); drop it and the alias competes for automatic matches.
- Per-tool path for the alias file: Cursor `~/.cursor/skills/<alias>/SKILL.md`
  (or `~/.agents/skills/<alias>/`), Claude Code `~/.claude/commands/<alias>.md`,
  Codex CLI `~/.codex/prompts/<alias>.md`, Gemini CLI
  `~/.gemini/commands/<alias>.toml`.
- Do NOT place the same alias name in two directories the SAME tool scans
  (e.g. `~/.cursor/skills/` and `~/.agents/skills/`) — you get two duplicate
  entries in the `/` menu.
- Cursor tips: `Alt+Enter` (Windows) on a `/`-selected skill turns it into a
  sticky custom mode for the session; `/loop` can re-run a skill on an interval.
