# from-terminal-to-Minecraft

一个单文件 Python 脚本，**不打开启动器、直接从终端启动 Minecraft**。

它读取启动器（HMCL / 官方启动器 / Prism 等）已经下载好的实例目录，自己拼 classpath、解压 natives、挑合适的 JDK，然后 `exec` java。没有额外依赖，只用标准库。

## 为什么

- 不想为了点一下"启动"就开一个几百 MB 的 Java 启动器界面
- 想写成脚本/快捷键/桌面文件，或者塞进 systemd-run、tmux 里跑
- 启动器崩了、或者只想飞快换实例

## 安装

单文件脚本，放哪都行，只要在 `PATH` 里。

**方式一：直接下载**

```bash
curl -fsSL https://raw.githubusercontent.com/must-be-the-Airconditi/from-terminal-to-Minecraft/main/mc \
  -o ~/.local/bin/mc
chmod +x ~/.local/bin/mc
```

**方式二：clone**

```bash
git clone https://github.com/must-be-the-Airconditi/from-terminal-to-Minecraft.git
cd mc-launcher
install -Dm755 mc ~/.local/bin/mc
```

**方式三：就地软链接**（方便以后 `git pull` 更新）

```bash
ln -sf ~/projects/from-terminal-to-Minecraft/mc ~/.local/bin/mc
```

确认 `~/.local/bin` 在 `PATH` 里：

```bash
echo $PATH | tr ':' '\n' | grep -q "$HOME/.local/bin" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
mc --list
```

## 用法

```bash
mc                      # 启动最新的实例
mc --list               # 列出已安装实例
mc 1.21.4-fabric        # 指定实例名
mc --fullscreen         # 全屏启动
mc --dry-run            # 只打印 java 命令，不执行
```

## 环境变量

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `MC_DIR` | `.minecraft` 目录 | 自动探测 `~/.minecraft`、`~/桌面/.minecraft`、`~/Desktop/.minecraft` |
| `MC_USER` | 玩家名 | 当前系统用户名 |
| `MC_UUID` | 玩家 UUID | 由玩家名推导的离线 UUID |
| `MC_TOKEN` | access token | `0`（离线） |
| `MC_MEM` | 堆大小 | `2G` |
| `MC_JAVA` | 指定 java | 自动挑选版本号最小且够用的 JDK |
| `MC_JVM_ARGS` | 追加 JVM 参数，空格分隔 | 空 |
| `MC_WIDTH` / `MC_HEIGHT` | 初始窗口尺寸 | `854` / `480` |

```bash
MC_MEM=4G MC_JVM_ARGS="-XX:+UseZGC" mc 1.21.4-fabric
```

## 兼容性

脚本不挑加载器：它只读 version json 里的 `mainClass`、`libraries` 和启动参数，所以

- 原版 / Fabric / Quilt / Forge / NeoForge 都能用（取决于 `mainClass` 指向谁）
- 支持 `inheritsFrom` 继承链，也就是 Forge/NeoForge 官方格式里"只写增量、基础库靠继承"的那种 json，会逐级合并
- 支持 1.13 之前的 `minecraftArguments` 老格式（含 `--tweakClass`）

## 依赖

- Python 3.8+
- 一个够新版本的 JDK（脚本会在 `/usr/lib/jvm`、`/opt/java`、`/usr/java` 里找）
- 实例已经由别的启动器下载好（本脚本只负责启动，不负责下载、安装 mod loader）

## 局限

- **仅离线模式**：不接 Mojang 认证，也不支持 authlib-injector 外置登录。单机能进，正版服务器/外置登录服务器会因为会话无效而拒绝
- 只处理 Linux 规则（linux/x86_64），其它平台的 natives 规则会被跳过
- 不处理 `--quickPlay*`、demo 之类特性参数
- Forge/NeoForge 只处理到"合并 json + exec java"这一层；如果某个版本还需要安装器改文件（老 Forge 的 `install` 步骤），需要先让启动器装好

## 测试过的环境

Arch Linux + niri (Wayland)，HMCL 下载的 Fabric 实例（1.20.1 / 26.1.2，209 个 mod）用 OpenJDK 17 / 25 启动正常。

## License

MIT
