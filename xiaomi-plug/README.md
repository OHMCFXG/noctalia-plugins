# Xiaomi Plug

局域网小米 MIoT 智能插座的实时功率，显示在 Noctalia bar 上。没有 panel 或桌面部件。

## 插件

| 字段 | 值 |
| --- | --- |
| ID | `0x1ce/xiaomi-plug` |
| Entries | Bar widget: `bar`；service: `plug-data` |
| Plugin API | 24（`runAsync` 参数数组，避免把 token 拼进 shell） |

## 依赖

同时支持 [uv](https://docs.astral.sh/uv/) 和 Python，**默认 uv**。

- 未指定解释器且 PATH 上有 `uv`：用 `uv run --with python-miio` 运行 `poll.py`，自动带上 [python-miio](https://github.com/rytilahti/python-miio)
- 没有 `uv`：回退到 PATH 上的 `python3`（需要已安装 `python-miio`）
- 高级设置里指定了 Python 路径：始终用该解释器

插座通过局域网 UDP 54321 通信，需要和电脑在同一网段。

## 使用

1. 把本仓库加为插件源并启用：

```sh
noctalia msg plugins source add personal path /path/to/noctalia-plugins
noctalia msg plugins enable 0x1ce/xiaomi-plug
```

2. 在 bar 编辑器中添加 `0x1ce/xiaomi-plug:bar`。
3. 在 **设置 → 插件 → Xiaomi Plug** 中填写插座 IP 和 32 位 miIO token。  
   也可以左键点击 bar widget，会打开该插件的设置页。

### 交互

| 操作 | 行为 |
| --- | --- |
| 悬停 | Tooltip 显示功率或错误 |
| 左键 | 打开插件设置（填写 IP / token） |
| 右键 | 立即刷新功率 |
| 中键 | 打开 widget 实例设置（host 内置） |

## 设置

IP 和 token 是插件级 `[[setting]]`，写在 Noctalia 配置里，由 `noctalia.getConfig()` 读取。不要用环境变量。

| 设置 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `ip` | string | 空 | 插座局域网 IPv4 |
| `token` | string | 空 | 32 位十六进制 miIO token |
| `pollSeconds` | int | 5 | 轮询间隔，3–60 秒 |
| `pythonPath` | file | 空 | 可选。留空默认 uv；无 uv 时用 python3；填写则强制该解释器 |
| `siid` | int | 11 | 高级：功率属性服务 id（插座 3 为 11） |
| `piid` | int | 2 | 高级：功率属性 id（插座 3 为 2） |

Token 在设置界面中是普通字符串，无法做成密码框。它保存在本机 Noctalia 配置中，不要提交到 git。

默认 SIID/PIID 对应米家智能插座 3（`cuco.plug.v3`）。其他型号需要改这两个值。

## IPC

```sh
noctalia msg plugin 0x1ce/xiaomi-plug:bar focused refresh
noctalia msg plugin 0x1ce/xiaomi-plug:plug-data all refresh
noctalia msg plugin 0x1ce/xiaomi-plug:bar focused settings
```

## 工作方式

`[[service]]` 按间隔查询一次 MIoT 功率。默认命令是 `uv run --no-project --with python-miio -- python poll.py ...`；没有 uv 时改为 `python3 poll.py ...`。结果写到 `noctalia.state`，bar widget 只读这份快照。IP 和 token 来自插件设置，作为独立参数传入，不经过 `/bin/sh`。第一次用 uv 时可能会花几秒下载 `python-miio`，之后走缓存。已有读数时后台刷新不会改 bar 上的图标。
