# 彩云天气插件设计方案

## 1. 目标

为 Noctalia v5 设计一个基于彩云天气 API 的天气插件：

- 在 bar 上显示天气图标和当前温度；
- 点击 bar widget 后打开天气面板；
- 在面板中以合理、现代、易读的方式展示当前天气、短临降水、小时预报、逐日预报、空气质量、生活指数和天气预警；
- API Key 固定在插件请求逻辑中，用户不需要填写；
- 用户只需要在插件设置中填写纬度和经度。

Noctalia v5 插件系统目前处于 Beta，manifest 格式和插件 API 仍可能发生变化。

## 2. API

使用彩云天气 v2.7 综合天气接口：

```text
https://api.caiyunapp.com/v2.7/Y2FpeXVuIGFuZHJpb2QgYXBp/{longitude},{latitude}/weather?alert=true
```

注意：用户设置使用 `latitude` 和 `longitude` 命名，但彩云天气 URL 的坐标顺序是：

```text
longitude,latitude
```

例如：

```text
latitude  = 31.22
longitude = 121.35
```

最终请求路径为：

```text
.../121.35,31.22/weather?alert=true
```

API 默认返回 `metric` 单位：

- 温度：摄氏度；
- 风速：公里/小时；
- 距离：公里；
- 气压：帕，需要转换为 hPa；
- 湿度：0 到 1，需要转换为百分比。

### API Key 说明

固定 Key 不作为用户设置暴露，也不写入用户配置文件。由于请求由桌面插件直接发起，Key 会存在于插件代码和网络请求中，不能被视为真正的秘密凭据。本插件按需求固定使用该 Key。

## 3. 插件目录和入口

建议插件目录：

```text
caiyun-weather/
├── DESIGN.md
├── plugin.toml
├── service.luau
├── widget.luau
├── panel.luau
├── README.md
└── translations/
    ├── zh-Hans.json
    └── en.json
```

建议插件 ID：

```text
0x1ce/caiyun-weather
```

入口设计：

| 入口 | ID | 作用 |
| --- | --- | --- |
| Bar widget | `bar` | 显示天气图标和当前温度 |
| Panel | `weather` | 显示完整天气信息 |
| Service | `weather-data` | 请求 API、缓存和发布天气状态 |

天气面板完整 ID：

```text
0x1ce/caiyun-weather:weather
```

采用 `service + widget + panel` 的结构。当前仓库中的 `mpris-lyrics` 已经采用了 service 统一获取数据、其他入口通过 `noctalia.state` 读取数据的模式，天气插件沿用这一模式可以避免重复请求。

## 4. 用户设置

设置为插件级设置，使 service、bar widget 和 panel 都可以读取。

| 配置键 | 类型 | 范围/默认值 | 说明 |
| --- | --- | --- | --- |
| `latitude` | `string` | 默认空 | 纬度，范围 `-90` 到 `90`，例如 `31.22` |
| `longitude` | `string` | 默认空 | 经度，范围 `-180` 到 `180`，例如 `121.35` |
| `refreshIntervalMinutes` | `int` | `10`，范围 `1`～`120` | 自动刷新间隔（分钟）；右键 bar widget 可立即刷新 |

使用字符串而不是 `double`，是为了区分“用户尚未填写”和合法的 `0` 坐标。service 读取后自行完成数字解析和范围校验。

校验规则：

1. 空值：视为尚未配置；
2. 非数字：视为格式错误；
3. 纬度不在 `-90..90`：视为无效；
4. 经度不在 `-180..180`：视为无效；
5. 只有两项都有效时才发起 API 请求。

第一版不提供 API Key、单位、自动定位或多地点设置，以保持配置简单。

## 5. Service 和数据流

### Service 责任

`service.luau` 负责：

