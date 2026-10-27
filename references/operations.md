# 连接、环境和后台执行

首次配置服务器、用户名、项目目录和本地密码文件位置。后续读取 `server.local.json`；缺失或路径失效时只核对必要信息，不反复索要密码。不要把实际配置、凭据、主机密钥或认证日志放入 Git。

SSH/SCP 子进程使用本地 askpass helper 和严格主机校验。手动第一次连接核实指纹后，脚本可自动认证。未知或变化的主机密钥需要核实，不能用关闭校验的方式绕过。

远程脚本通过 UTF-8 stdin 送入 Python；PowerShell bootstrap 使用 UTF-16LE 的 `-EncodedCommand`，参数通过 JSON 数据传递。默认解释器来自项目部署记录，其他环境使用 `-RemotePython`，不要假设远程具有本机的包。

Windows SSH 后台任务使用：

```text
CREATE_BREAKAWAY_FROM_JOB | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
```

配合独立 stdout/stderr 日志、DEVNULL stdin 和关闭无关继承句柄。系统拒绝 breakaway 时会报错；不要去掉标志后宣称已经独立后台运行。

Launch 返回后新开一条 SSH 请求，使用 LaunchRecord 核对 native PID、创建标识和日志。虚拟环境入口可能再启动其他 Python，所以提交 PID 与程序自己的 launcher/worker PID 可以不同。旧记录没有创建标识时 PID 匹配只是未验证信息，不能把 PID 复用当任务存活。

状态查询使用任务记录和原生 WinAPI，避免为简单查询重复做可能很慢的 WMI 全进程扫描。状态 JSON 正在写入时可能短暂不可解析，先重试，不要据此判断失败。SSH 超时仅说明本次操作结果未知；启动超时先查状态，不直接重试提交。

helper 的超时清理只作用于自己创建的本地 SSH/SCP 进程树，不终止远程计算或其他连接。后台程序最终状态由应用自身记录；原生进程结束并不足以证明结果完整。
