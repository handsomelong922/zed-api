# zed-api

把 Zed 托管的模型转成本地 OpenAI / Anthropic 接口，让 **Codex、Claude Code、OpenCode** 直接连接使用。

三种协议（Responses / Chat Completions / Messages）都支持流式和工具调用，自带多账号调度、额度查看和中文 Web 管理页。

> 原生运行默认只监听 `127.0.0.1:8001`。Docker 镜像针对 1Panel / VPS 做了单端口适配，只需要映射容器端口 `8001`。

## 效果

Claude Code：

![Claude Code](docs/claude-code.png)

Codex 桌面端（5.6 Sol，极高档位）：

![Codex Desktop](docs/codex-desktop.png)

## 能做什么

- **Codex**：原生 `/v1/responses`，reasoning、工具调用历史都完整透传。`/v1/models` 同时给出 OpenAI 和 Codex Desktop 两种格式，新版桌面端拿来就能用。
- **Claude Code**：`/v1/messages`，顶层 system、内容块、缓存标记、工具结果都按 Anthropic 语义处理。
- **OpenCode**：`/v1/chat/completions`，切模型、切思考档位最方便。
- **多账号**：健康账号优先，认证失败、限流、网络错误分别冷却，挂了自动换号，换完记住。
- **管理页**：每个账号的套餐、到期时间、额度、模型探测结果一目了然，可以单个或全部做健康检查。
- **Web API Key**：管理页可直接设置全局模型 API 密钥，立即生效并持久化到 `/data/settings.json`。

## 模型与思考档位

| 模型 ID | 上游 | 说明 |
| --- | --- | --- |
| `gpt-5.6` | `gpt-5.6-sol` | 别名，方便配置 |
| `gpt-5.6-sol` / `-terra` / `-luna` | 同名 | GPT-5.6 三个变体 |
| `claude-sonnet-5` | 同名 | Claude Sonnet 5 |

GPT-5.6 思考档位：`none / low / medium / high / xhigh`，不传默认 `xhigh`。`max` 和 `minimal` 这条链路上游不支持，传了直接 400，不会偷偷降级。账号实际有哪些模型以 Zed 返回为准。

## 快速开始

### Windows

```powershell
.\start.ps1                        # 后台启动，127.0.0.1:8001
.\stop.ps1                         # 停止
.\zed2api.exe login my-account     # 首次先登录 Zed 账号
```

管理页：<http://127.0.0.1:8001>

### macOS

需要 Zig 0.15.x、Node.js/npm，以及系统中的 `openssl` 和 `curl`：

```sh
(cd webui && npm ci && npm run build)
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zed2api login my-account
./start.sh                         # 后台启动，127.0.0.1:8001
./stop.sh                          # 停止
```

`zig build` 会按当前 Mac 原生架构构建，Apple Silicon 和 Intel 均支持。管理页同样是 <http://127.0.0.1:8001>。

### Linux / Docker

GitHub Actions 会构建 Linux amd64 / arm64 二进制，并发布多架构镜像：

```text
ghcr.io/handsomelong922/zed-api:latest
```

#### 1Panel / Docker（推荐用于低配 VPS）

Docker 只需要一个容器端口：

```text
8001
```

在 1Panel 中填写镜像 `ghcr.io/handsomelong922/zed-api:latest`，把你自定义的宿主机端口映射到容器端口 `8001`。例如宿主机端口选择 `34567`，访问地址就是：

```text
http://服务器IP:34567
```

同时把宿主机的持久化目录挂载到：

```text
/data
```

`accounts.json`、`active_account.txt` 和网页保存的 `settings.json` 都会保存在 `/data`，升级或重建容器不会丢账号或网页 API Key。

如果端口会暴露到公网，建议启用全局 API Key。最方便的方式是进入管理页的 **“API Key 设置”**，输入新 Key 后保存；保存会立即生效并写入 `/data/settings.json`。第一次还没有任何 Key 时可以直接保存；已有 Key 后，修改或清除必须输入当前 Key 验证身份。设置接口不会回显密钥，网页也不会把密钥写入 localStorage/sessionStorage。

也可以在 1Panel 的容器环境变量中设置后备 Key：

