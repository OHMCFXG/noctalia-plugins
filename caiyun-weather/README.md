# Caiyun Weather

基于彩云天气 API 的 Noctalia v5 天气插件。

## 功能

- bar widget 显示天气图标和当前温度；
- 点击 bar widget 打开详细天气 panel；
- 当前天气、体感温度、湿度、风力、能见度、气压和云量；
- 两小时短临降水趋势；
- 逐小时和未来五天预报；
- AQI、主要污染物和生活指数；
- 日出日落和天气预警；
- service 统一请求、缓存和刷新数据。

## 配置

启用插件后，在 **设置 → 插件 → Caiyun Weather** 中填写：

- 纬度，例如 `31.22`；
- 经度，例如 `121.35`；
- 自动刷新间隔，范围为 1～120 分钟，默认 10 分钟。

API Key 已固定在插件请求中，不需要填写。

注意：彩云天气 API 的 URL 坐标顺序是 `经度,纬度`，插件会自动按照该顺序构造请求。

## 使用

启用插件：

```sh
noctalia msg plugins enable 0x1ce/caiyun-weather
```

然后在 bar 编辑器中添加：

```text
0x1ce/caiyun-weather:bar
```

点击天气 widget 即可打开：

```text
0x1ce/caiyun-weather:weather
```

也可以通过 IPC 打开面板：

```sh
noctalia msg panel-toggle 0x1ce/caiyun-weather:weather
```

右键 bar widget 会请求立即刷新天气，不受自动刷新间隔影响。

## 数据来源

天气数据来自彩云天气 v2.7 综合天气接口。API 默认返回公制单位：温度为摄氏度，风速为公里/小时，能见度为公里。

固定 API Key 会随插件请求发送。桌面客户端中的 API Key 无法真正隐藏，请将其视为公开客户端凭据。

## 设计

详细设计和实现范围见 [`DESIGN.md`](./DESIGN.md)。