1. 读取经纬度设置；
2. 构造 API URL；
3. 通过 `noctalia.http()` 发起异步 GET 请求；
4. 检查 HTTP 响应和 API JSON 中的 `status`；
5. 解析并校验返回数据；
6. 将原始响应转换为面向 UI 的精简数据模型；
- 通过 `noctalia.state` 发布给 widget 和 panel；
- service 使用较低频率的内部 tick 检查定时刷新，UI 数据变化仍由 state watcher 立即响应。

不直接把完整原始 API 响应放入共享状态。API 中逐分钟、逐小时数据点较多，应在 service 中降采样和裁剪，减少跨 VM 复制和 UI 处理压力。

### 刷新策略

建议行为：

- service 启动后立即请求一次；
- 按 `refreshIntervalMinutes` 定时刷新，默认每 10 分钟；
- 经纬度配置变化后立即刷新；刷新间隔变化在下一个调度 tick 生效，不额外触发网络请求；
- panel 打开时直接使用缓存数据，不等待网络请求；
- panel 的刷新按钮通过 state 信号请求 service 立即刷新；
- 请求失败时保留最后一次成功数据，同时标记为过期；
- 没有任何成功数据时显示错误状态。

### 建议的共享状态

共享状态可以抽象为以下结构：

```text
weather = {
  status = "unconfigured" | "loading" | "ready" | "error",
  stale = boolean,
  error = string | nil,
  updatedAt = number | nil,
  locationName = string,
  latitude = number,
  longitude = number,
  current = { ... },
  nowcast = { ... },
  hourly = [ ... ],
  daily = [ ... ],
  airQuality = { ... },
  lifeIndex = { ... },
  astronomy = { ... },
  alerts = [ ... ]
}
```

实际实现时只发布 UI 需要的字段，不保存完整原始 JSON。

## 6. Bar widget 设计

### 正常状态

bar widget 只显示最重要的信息：

```text
[天气图标] 30°
```

例如：

```text
☔ 30°
```

温度在 bar 中显示为四舍五入后的整数，panel 中显示一位小数。

### 图标映射

根据当前 `skycon` 映射到 Tabler/Nerd Font glyph：

| `skycon` | 建议 glyph |
| --- | --- |
| `CLEAR_DAY` | `sun` |
| `CLEAR_NIGHT` | `moon` |
| `PARTLY_CLOUDY_DAY` | `cloud-sun` |
| `PARTLY_CLOUDY_NIGHT` | `cloud-moon` |
| `CLOUDY` | `cloud` |
| `LIGHT_RAIN`、`MODERATE_RAIN` | `cloud-rain` |
| `HEAVY_RAIN`、`STORM_RAIN` | `cloud-storm` |
| `LIGHT_SNOW`、`MODERATE_SNOW`、`HEAVY_SNOW`、`STORM_SNOW` | `snowflake` |
| `FOG`、各种雾霾 | `cloud-fog` |
| `WIND`、`DUST`、`SAND` | `wind` |
| 未知值 | `cloud` |

bar widget 优先使用 Noctalia 简单的 `barWidget.setGlyph()` 和 `barWidget.setText()` 接口。点击时调用：

```text
noctalia.togglePanel("0x1ce/caiyun-weather:weather")
```

同时考虑 `barWidget.isVertical()`：横向 bar 使用图标加温度的水平布局，纵向 bar 使用上下布局。

### 异常状态

| 状态 | 图标 | 文字 |
| --- | --- | --- |
| 尚未填写坐标 | `map-pin` | `--` |
| 首次加载 | `cloud` 或加载图标 | `…` |
| 请求失败但有旧数据 | 使用旧天气图标 | 使用旧温度 |
| 请求失败且无旧数据 | `cloud-off` | `--` |

详细错误信息只在 panel 中显示，避免 bar 被错误文本占满。

## 7. Panel 设计

建议 panel 配置：

- 宽度：约 `460px`；
- 高度：约 `680px`；
- `placement = "floating"`；
- `position = "auto"`；
- `open_near_click = true`；
- 根节点使用 `ui.scroll`；
- 面板大小由 manifest 声明，内容由 `panel.render()` 更新。

