# VLESS Reality Chain

为 Alpine NAT 小机器准备的双段代理安装器：

```text
客户端 ── VLESS + REALITY + Vision ── 线路机
       ── VLESS + REALITY + Vision ── 落地机 ── 目标网站
```

支持 Alpine + OpenRC，amd64 / arm64。核心固定为官方 **sing-box 1.14.3**，下载适合 Alpine 的 **musl** 程序，并核对仓库内固定的官方 SHA256。脚本版本 `v1.0.0`。两台机器各安装一次，先落地，再线路。

## 先准备端口

在**两台**机器的 NAT 面板分别添加：

| 用途 | 公网端口 | 容器端口 | 协议 |
| --- | --- | --- | --- |
| 代理 | 24443 | 24443 | TCP |
| SSH | 商家分配 | 22 | TCP |

公网与容器端口可以不同，脚本会分别询问。代理端口要求大于 20000。商家防火墙也要放行。安装器无法修改商家的 NAT 面板。

在每台机器以 root 执行一次依赖准备：

```sh
apk add --no-cache bash curl ca-certificates
```

## 1. 安装落地机

与你原来使用的一键命令相同的启动形式：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pengyuyan29/vless-reality-chain/v1.0.0/install-vless-chain.sh)" -- exit
```

按提示填写**落地机**的 NAT 公网入口、代理公网端口、容器监听端口、SNI。默认端口 24443，默认 SNI `www.cloudflare.com`。UUID、REALITY 密钥和 short ID 自动生成。

建议先下载阅读时：

```bash
curl -fSL https://raw.githubusercontent.com/pengyuyan29/vless-reality-chain/v1.0.0/install-vless-chain.sh -o /root/install-vless-chain.sh
less /root/install-vless-chain.sh
bash /root/install-vless-chain.sh exit
```

成功后生成：

- `/etc/vless-chain/exit-outbound.json`：给线路机导入的连接文件，包含落地节点访问凭据和实测出口 IPv4，**不含 REALITY 私钥**。
- `/etc/vless-chain/vless.txt`：该机器的分享链接。

安装器通过本地 SOCKS 临时客户端完成一次真实 VLESS + REALITY 请求，再加入开机启动。这个检查不经过公网 NAT 映射，下一步仍需从线路机连接落地入口验证。

## 2. 把落地连接文件复制到线路机

可用支持 SFTP 的 SSH 工具传文件，或者从自己的电脑中转：

```sh
scp -P 落地SSH公网端口 root@落地公网地址:/etc/vless-chain/exit-outbound.json ./exit-outbound.json
scp -P 线路SSH公网端口 ./exit-outbound.json root@线路公网地址:/root/exit-outbound.json
```

这些是占位符，执行前替换。OpenSSH 新版 scp 默认使用 SFTP；如果提示找不到子系统，需要在对应服务器安装并配置 SFTP，或使用控制台在 root 专用文件中粘贴 JSON。

连接文件权限建议设为 600，不要传到公开仓库、网盘分享或工单附件。复制完整 JSON，避免终端换行造成漏字。

## 3. 安装线路机

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pengyuyan29/vless-reality-chain/v1.0.0/install-vless-chain.sh)" -- relay
```

填写**线路机**自己的公网入口与端口；落地文件填 `/root/exit-outbound.json`。两段可使用不同 SNI；线路到落地这一段会使用落地文件里的 SNI、公钥和 short ID。

线路配置仅有一个 VLESS 出站，指向落地。没有直接访问互联网的备用出站。安装时实测的出口 IPv4必须等于落地文件记录的 IPv4，否则安装失败并恢复之前的受管状态。商家变更落地出口时，请先重新运行落地安装器生成新的连接文件。

成功后只把**线路机的** `/etc/vless-chain/vless.txt` 导入客户端，日常使用这个节点。

## 命令行参数

脚本支持完整参数输入，适合自己保存部署步骤；下面的 `203.0.113.*` 是文档示例地址，不能用于真实连接：

```bash
bash install-vless-chain.sh exit \
  --public-host 203.0.113.10 --public-port 24443 --listen-port 24443 \
  --sni www.cloudflare.com

bash install-vless-chain.sh relay \
  --public-host 203.0.113.20 --public-port 24443 --listen-port 24443 \
  --sni www.cloudflare.com --exit-file /root/exit-outbound.json
```