```text
ZED_API_KEY=你自己设置的密钥
```

优先级是：**网页保存的 `/data/settings.json` > `ZED_API_KEY` 环境变量 > 无鉴权**。清除网页 Key 后，如果仍存在 `ZED_API_KEY`，服务会自动回退到环境变量 Key。

启用后，`/v1/*` 与 `/api/event_logging/batch` 必须携带有效密钥。OpenAI 风格客户端使用 `Authorization: Bearer <key>`；Anthropic 风格客户端也可以使用 `x-api-key: <key>`。Web 管理页、账号管理和登录流程仍保持可访问；API Key 不是整个管理页的登录密码，公网管理页仍建议配合 HTTPS、防火墙、安全组或反向代理认证。

**首次没有账号时**，使用同一个自定义端口访问：

```text
http://服务器IP:你的自定义端口/login
```

不需要 SSH、容器终端，也不需要再映射其他端口。登录流程：

1. 打开 `/login` 页面，点击“打开 Zed 授权”。
2. 在 Zed / GitHub 页面完成授权。
3. 浏览器最后会尝试打开本机 `127.0.0.1:8001`；远程服务器部署时这个页面打不开是正常现象。
4. 复制浏览器地址栏中的完整 URL（必须包含 `user_id` 与 `access_token`）。
5. 回到服务器的 `/login` 页面，把 URL 粘贴进去并点击“完成账号导入”。
6. 账号保存后服务会自动切换到正常 API/Web 管理页，随后刷新原来的服务器地址即可。

普通 Docker 命令对应写法：

```sh
mkdir -p data

docker run -d \
  --name zed-api \
  --restart unless-stopped \
  --memory=384m \
  -p 34567:8001 \
  -e ZED_API_KEY="change-this-to-your-own-secret" \
  -v "$PWD/data:/data" \
  ghcr.io/handsomelong922/zed-api:latest
```

这里的 `34567` 只是示例，可以替换成你在服务器上选择的任意可用端口；**容器端口始终保持 `8001`，无需额外端口。**

> GHCR 首次创建 package 时，如果 GitHub 将 package visibility 默认为 Private，需要在 GitHub Packages 的该镜像设置中把 Visibility 改成 Public 一次；之后云服务器就可以无需 `docker login` 直接 `docker pull`。

> 公网部署建议务必启用 API Key，并使用足够长、不可猜测的随机值。服务不会在日志或设置状态 API 中输出这把密钥。

#### Native Linux

从 GitHub Release 下载与你架构匹配的：

- `zed-api-linux-amd64.tar.gz`
- `zed-api-linux-arm64.tar.gz`

解压后运行：

```sh
chmod +x zed2api
./zed2api login my-account
./zed2api serve 8001
```

原生 Linux 默认监听 `127.0.0.1:8001`，适合直接配合 systemd + 本机反向代理使用。

Windows 健康检查：

```powershell
.\health-check.ps1                # 令牌+账单检查，不调模型
.\health-check.ps1 -Deep          # 当前账号发一次最低成本探测
.\health-check.ps1 -AllAccounts   # 所有账号各探测一次
.\health-check.ps1 -Streaming     # 顺带测三个协议的流式收尾
```

## 客户端配置

模板都在 `configs/`，往自己已有的配置里合并，别整个覆盖。配置前先确认服务活着：

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:8001/v1/models'
```

如果启用了全局 API Key，客户端的 API Key 字段填写当前**有效 Key**即可；客户端需要最终发送 `Authorization: Bearer <key>` 或 `x-api-key: <key>`。

### Codex

把 `configs/codex.config.toml.example` 合并进 Windows 的 `%USERPROFILE%\.codex\config.toml` 或 macOS/Linux 的 `~/.codex/config.toml`：

```toml
model_provider = "zed_local"
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"

