# 清华 courseX 课程数据抓取与查询

从 [tsinghua.app/courses](https://tsinghua.app/courses)（courseX 课程信息共享计划）抓取的
**2026-2027 学年秋季学期** 全部课程数据，共 **4533 门**（与网站收录数一致），
支持按 **学期 + 上课时间 + 上课地点** 组合筛选。

## 文件说明

| 文件 | 说明 |
|------|------|
| `scrape.ps1` | 爬虫：枚举课程 ID → 抓取详情页 → 导出 CSV。支持断点续传，重复运行只抓增量 |
| `query.ps1` | 查询工具：按学期/星期/节次/周次/地点/关键词筛选 |
| `data/courses_2026-2027-1.csv` | 课程表：一行一门课（学期、课程ID、课程序号、中英文名、教师、时段数、时段原文、链接） |
| `data/schedule_2026-2027-1.csv` | 课表：一行一个"课程×时段"（星期、节次、周次、地点已拆分为独立列，用于筛选） |
| `data/courses_2026-2027-1.jsonl` | 原始解析结果（每行一个 JSON，含完整时段数组） |
| `data/ids_2026-2027-1.txt` | 枚举到的全部课程 ID（4533 个） |

CSV 均为 UTF-8 with BOM，可直接用 Excel 打开。

## 查询示例

```powershell
# 星期二第6节 在 六教 上课的课程
.\query.ps1 -Weekday 二 -Period 6 -Location 六教

# 星期五第3-4节 在 明理楼 的课程（节次按区间重叠匹配）
.\query.ps1 -Weekday 五 -Period 3-4 -Location 明理楼

# 限定学期 + 时间 + 地点
.\query.ps1 -Semester 2026-2027-1 -Weekday 一 -Period 1 -Location 一教

# 按周次筛选（全周/前八周/后八周）
.\query.ps1 -Weekday 三 -Period 2 -Weeks 前八周

# 课程名/教师/课程号关键词
.\query.ps1 -Keyword 经济学通论

# 结果导出为 CSV
.\query.ps1 -Weekday 二 -Period 6 -Location 六教 -Export .\result.csv
```

## 网页 UI

`web/` 目录是纯静态页面（无需后端），数据在 `web/data.json`。

**本地使用**：浏览器 `file://` 协议会拦截数据加载，需起一个本地静态服务器，任选其一：

```powershell
# 方式一：Python（若已安装）
cd web; python -m http.server 8000

# 方式二：Node（若已安装）
cd web; npx serve
```

然后访问 http://localhost:8000 。

**功能**：按学期 / 星期 / 节次（支持 `3-4` 区间）/ 周次 / 上课地点 / 关键词组合筛选，
结果可一键导出 CSV。

## 重新抓取 / 抓取其他学期

```powershell
# 默认抓 2026-2027-1（2026-2027 学年秋季学期）
.\scrape.ps1

# 其他学期：s 参数格式为 "学年-学期序号"，如 2025-2026-3 为 2025-2026 夏季学期
.\scrape.ps1 -Semester '2025-2026-3'
```

原理：网站搜索接口 `GET /courses?s={学期}&q={关键词}` 无结果数量上限，
用 a-z、0-9 及常用汉字作为查询词取并集，直到达到网站公布的课程总数；
再逐个抓取课程详情页（服务端渲染，字段在 HTML 中）解析入库。

## 数据说明

- 字段与网站课程详情页一一对应：学期、课程序号、课程名（中/英）、教师、上课时间地点。
- 一门课可有多个时段，`schedule_*.csv` 中每个时段一行，`slot_raw` 保留原文。
- 源站部分课程（多为北大跨选课，课程号 `PK` 开头）课名为空、时间为 `星期第0节`
  （时间待定）或英文格式 `Section 6 of Thur (Week 7)`，已尽量解析归一化，
  无法确定的字段留空，以原文为准。