原来已经有 sing-box 服务的机器，先选择一个空闲、已映射的端口。脚本使用独立的 `vless-chain` 服务与目录，遇到其他程序占用代理端口时会停止部署。请先手动规划旧服务的迁移；不要在使用中的 24443 上直接重装。

## 检查与回滚

```sh
rc-service vless-chain status
/usr/local/lib/vless-chain/sing-box check -c /etc/vless-chain/config.json
rc-service vless-chain restart
```

每次替换配置前，备份到 `/var/lib/vless-chain-backups/时间戳-随机后缀/`，保存配置、程序、OpenRC 服务、之前是否运行和是否开机启动。替换、服务启动或真实代理测试失败会自动恢复。安装依赖和新增系统账号不会卸载。

手动恢复某一备份，传**目录名**，例如：

```sh
bash /root/install-vless-chain.sh rollback 20261015T120000Z-abcdef
```

手动回滚前会再备份当前受管状态。首次安装前的备份代表未安装状态，恢复它会停止并移除本脚本的服务和配置。重复安装受管节点会保留 UUID、REALITY 密钥和 short ID；改变端口或 SNI 后需要重新导入分享链接。

同版本的相同程序会复用；同一文件系统中的程序备份使用硬链接，减少 500 MB / 1 GB 小磁盘的占用。不同核心版本仍会积累，请定期检查备份大小，确认不需要后再自行清理。

## 实际验证

在自己的客户端选择线路节点后，确认网站看到的是落地出口。若使用本地 SOCKS（例如 20808）：

```sh
curl --noproxy "" --proxy socks5h://127.0.0.1:20808 https://api.ipify.org
curl --noproxy "" --proxy socks5h://127.0.0.1:20808 https://www.cloudflare.com/cdn-cgi/trace
```

**不要写 `--noproxy '*'`**，它会让请求绕过代理，得到一个看似成功但无效的测试。

可以暂时停止落地服务，确认线路节点无法访问网站，再启动落地服务确认恢复。用完记得恢复服务。

## 安全与适用范围

- VLESS 本身没有传输加密；本项目强制使用 REALITY，并启用 Vision。分享链接的 `encryption=none` 是 VLESS 字段，传输保护来自 `security=reality`。
- 主服务以 `vless-chain` 系统用户运行。配置目录 root:vless-chain 750，配置文件 640；分享链接、节点元数据及落地连接文件仅 root 可读。
- 代理目标中的私有 IP 被拒绝，线路无 direct 回退。这个规则不等于完整的 DNS 重绑定防护或主机防火墙。
- REALITY 握手目标会随网络和站点变化。TLS 1.3 探测通过也不能保证 REALITY 可用，因此安装器还要做实际认证代理测试。
- 公网代理监听 TCP；目标 UDP 若由客户端支持，可经 VLESS 封装传输，不需要开放独立的公网 UDP 代理端口。
- 不修改 SSH、root 密码、NAT 映射、系统防火墙和内核参数。下载程序固定版本，校验失败就停止；更新核心需要审核新的版本与 SHA256。
- 当前自动化测试范围见 Actions。amd64 安装链路在 Alpine 容器验证；arm64 使用官方校验值，未在真实 ARM 机器跑完整安装。公网 NAT、客户端实际体验、流量和长期稳定性需要在自己的环境确认。

SSH 服务不存在时先在面板控制台安装 OpenSSH 并检查 22 端口；root 被锁定或密码验证失败时，在控制台运行 `passwd root` 设置自己的密码。密码不要写入脚本或仓库。

## 参考

交互和 NAT 部署思路参考 [ceocok / Incudal](https://github.com/ceocok/incudal/blob/main/scripts/install-singbox.sh)。本项目的单协议链式配置根据 [sing-box VLESS](https://sing-box.sagernet.org/configuration/outbound/vless/)、[TLS / REALITY](https://sing-box.sagernet.org/configuration/shared/tls/) 和 [Route](https://sing-box.sagernet.org/configuration/route/) 文档编写。

本仓库只包含通用代码、文档示例地址和测试夹具。请勿提交实际服务器配置、SSH 密码、REALITY 私钥或分享链接。
