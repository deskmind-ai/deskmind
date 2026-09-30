<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="得心 DeskMind · 得心，应手。" width="760">
  </picture>
</p>

# 得心 · DeskMind

**得心，应手。 · See. Think. Act.**

**知道自己有几分把握的小模型。** 每一步先由 0.8B 模型决定，没把握时交给 4B。每个决定都是带类型的，每个选项都有概率。目标可能有不止一种意思时，得心会先问你，再动手写。在我们的真实桌面评测上（v25，router-g14-q8，13 个任务各跑 3 次），39 次运行通过 36 次，没有一次把没做完的任务报告为完成（false DONE 0 次）。

面向 Apple Silicon 的本地优先 computer-use 全栈：用小模型做决策和屏幕定位，用 macOS 执行循环完成操作，以可复现评测检验结果，再通过原生 Mac app 交付完整体验。

[English](README.md) · [路线图](ROADMAP.md) · [参与贡献](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md) · [品牌规范](BRAND.zh-CN.md)

得心正在构建完整的桌面 agent 系统。Brain、Eyes、Hands、Bench 和 App 各自保留清晰接口，既能连成闭环，也能单独研究、替换或接入。我们希望端到端体验真正有用，每个组件的能力也能独立衡量。

**开发状态 · 2026 年 9 月 30 日。** 源码仓库目前为私有；项目文档也注明发布模型仓库仍为私有。下方链接需要相应访问权限，不能视为已经可公开安装。公开产物与干净环境安装流程验证完成后，再更新可用状态。

## 五个组件，一条任务链

