# Windows SSH Job Skill

通过 SSH 远程连接 Windows 电脑，流程化提交 Python 作业、检查状态、取回结果，并通过 Git 返回到新的结果分支。可作为 Codex skill 使用，也可直接调用 PowerShell 脚本。

仓库只包含通用源码与示例。真实服务器配置、密码文件、编译后的认证 helper、作业输出和个人实验记录均不进入 Git。

## 准备

- 本机为 Windows，具备 PowerShell 5.1 或 7、OpenSSH 客户端，以及已安装的 .NET Framework C# 编译器。Git 回传另需本机 Git 和对应仓库写权限。
- 远程 Windows 已启用 SSH 服务，网络可达；可使用 Tailscale 地址。Python 环境和项目依赖由项目自身管理。
- 先人工连接一次 `ssh remote-user@windows-host.example`，核实主机指纹。脚本不自动接受未知或变化的主机密钥。

## 安装为 skill

```powershell
git clone https://github.com/zhehaojin/windows-ssh-job-skill.git "$env:USERPROFILE\.codex\skills\windows-ssh-jobs"
Set-Location "$env:USERPROFILE\.codex\skills\windows-ssh-jobs"
.\scripts\setup.ps1
```

`setup.ps1` 仅将相邻 C# 源码编译成本机 askpass helper，不安装软件。保留在其他目录也可直接运行脚本。

首次让用户把密码存为本机自行选择位置的 UTF-8 单行文件，再配置服务器与文件位置：

```powershell
.\scripts\configure.ps1 `
  -ServerHost 'windows-host.example' `
  -ServerUser 'remote-user' `
  -Repo 'D:\work\project' `
  -CredentialDirectory 'C:\private'
```

目录模式默认读取已有 `ssh-password.txt`，也可使用 `-CredentialFile 'C:\private\my-server.txt'`。配置脚本只记录路径，不读取、复制或移动密码。后续直接复用，换位置时再执行一次配置即可。请勿将密码发到聊天或写进参数文件。

`server.example.json` 仅用于展示字段；真正连接使用被 Git 忽略的 `server.local.json`。

## 连接与提交作业

uv 等环境可显式指定远程 Python；已有完整部署记录的项目也可省略 `-RemotePython`：

```powershell
$python = 'D:\work\project\.venv\Scripts\python.exe'
.\scripts\remote.ps1 -Action Info -RemotePython $python
```

省略解释器时，项目 `.deployment/environment.json` 须包含 `python`、`lock_sha256`，且与该项目的 `requirements-windows.lock.txt` 一致。只要该记录存在，Launch 就会校验它；显式传入 `-RemotePython` 也须匹配记录，不能绕过已有环境锁。

准备 Python 参数数组；其中的脚本须已位于远程项目中：

```powershell
@('-u', '-B', 'train.py', '--epochs', '100') |
  ConvertTo-Json | Set-Content -Encoding UTF8 '.\arguments.json'

$job = .\scripts\remote.ps1 -Action Launch `
  -ArgumentsFile '.\arguments.json' -RemotePython $python | ConvertFrom-Json

# 新 SSH 请求核对独立后台进程和日志。
.\scripts\remote.ps1 -Action Status -LaunchRecord $job.launch_record -RemotePython $python
```

Launch 在项目 `.local/ssh-jobs/` 创建独立提交记录和日志，使用 Windows breakaway 启动。如果系统拒绝脱离 SSH 作业组，会明确失败，不静默降级。应用自身仍须为每次训练选择新的输出目录；helper 不会替任意程序改写输出参数。

支持 `RUN_DIRECTORY` 和双状态文件约定的程序，可直接按 run 查询：

```powershell
.\scripts\remote.ps1 -Action Status -RunDirectory 'D:\work\project\runs\run-001' -RemotePython $python
```

普通程序通过提交记录查看进程和日志；退出码、实验完整性及科学结果仍以程序自己的状态文件为准。`safe_to_collect` 只表示可收集终态记录，不保证实验全部成功。

## 传输与 Git 回传

将需要的结果拉回已创建的本地目录：

```powershell
.\scripts\remote.ps1 -Action Pull `
  -RemotePath 'D:\work\project\runs\run-001\summary.csv' `
  -LocalPath 'C:\results\summary.csv'
```

传目录时显式加 `-Recursive`。Push 可将明确指定的本地文件传到远程；不要覆盖运行中的源码和输出。`RunPython -ScriptPath` 可执行已准备好的远程操作脚本。

先准备只含可发布内容的本地目录，核对数值、失败记录和敏感信息，再推送到已有 GitHub 仓库的新分支：

```powershell
.\scripts\publish-results.ps1 `
  -RepositoryUrl 'https://github.com/OWNER/REPOSITORY.git' `
  -Branch 'results/run-001' `
  -ResultsDirectory 'C:\prepared-results\run-001' `
  -WorkDirectory 'C:\result-publications' `
  -DryRun
```

去掉 `-DryRun` 即实际推送。脚本使用本机已有 Git 身份和凭据，在独立 clone 中操作；不会切换当前工作区、覆盖已有分支或写入全局 Git 配置。新分支采用“预期远端引用不存在”的精确 lease，仅允许创建，不允许更新已存在的分支。

敏感/环境文件会排除并计数；符号链接或大文件会中止发布，需要先整理发布目录。大体积 checkpoint 和数据库适合另行通过 Release 附件分发；本脚本不把完整原始运行目录自动提交到 Git。详细发布约定见 [references/git-return.md](references/git-return.md)。

## 在 Codex 中使用

```text
$windows-ssh-jobs 帮我在已配置的 Windows 服务器提交这个 Python 任务，并在完成后把准备好的结果推送到新分支。
```

skill 按需加载说明和脚本，减少重复摸索；模型执行任务仍会使用 token。未来定时检查或自动上传需要单独设置调度；仓库本身不会创建后台定时器。

## 验证

在 Windows 上运行 Python 标准库回归测试：

```powershell
python -B -m unittest discover -s tests -v
```

PowerShell 离线测试位于 `tests/`，使用临时配置、假凭据和本地模拟 Git/SSH，不会向真实服务器提交任务或上传结果。