[model_providers.zed_local]
name = "Zed Local"
base_url = "http://127.0.0.1:8001/v1"
wire_api = "responses"
requires_openai_auth = false
```

改完重启 Codex（旧进程不重读配置），然后验证：

```powershell
codex exec --skip-git-repo-check '请只回复：CODEX_OK'
```

本机开着 Clash 之类代理的话，`NO_PROXY` 里要有 `localhost,127.0.0.1`，不然发往本机的请求会被代理拦成 502。

### Claude Code

按想用的模型挑一个模板，合并进 Windows 的 `%USERPROFILE%\.claude\settings.json` 或 macOS/Linux 的 `~/.claude/settings.json`：

- `configs/claude.settings.json.example` — Sonnet 5
- `configs/claude-gpt56-sol / -terra / -luna` — GPT-5.6 变体

地址填根路径 `http://127.0.0.1:8001`（客户端自己拼 `/v1/messages`）。重启后验证：

```powershell
claude -p '请只回复：CLAUDE_OK'
```

### OpenCode

把 `configs/opencode.json.example` 复制成项目根目录的 `opencode.json`，或合并里面的 `zed-local` Provider：

```powershell
opencode run --model zed-local/gpt-5.6-terra --variant low "你的任务"
```

未启用 API Key 时 `apiKey` 可以继续填 `dummy`；启用后应填写当前有效 Key。

## API

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/v1/responses` | OpenAI Responses（支持 `stream:true`） |
| POST | `/v1/chat/completions` | OpenAI Chat Completions（支持 `stream:true`） |
| POST | `/v1/messages` | Anthropic Messages（支持 `stream:true`） |
| POST | `/v1/messages/count_tokens` | Claude Code 启动用的兼容桩 |
| GET | `/v1/models` | 模型列表（双格式） |
| GET | `/zed/settings/api-key` | 查询 API Key 是否启用及来源，不返回密钥 |
| POST | `/zed/settings/api-key` | 保存/轮换网页 API Key；已有 Key 时需验证当前 Key |
| DELETE | `/zed/settings/api-key` | 清除网页 API Key；已有 Key 时需验证当前 Key |
| GET | `/zed/accounts` | 账号与调度状态（脱敏） |
| GET | `/zed/accounts/status` | 全账号令牌/套餐/额度检查 |
| POST | `/zed/accounts/health` | 单账号或全账号模型探测 |
| POST | `/zed/accounts/switch` | 切换当前账号 |
| GET | `/zed/usage` | 当前账号用量 |
| GET | `/zed/billing` | 当前账号账单 |
| GET | `/login` | Docker / 1Panel 首次账号初始化 |
| POST | `/zed/login` | 管理页发起本地浏览器 GitHub / Zed OAuth 登录 |
| POST | `/zed/login/complete` | 粘贴本地浏览器回调 URL 完成远程账号导入 |
| GET | `/zed/login/status` | 查询登录状态 |

## 构建

需要 Zig 0.15.x：

```sh
cd webui && npm ci && npm run build && cd ..   # 前端产物内嵌进可执行文件
zig build test                                  # 协议转换与流式回归测试
zig build -Doptimize=ReleaseSafe                # 当前平台原生构建
```

Linux 交叉构建示例：

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

改了前端记得重新 `zig build`，不然可执行文件里还是旧页面。

## 已知限制

- 没有网页 Key 且 `ZED_API_KEY` 未设置/为空时，模型 API 保持无鉴权；公网部署建议启用 API Key，并仍配合 HTTPS、防火墙或安全组使用。
- API Key 保护模型 API 以及已有 Key 后的 Key 修改/清除操作，但不是整个 Web 管理页的管理员登录机制。
- Docker 镜像对普通 bridge 端口映射做了单端口适配；1Panel 只需映射容器 `8001`。
- 请求格式完全按 Zed 官方客户端实现，但上游随时可能改协议或触发风控，不保证持续可用。
- `count_tokens` 是兼容桩，别拿来精确计费。
- 有些 Zed 套餐不公开数值额度，管理页只能显示“未公开”，精确金额去 Zed 官网看。
- 一次调度最多尝试 64 个账号。

## License

MIT。早期思路参考了 [yukmakoto/zed2api](https://github.com/yukmakoto/zed2api)，但本仓库已基本完全重写：请求格式对齐官方客户端、新增 Codex / Claude Code / OpenCode 三客户端适配、多账号调度、全新 Web UI，并修复了原实现的问题。

## 友链

[LinuxDo](https://linux.do)