| 组件 | 负责什么 | 当前范围 |
|---|---|---|
| [Brain](https://github.com/deskmind-ai/brain) | 决定下一步 | 0.8B / 4B 带类型决策模型、MLX 本地服务、可选双层路由 |
| [Eyes](https://github.com/deskmind-ai/eyes) | 找到屏幕上的目标 | 4B 视觉定位模型、训练与评测工具、实验性本地服务 |
| [Hands](https://github.com/deskmind-ai/hands) | 观察并操作 macOS | 桌面循环、辅助功能观察、视觉后备路径、执行预算与取消 |
| [Bench](https://github.com/deskmind-ai/bench) | 检查是否真的完成 | 沙箱任务、测试素材、严格评分器、分版本参考结果 |
| [App](https://github.com/deskmind-ai/app) | 交付完整 Mac 体验 | 原生应用与承载系统权限的 helper，已有打包开发版本 |

任务从 App 或开发者客户端进入。Hands 观察桌面，Brain 选择带类型的动作，Hands 执行后再次观察；需要定位目标时可以调用 Eyes。Bench 在受控任务中检查最终状态。

并非每个任务都调用 Eyes。Finder 和 TextEdit 可以使用合成的辅助功能投影，因此这类任务的成功本身不能证明纯截图操作能力，也不能单独证明 Eyes 的贡献。

## 从哪里开始

- **体验 Mac 应用：**先看 [App 的要求和设置说明](https://github.com/deskmind-ai/app/blob/main/README.md)。文档要求 Apple Silicon、macOS 15 或以上；当前版本仍需私有模型访问权限。已有打包版本，公开且经独立验证的全新安装路径仍待建立。
- **接入一个组件：**从 [Brain 的结构化决策 API](https://github.com/deskmind-ai/brain/blob/main/README.md)、[Eyes 定位接口](https://github.com/deskmind-ai/eyes/blob/main/README.md) 或 [Hands](https://github.com/deskmind-ai/hands) 开始。Brain 可以先用随仓库提供的请求样例验证接口，再接桌面操作。
- **复现或质疑成绩：**从 [Bench](https://github.com/deskmind-ai/bench) 和准确的[参考配置](https://github.com/deskmind-ai/bench/blob/main/results/reference.md) 开始。本仓库采纳模板后，可以用评测复现表单提交结果。

实验请使用可丢弃的测试文件夹和明确选定的应用。运行前先检查组件要求的权限与数据流向。

## 现在展示到哪一步

仓库报告覆盖了范围明确的 Finder 任务，例如新建文件夹和移动文件，以及 TextEdit 精确编辑、歧义处理和中途取消。这些可以作为可复现演示的候选；目前这里还没有经过审阅的公开录像与可下载演示包。

除了 Finder 和 TextEdit（辅助功能投影），Hands 还有视觉模式，用于没有可用辅助功能结构的应用：用 OCR 和 Eyes 读屏幕，再由 Brain 决策。开发中的运行包括在这种模式下，在一个桌面音乐应用里搜索并播放某首歌的指定版本。这些运行还没有纳入已发布的 Bench 套件。

下一份演示应展示目标、允许操作的应用和文件夹、观察结果、选定动作、最终文件状态与人工介入，并说明哪些步骤用了投影或视觉，也保留失败。拟议的跨应用展示仍是开发目标，需要以具体录像和验证结果确认。

**已知边界：**诊断集中的网页提取任务仍未解决；已报告的真实桌面评测只覆盖一台 Mac 和一种界面语言；其他应用与环境的泛化能力需要继续测试。

## 成绩与适用范围

下列数字来自项目自己的运行报告，尚不代表独立复现。

### 完整桌面任务

最新 Bench 参考结果为 **v25、router-g14-q8：36/39 严格通过（92%）**，环境错误 0 次，false DONE 0 次。配置为 0.8B → 4B、8 位、Apple M4 Pro 48 GB；13 个任务各重复 3 次，开启投影层。

规划决策耗时为 **p50 0.57 秒 / p95 5.25 秒**，不是整项任务完成时间。同一任务的重复运行具有相关性，这个小型诊断集还不能证明广泛的桌面可靠性。

较早的同一 **v23** harness 对照为得心 **35/38**、Jev **33/38**，两者各排除 1 次环境故障。已查阅的参考表没有同版本 v25 Jev 对照，不应把不同 harness 版本混合排名。

[参考结果与定义](https://github.com/deskmind-ai/bench/blob/main/results/reference.md)

### Brain 决策质量

在 **JevBench v1.4.2 的 231 道公开题**上，Brain 4B 报告准确率 **0.866**，Brain 0.8B 为 **0.706**。这只是公开题成绩，尚未建立官方密封题或综合分结果。输出带类型的概率是接口特性，留出集上的概率校准需要单独评估。

[Brain 方法、结果与限制](https://github.com/deskmind-ai/brain/blob/main/docs/results.md)

### Eyes 视觉定位

在 **1,581 道 ScreenSpot-Pro** 上，Eyes 报告 **单次、无缩放 67.7%**；同一推理栈下的 GUI-Owl 基座为 **64.8%**，所测 KV-Ground 对照为 **66.1%**。**两次推理、缩放版本 77.5%** 属于另一种计算预算。

以上设置为单 GPU、vLLM 0.19、bf16、贪心解码、原始分辨率、Qwen3-VL computer-use tool prompt。本地服务则使用 **4 位 MLX、≤2 MP 图像和 point_2d 提示格式；这个部署设置目前没有实测基准分数**。

[Eyes 完整结果与失败分析](https://github.com/deskmind-ai/eyes/blob/main/docs/results.md)

### 下一步想达到什么

我们希望在明确的模型规模、开放程度与计算预算条件下，让小模型决策和视觉定位达到领先水平，同时完成可靠的端到端任务。**SOTA 是研究目标，当前不宣称已经达到。** 做出领先声明前，需要更新候选模型范围、固定协议、公开证据、审查权利与许可，并获得独立复现。[拟议优先事项](ROADMAP.md)

## 本地优先意味着什么

默认本地模型服务路径旨在让推理留在 Mac 上。模型下载需要联网；网络应用中的操作也可能发送数据。开发者配置可以启用远程升级层，它会收到发送给该层的请求。

请以实际配置和组件文档为准。本地推理本身不能证明系统安全，也不代表每个动作都离线。提交报告时，只分享已经脱敏的日志和截图。

## 参与贡献

跨组件问题、复现报告和项目方向，统一从本仓库进入。如果已确定 bug 属于 Brain、Eyes、Hands、Bench 或 App，请在有权限访问的对应子仓库提交，并关联已有的主仓库问题；无法确定归属时，直接在这里报告。

报告内容与分流规则见 [CONTRIBUTING.md](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md)。将来若启用 GitHub Discussions，一般问答和设计讨论可在那里开展；本文不假设它目前已开放。

## 认识小方

小方是 logo 里的方框活了过来。现有素材在 [brand/](brand/)，使用规则见 [BRAND.zh-CN.md](BRAND.zh-CN.md)。

## 许可

- 本仓库文字与文档采用 [CC BY 4.0](LICENSE)
- 代码许可以各组件仓库的 LICENSE、NOTICE 为准
- 模型权重、基座和数据集各有适用条款；代码许可不能单独证明所有产物都可以再分发
- DeskMind、得心、logo 和小方的使用另见[品牌规范](BRAND.zh-CN.md)
