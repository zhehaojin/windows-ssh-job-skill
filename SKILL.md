---
name: windows-ssh-jobs
description: 通过已配置的 SSH 连接 Windows 服务器，提交 Python 后台作业、检查状态、传输文件，并将准备好的结果提交到 GitHub 新分支。用于 Windows SSH 作业流程。
---

# Windows SSH jobs

优先调用 `scripts/remote.ps1`，不为每次任务重写 SSH 连接。配置只保存在本地 `server.local.json`，不能提交；公开示例在 `server.example.json`。

## 首次配置

读取已有配置；若缺失，让用户一次性指定服务器、账户、项目目录和本地密码文件位置。只问路径，不在聊天中索取密码。用 `scripts/configure.ps1` 保存路径，`scripts/setup.ps1` 编译 askpass。已有有效配置直接复用。密码由子进程读取，不进入 skill、命令行或日志。

在首次人工 SSH 连接中核实主机指纹；脚本保持严格主机校验。远程默认解释器来自项目 `.deployment/environment.json`，其他环境通过 `-RemotePython` 指定实际 Python。

## 执行

以下 `$helper` 为本 skill 的 `scripts/remote.ps1` 绝对路径：

```powershell
& $helper -Action Info -RemotePython $python
& $helper -Action Launch -ArgumentsFile $argumentsJson -RemotePython $python
& $helper -Action Status -LaunchRecord $record -RemotePython $python
& $helper -Action Status -RunDirectory $run -RemotePython $python
& $helper -Action RunPython -ScriptPath $script -RemotePython $python
& $helper -Action Pull -RemotePath $remoteFile -LocalPath $localFile
```

启动前核对用户目标、仓库约定、解释器、参数与输出路径，不修改现有作业的源码/环境/输出。Launch 参数文件为 Python 参数字符串数组，不含解释器。它创建独立提交记录，以 Windows breakaway 方式启动；必须用新的 SSH 请求检查记录和进程，不能仅凭 PID 宣称后台运行或计算成功。网络结果不明时先查状态，避免重复提交。

Status 自动识别有 `RUN_DIRECTORY`、`launcher_status.json`、`results/status.json` 的作业；其他程序根据自身日志/状态文件判断，必要时用 RunPython 查询。进程存活不等于有进展；进程结束也不等于成功。保留全部失败记录，不用测试结果回选模型。

## 结果与 Git 回传

仅在用户授权上传时使用 `scripts/publish-results.ps1`。先按 [references/git-return.md](references/git-return.md) 准备并检查发布目录，在独立 clone 中创建新的结果分支，保留现有分支和工作区。该脚本不安装工具、不创建仓库，也不把远程 SSH 密码当作 GitHub 凭据。

连接、环境与后台细节按需读 [references/operations.md](references/operations.md)。参数和手动安装示例见 [README.md](README.md)。普通状态查询不读取全部参考资料。

此 skill 只复用流程，不扩大用户请求的执行或上传范围。遇到认证失败重试一次后报告具体原因；不绕过主机校验、不终止无关任务，不将沙箱限制误报为服务器失联。
