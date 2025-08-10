#  测试ddc电子零延迟机密通信

[![FreeBSD](https://img.shields.io/badge/FreeBSD-14.x-red.svg)](https://www.freebsd.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Sing-box](https://img.shields.io/badge/Sing--box-1.11.9-green.svg)](https://github.com/SagerNet/sing-box)

## 📋 项目简介

这是一个专为 **FreeBSD 14.3-RELEASE amd64** 系统设计的科学上网一键部署脚本。

### ✨ 核心特性

- 🔒 **完全安全**：重构原作者脚本，剔除所有安全隐患
- 🚀 **一键部署**：SSH远程执行，3分钟完成安装
- 🎯 **三协议支持**：VLESS+Reality、VMess+WebSocket、Hysteria2
- 🔄 **多订阅格式**：支持V2rayN、Clash Meta、Sing-box
- 📦 **零依赖风险**：使用自编译二进制，无外部下载风险
- 🛡️ **无Root权限**：普通用户即可完成部署

### 🔧 支持的协议

| 协议类型 | 传输方式 | 伪装/加密 | 端口 | 描述 |
|---------|---------|----------|------|------|
| **VLESS** | TCP | Reality | 自动分配 | 现代化TLS伪装，抗封锁能力强 |
| **VMess** | WebSocket | 无 | 自动分配 | 经典协议，兼容性好 |
| **Hysteria2** | UDP | 自签名TLS | 自动分配 | 高性能UDP协议，速度快 |

## 🚀 快速开始

### 前置要求

- **操作系统**：FreeBSD 14.3-RELEASE amd64
- **权限要求**：普通用户（非root）
- **网络要求**：可访问GitHub和必要的规则源

### 一键安装

```bash
# 方式一：使用curl
curl -sSL https://github.com/dayao888/ferrbsd-sbx/raw/main/deploy.sh | bash

# 方式二：使用fetch（FreeBSD原生）
fetch -o - https://github.com/dayao888/ferrbsd-sbx/raw/main/deploy.sh | bash

# 方式三：手动下载执行
fetch https://github.com/dayao888/ferrbsd-sbx/raw/main/deploy.sh
chmod +x deploy.sh
./deploy.sh
```

### 安装过程

1. **环境检查**：自动检测FreeBSD版本和依赖工具
2. **交互配置**：设置Reality伪装域名和端口（可选）
3. **自动部署**：下载二进制、生成配置、启动服务
4. **输出结果**：显示分享链接和订阅文件

## 📱 客户端配置

### V2rayN (Windows)

1. 复制输出的分享链接
2. 在V2rayN中选择"从剪贴板导入批量URL"
3. 选择对应节点连接

### Clash Meta (多平台)

1. 下载生成的 `subscriptions/UUID_clashmeta.yaml` 文件
2. 导入到支持Clash Meta的客户端
3. 选择代理节点

### Sing-box (移动端)

1. 使用生成的 `subscriptions/UUID_singbox.json` 配置
2. 导入到SFA、NekoBox等客户端

## 🛠️ 管理命令

安装完成后，提供以下管理脚本：

```bash
# 查看服务状态
./check_status.sh

# 重启服务
./restart.sh

# 停止服务
./stop.sh

# 重新生成订阅
./subscription.sh
```

## 📊 目录结构

```
sbx/
├── deploy.sh              # 主部署脚本
├── subscription.sh        # 订阅生成工具
├── sb-amd64               # Sing-box二进制文件
├── config.json            # Sing-box配置文件
├── cert.pem               # TLS证书
├── private.key            # TLS私钥
├── subscriptions/         # 订阅文件目录
│   ├── UUID_v2sub.txt     # V2rayN订阅
│   ├── UUID_clashmeta.yaml # Clash Meta配置
│   └── UUID_singbox.json  # Sing-box配置
├── check_status.sh        # 状态检查
├── restart.sh             # 重启脚本
└── stop.sh                # 停止脚本
```

## 🔧 高级配置

### 手动指定端口

编辑 `config.json` 文件，修改对应的端口号：

```json
{
    "inbounds": [
        {
            "listen_port": 10001,  // Hysteria2端口
            ...
        },
        {
            "listen_port": 10002,  // VLESS端口
            ...
        },
        {
            "listen_port": 10003,  // VMess端口
            ...
        }
    ]
}
```

### 更换Reality域名

修改 `config.json` 中的 `server_name` 字段，然后重启服务：

```bash
./restart.sh
./subscription.sh  # 重新生成订阅
```

### 自定义路由规则

编辑 `config.json` 中的路由规则部分，可添加自定义的代理规则。

## 🔍 故障排除

### 常见问题

1. **服务启动失败**
   ```bash
   # 查看日志
   cat sb.log
   
   # 检查端口占用
   netstat -an | grep LISTEN
   ```

2. **连接超时**
   - 检查防火墙设置
   - 确认端口是否被服务商封禁
   - 尝试更换端口

3. **Reality握手失败**
   - 确认Reality域名可访问
   - 检查系统时间是否同步

### 获取帮助

如遇到问题，请提供以下信息：

- FreeBSD版本：`uname -r`
- 错误日志：`cat sb.log`
- 网络状态：`netstat -an | grep LISTEN`

## 🛡️ 安全说明

### 安全改进

- ✅ 移除所有外部下载依赖（除geosite/geoip规则）
- ✅ 使用自编译sing-box二进制
- ✅ 剔除Web管理面板和远程执行功能
- ✅ 移除保活机制和Argo隧道
- ✅ 删除所有第三方API调用

### 隐私保护

- 📊 不收集任何用户数据
- 🔒 本地生成UUID和密钥
- 🛡️ 无远程统计和上报功能

## 📄 许可证

本项目基于 MIT 许可证开源。

## 🤝 贡献

欢迎提交Issue和Pull Request改进项目。

## ⚠️ 免责声明

本项目仅供学习和研究使用，请遵守当地法律法规。作者不承担任何使用风险。

---

**享受自由的网络环境！** 🌐