panel 采用主题 palette role，而不是写死亮色背景：

- 普通文字：`on_surface`；
- 次要文字：`on_surface_variant`；
- 卡片背景：`surface_variant/0.5`；
- 主天气图标：`primary`；
- 降水：`secondary`；
- 预警和接口错误：`error`。

### 推荐布局

```text
┌──────────────────────────────────────┐
│ 天气 · 长宁区              ↻     ×   │
├──────────────────────────────────────┤
│       天气图标       30.1°           │
│                     小雨              │
│                  体感 31.5°          │
│ 雨渐大，7分钟后转为中雨，不过25分钟后… │
├──────────────────────────────────────┤
│ 当前实况                            │
│ 湿度 75%       风 东北 19 km/h        │
│ 能见度 11.5 km  气压 997 hPa          │
│ 云量 73%       露点 25.2°C            │
├──────────────────────────────────────┤
│ 未来两小时降水趋势                   │
│              降水曲线                │
├──────────────────────────────────────┤
│ 未来几小时                           │
│ 现在  09时  10时  11时  12时  13时    │
│  ☔    ☔    ☔    ☔    ☔    ☔        │
│ 30°   28°   28°   28°   27°   27°     │
├──────────────────────────────────────┤
│ 未来五天                             │
│ 今天  大雨       27° / 30°   80%      │
│ 周一  大雨       27° / 29°   80%      │
│ 周二  大雨       28° / 31°   80%      │
│ 周三  中雨       28° / 32°   70%      │
│ 周四  小雨       27° / 32°   60%      │
├──────────────────────────────────────┤
│ 空气质量与生活指数                   │
│ AQI 25 优       PM2.5 14              │
│ 紫外线：无       体感：闷热            │
│ 穿衣：热         洗车：较不适宜        │
├──────────────────────────────────────┤
│ 日出 05:16       日落 18:44           │
│ 更新于 08:20 · 数据来源：彩云天气      │
└──────────────────────────────────────┘
```

## 8. Panel 数据分区

### 8.1 顶部当前天气

使用：

- `result.realtime.temperature`；
- `result.realtime.apparent_temperature`；
- `result.realtime.skycon`；
- `result.forecast_keypoint`；
- `result.alert.adcodes`。

地点名称优先使用 `result.alert.adcodes` 最后一级的 `name`。例如 API 返回“上海市 / 上海城区 / 长宁区”时显示“长宁区”。如果没有行政区名称，则显示经纬度。

### 8.2 当前实况指标

使用 `result.realtime`：

| 字段 | 显示方式 |
| --- | --- |
| `humidity` | 转换为百分比，例如 `75%` |
| `wind.speed` | `km/h` |
| `wind.direction` | 转换为中文风向，例如“东北风” |
| `visibility` | `km` |
| `pressure` | Pa 转换为 hPa |
| `cloudrate` | 转换为云量百分比 |
| `dewpoint` | 露点温度 |
| `air_quality.aqi.chn` | 中国 AQI |
| `air_quality.description.chn` | 优、良、轻度污染等 |

### 8.3 两小时短临降水

使用：

- `result.minutely.description`；
- `result.minutely.precipitation_2h`；
- `result.minutely.probability`。

`precipitation_2h` 点数较多，service 降采样为约 12～24 个点，再提供给 `ui.graph`。图表用于展示趋势，文字描述作为主要信息，例如：

```text
雨渐大，7分钟后转为中雨，不过25分钟后雨会再次变小
```

### 8.4 逐小时预报

显示未来 6～8 个小时，每项包含：

- 时间；
- 天气图标；
- 温度；
- 降水概率；
- 降水量。

使用 `hourly.skycon`、`hourly.temperature` 和 `hourly.precipitation`。可以额外使用 24～48 小时温度数据绘制趋势图，避免在 panel 中放置过多卡片。

