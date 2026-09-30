<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="得心 DeskMind · 得心，应手。" width="760">
  </picture>
</p>

# 得心 · DeskMind

**在你的 Mac 上本地操作电脑、并且知道自己有几分把握的小模型。**

每一步先由 0.8B 模型决定，没把握的交给 4B。每个决定都带概率。目标有歧义时，它先问你，再动手写。在我们的真实桌面评测上，它从没把没做完的任务说成完成。

[English](README.md) · [官网](https://deskmind.dev) · [模型](https://huggingface.co/deskmind) · [讨论区](https://github.com/orgs/deskmind-ai/discussions) · [路线图](ROADMAP.md) · [参与贡献](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md)

<!-- TODO(launch): 换成真实、未剪辑的演示录屏（G18b 素材），保留倍速标注。 -->
<p align="center"><img src="assets/demo.gif" alt="得心在 Mac 上执行真实任务：抄表、遇到歧义先问、播放歌曲的现场版" width="760"></p>

## 三步试用

```bash
# 1. 获取 Brain 和模型   （TODO(launch)：确认公开仓库地址和模型名）
git clone https://github.com/deskmind-ai/brain && cd brain && uv sync --extra mlx
uv run hf download deskmind/brain-4b --local-dir models/brain-4b

# 2. 在 Mac 上启动服务
uv run deskmind-brain-serve --predictor mlx:models/brain-4b --port 8793 --two-stage

# 3. 让它给出一个真实桌面任务的下一步
curl -s localhost:8793/v1/systemone -H 'Content-Type: application/json' -d @examples/request.json
```

返回的是带类型的决定（操作和目标），每个选项都有概率。要让它真正操作桌面，加上 [Hands](https://github.com/deskmind-ai/hands)；完整体验见 [Mac 应用](https://github.com/deskmind-ai/app)。<!-- TODO(launch): 确认 App 可用性表述 -->

## 包含什么

| | 负责 | |
|---|---|---|
| [Brain](https://github.com/deskmind-ai/brain) | 决定下一步 | 0.8B 和 4B，MLX，可选 0.8B → 4B 路由 |
| [Eyes](https://github.com/deskmind-ai/eyes) | 在屏幕上找到目标 | 4B 视觉定位模型 |
| [Hands](https://github.com/deskmind-ai/hands) | 观察并操作 macOS | 辅助功能与视觉两种模式、执行预算、取消 |
| [Bench](https://github.com/deskmind-ai/bench) | 检查是否真的完成 | 沙箱任务和严格的最终状态评分 |
| [App](https://github.com/deskmind-ai/app) | 带到你的 Mac 上 | 原生应用 |

## 成绩

| 项目 | 条件 | 结果 |
|---|---|---|
| 真实桌面任务 | Bench v25，router-g14-q8（0.8B → 4B，8 位），M4 Pro，13 个任务各跑 3 次 | **36/39（92%）**，false DONE 0 次；决策中位数 0.57 秒（不是整项任务时间） |
| 同一 harness 对比 | Bench v23，两者各排除 1 次环境故障 | 得心 **35/38** · Jev 33/38 |
| 决策质量 | JevBench v1.4.2，231 道公开题 | Brain 4B **0.866** · Brain 0.8B **0.706** |
| 视觉定位 | ScreenSpot-Pro，1,581 题，GPU，单次推理 | Eyes **67.7%**（基座 64.8%） |

以上都是我们自己的运行结果；方法和完整表格见 [Bench 参考结果](https://github.com/deskmind-ai/bench/blob/main/results/reference.md) · [Brain](https://github.com/deskmind-ai/brain/blob/main/docs/results.zh-CN.md) · [Eyes](https://github.com/deskmind-ai/eyes/blob/main/docs/results.md)。

## 局限

评测集小，只在一台 Mac、一种界面语言上测过；一项网页提取任务仍未解决；本地 4 位 Eyes 还没有基准分数；公开题成绩不等于 JevBench 密封题成绩。推理默认留在本机，但下载模型和联网应用本身会用网络。正在做的事见[路线图](ROADMAP.md)。

## 认识小方

小方是 logo 里的方框活了过来。素材在 [brand/](brand/)，规则见 [BRAND.zh-CN.md](BRAND.zh-CN.md)。

## 许可

本仓库文档：[CC BY 4.0](LICENSE)。代码：以各组件的 LICENSE、NOTICE 为准。模型权重和数据集各有条款。品牌：[BRAND.zh-CN.md](BRAND.zh-CN.md)。
