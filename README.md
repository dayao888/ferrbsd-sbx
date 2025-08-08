# FreeBSD (non-root) sing-box 一键部署脚本

本项目旨在为 **FreeBSD 14.3 (amd64)** 操作系统的**非 root 用户**提供一个安全、纯净、便捷的 `sing-box` 代理服务部署方案。

## ✨ 项目特性

- **无需 Root**：整个安装和运行过程**不**需要 `root` 或 `sudo` 权限
- **环境纯净**：所有文件（程序、配置、日志）均安装在用户家目录下的 `$HOME/.sbx`，卸载彻底无残留
- **协议全面**：一次性配置三个主流协议，满足不同网络环境需求：
    - `VLESS + REALITY` (主推，高安全性)
    - `VMess + WebSocket` (高兼容性)
    - `Hysteria 2` (高速度)
- **高度自动化**：自动检测依赖、生成全部密钥和凭证、创建配置文件
- **管理便捷**：生成 `sbx.sh` 管理脚本，提供启动、停止、重启、查看状态、日志、节点链接、一键卸载等全套功能

## 🚀 安装部署

### 准备工作

在运行脚本之前，您**必须**在您的服务器提供商的控制台（如 AWS、Google Cloud、Vultr 等）的**防火墙**或**安全组**中，为您计划使用的**三个端口**放行 TCP 和 UDP 流量。

### 一键安装

在您的 FreeBSD 服务器上执行以下命令：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/install.sh)"
```

> **注意**：如果您的服务器无法访问 GitHub，请先配置代理或使用其他方式下载脚本。

脚本启动后，会引导您完成交互式配置：

1. **域名配置**：选择是否使用域名（推荐），或自动获取公网 IP
2. **端口配置**：依次输入三个已在防火墙中放行的端口号
   - VLESS-Reality 端口
   - VMess-WS 端口
   - Hysteria2 端口

安装成功后，会自动启动服务并显示节点和订阅链接。

## 🛠️ 服务管理

安装程序会在您的用户主目录 (`$HOME`) 下创建一个名为 `sbx.sh` 的管理脚本。

### 交互式菜单

直接运行脚本会显示一个清晰的数字菜单：

```bash
./sbx.sh
# 或
sh ~/sbx.sh
```

### 直接命令

您也可以直接在脚本后附加命令参数来快速执行操作：

```bash
# 启动服务
./sbx.sh start

# 停止服务
./sbx.sh stop

# 重启服务
./sbx.sh restart

# 查看状态
./sbx.sh status

# 查看实时日志
./sbx.sh log

# 显示节点链接
./sbx.sh links

# 完全卸载
./sbx.sh uninstall
```

## 📋 协议说明

### VLESS + REALITY
- **端口**：用户自定义
- **加密**：无加密（依赖 TLS）
- **流控**：xtls-rprx-vision
- **伪装**：www.microsoft.com
- **特点**：最高安全性，抗检测能力强

### VMess + WebSocket
- **端口**：用户自定义
- **路径**：/vmess
- **加密**：auto
- **特点**：兼容性好，稳定性高

### Hysteria 2
- **端口**：用户自定义
- **协议**：UDP
- **伪装**：www.microsoft.com
- **特点**：速度快，适合高带宽环境

## 🔧 故障排除

### 常见问题

1. **安装失败**
   - 检查网络连接是否正常
   - 确认系统已安装 `curl`、`tar`、`openssl`
   - 检查是否有足够的磁盘空间

2. **服务启动失败**
   - 检查端口是否被占用：`sockstat -l | grep 端口号`
   - 查看详细日志：`./sbx.sh log`
   - 确认防火墙已放行相应端口

3. **连接失败**
   - 确认服务器防火墙/安全组已正确配置
   - 检查客户端配置是否正确
   - 验证服务状态：`./sbx.sh status`

### 日志位置

- **服务日志**：`$HOME/.sbx/log/sing-box.log`
- **配置文件**：`$HOME/.sbx/etc/config.json`
- **二进制文件**：`$HOME/.sbx/bin/sing-box`

## 📝 更新与卸载

### 更新

重新运行安装脚本即可自动更新：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/dayao888/ferrbsd-sbx/main/install.sh)"
```

### 卸载

使用管理脚本的卸载功能：

```bash
./sbx.sh uninstall
```

或手动删除：

```bash
rm -rf $HOME/.sbx
rm -f $HOME/sbx.sh
```

## ⚠️ 注意事项

1. **端口安全**：请确保只开放必要的端口，避免使用常见端口
2. **定期更新**：建议定期更新 sing-box 到最新版本
3. **备份配置**：重要配置请及时备份
4. **合规使用**：请遵守当地法律法规，合理使用代理服务

## 📞 支持

如果您在使用过程中遇到问题，请：

1. 查看本文档的故障排除部分
2. 检查 GitHub Issues 中是否有类似问题
3. 提交新的 Issue 并提供详细的错误信息

---

**免责声明**：本项目仅供学习和研究使用，请用户自行承担使用风险，并遵守相关法律法规。