小时数据应根据 API 的时区和 `server_time` 选择当前时间之后的数据，而不是盲目使用数组前几项。

### 8.5 逐日预报

显示 `daily` 的前 5 天：

- 日期；
- 天气图标和中文天气描述；
- 最高/最低温度；
- 降水概率；
- 必要时显示日均 AQI。

主要使用：

- `daily.skycon`；
- `daily.temperature`；
- `daily.precipitation`；
- `daily.air_quality.aqi`。

### 8.6 空气质量

默认展示核心指标：

- AQI；
- AQI 中文等级；
- PM2.5；
- PM10。

O₃、SO₂、NO₂、CO 可以作为第二行的详细指标，在 panel 空间允许时显示。

AQI 颜色根据等级映射到主题语义颜色，但不使用固定硬编码背景。

### 8.7 生活指数

今天优先显示：

- 紫外线；
- 舒适度；
- 穿衣；
- 洗车；
- 感冒风险。

使用 `daily.life_index` 的第一天数据；如果不可用，回退到 `realtime.life_index`。

### 8.8 日出日落

使用当天的：

```text
daily.astro[1].sunrise.time
daily.astro[1].sunset.time
```

放在 panel 底部，和更新时间、数据来源并列显示。

## 9. 异常状态和交互

### 未配置

bar 显示：

```text
📍 --
```

panel 显示配置提示：

```text
尚未配置天气位置

请前往：设置 → 插件 → Caiyun Weather
填写纬度和经度。
```

可以提供“打开插件设置”按钮，调用 Noctalia 的插件设置入口。

### 加载中

首次没有缓存数据时显示：

```text
正在获取天气数据…
```

### 请求失败

没有旧数据时显示错误卡片：

```text
无法获取天气数据
HTTP 状态：xxx

[重试]
```

有旧数据时保留旧内容，并显示：

```text
数据更新失败，当前显示的是上一次成功结果
[重试]
```

### 天气预警

当 `result.alert.content` 非空时，在当前天气卡片下方显示醒目的预警卡片。

预警字段可能随 API 版本变化，因此实现时应：

- 优先读取已知字段；
- 对缺失字段提供通用文本回退；
- 单个字段异常时不影响其他天气信息显示。

### 手动刷新

panel 顶部提供刷新按钮：

- 刷新按钮进入短暂 loading 状态；
- 请求完成后恢复；
- 请求失败时保留旧数据并提示错误；
- 不允许连续点击产生大量并发请求。

## 10. 本次实现范围

第一版实现：

- 经纬度设置；
- 固定 API Key；
- bar 图标和当前温度；
- 点击打开 panel；
- service 统一请求和缓存；
- 当前天气；
- 两小时短临降水；
- 未来 6～8 小时；
- 未来 5 天；
- AQI 和主要污染物；
- 生活指数；
- 日出日落；
- 天气预警；
- 手动刷新；
- 未配置、加载、过期和错误状态；
- 中文界面和基础英文翻译。

暂不实现：

- 自动定位；
- 多地点切换；
- 自定义 API Key；
- 温标切换；
- 历史天气；
- 地图；
- 复杂的高级设置。

## 11. 实现后的验证计划

实现代码后需要验证：

1. 正确构造 `longitude,latitude` 请求路径；
2. 经纬度为空、非法和越界时不发起请求；
3. API 成功响应可以正确解析；
4. HTTP 错误、API 错误和 malformed JSON 不会导致 entry 崩溃；
5. API 没有预警和存在预警时都能正常渲染；
6. bar 横向和纵向布局都可用；
7. panel 在小屏幕上可以滚动；
8. panel 打开、关闭、刷新和重新打开行为正确；
9. 网络失败时仍能显示上一次成功数据；
10. 经纬度设置修改后能立即刷新；
11. 多个 bar 实例不会重复发起相同请求；
12. 使用 Noctalia 插件校验流程验证 manifest、翻译和 catalog 信息。

当前文档阶段不创建实现代码，也不修改现有插件。