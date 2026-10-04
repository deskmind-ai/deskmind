// Every user-visible string of both apps, in one place for a translator to review.
//
// The English text is the key and the fallback; `zh` holds its Simplified Chinese. Arguments go through
// String(format:) -- %@ for strings, %d for integers, %.1f and friends for numbers, and positional specifiers
// (%1$@, %2$@) where the two languages put them in a different order. Nothing here translates data: task titles
// from the task YAML, and app names macOS already reports in its own language, pass through as they are.
//
// Compiled into both executables. The main app chooses the language (Settings: English by default); the helper
// has no settings of its own and speaks whatever the main app's last request asked for (the "lang" field).

import Foundation

/// The user's choice, as stored in the main app's defaults under "language".
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, zhHans = "zh-Hans"
    var id: String { rawValue }

    var resolved: ResolvedLang {
        switch self {
        case .en: .en
        case .zhHans: .zhHans
        case .system: ResolvedLang.fromSystem()
        }
    }
}

/// A language the strings actually exist in.
enum ResolvedLang: String {
    case en, zhHans = "zh-Hans"

    /// Any Chinese in the user's preferred languages (zh-Hans, zh-Hant, zh-CN, ...) reads Simplified Chinese;
    /// anything else reads English.
    static func fromSystem() -> ResolvedLang {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zhHans : .en
    }

    /// The language for code outside a view: the main app keeps it in step with its setting, the helper sets it
    /// from every request. English until then.
    nonisolated(unsafe) static var current: ResolvedLang = .en
}

/// The string for `key` in `lang`, with `args` formatted in.
func L(_ key: String, _ args: CVarArg..., lang: ResolvedLang) -> String {
    let template = lang == .zhHans ? (L10n.zh[key] ?? key) : key
    // No arguments: return the text as is, so a literal "%" can never be read as a specifier.
    return args.isEmpty ? template : String(format: template, arguments: args)
}

enum L10n {
    static let zh: [String: String] = [
        // MARK: Brand, language picker
        "Follow system": "跟随系统",
        "Language": "语言",

        // MARK: Onboarding (Main/DeskMindApp.swift)
        "Background helper": "后台助手",
        "DeskMind Hands is standing by. Restarting it won't close this window.":
            "DeskMind Hands 在后台待命，重启不影响这个窗口",
        "Starting DeskMind Hands…": "正在启动 DeskMind Hands…",
        "DeskMind Hands isn't running": "DeskMind Hands 没有运行",
        "Launch": "启动",
        "Allow": "授权",
        "Optional": "可选",
        "Ready": "已就绪",
        "Developer tools": "开发者工具",
        "Hide developer tools": "收起开发者工具",

        // MARK: Local model row
        "Local model": "本地模型",
        "Verifying %@…": "正在校验 %@…",
        "DeskMind Brain is running on this Mac. Nothing leaves it.": "DeskMind Brain 已在本机运行，所有推理都不出本机",
        "Loading the model into memory… %d s so far (usually about 30 s)":
            "正在把模型载入内存… 已用 %d 秒（通常 30 秒左右）",
        "Needs a model download: 0.8B + 4B, about 5.3 GB": "需要下载模型：0.8B + 4B，约 5.3 GB",
        "The model server didn't start. Click “Retry”.": "模型服务没能启动。点「重试」。",
        "Waiting for the helper to start": "等待助手启动",
        "estimating": "估算中",
        "under a minute": "不到 1 分钟",
        "about %d min": "约 %d 分钟",
        "Paused. Progress is saved.": "已暂停，进度已保存",
        "Downloading %@": "正在下载 %@",
        "Pause": "暂停",
        "Resume": "继续",
        "Download": "下载",
        "Re-download": "重新下载",
        "Retry": "重试",
        "%.2f / %.2f GB · %.1f MB/s · %@ left": "%.2f / %.2f GB · %.1f MB/s · 剩余 %@",

        // MARK: Developer tools, log lines
        "Capture test": "截图测试",
        "Restart helper": "重启助手",
        "Open log": "打开日志",
        "Helper pid %@ · up %@ s": "助手 pid %@ · 已运行 %@ 秒",
        "Helper updated": "助手已更新",
        "Installed the helper in %@": "已安装助手到 %@",
        "Couldn't install the helper: %@": "安装助手失败：%@",
        "Couldn't start the helper: %@": "启动助手失败：%@",
        "Helper connected (pid %@)": "助手已连接（pid %@）",
        "Helper disconnected. Waiting to reconnect…": "助手断开，等待重连…",
        "no response": "无回应",
        "Automation: %@": "自动化：%@",
        "%@: %@": "%@：%@",

        // MARK: Permissions (Main/GrantPanel.swift)
        "Accessibility": "辅助功能",
        "Screen Recording": "屏幕录制",
        "Automation": "自动化",
        "Reads the buttons and text in windows, and clicks and types for you": "读取窗口里的按钮和文字，并替你点击、输入",
        "Sees what's on screen, to tell how far a task has got": "看见屏幕上的内容，判断任务进行到哪一步",
        "Lets Finder and TextEdit save and move files in the background": "让访达和文本编辑在后台保存、移动文件",
        "“%@” is allowed": "「%@」已授权",
        "Restarting the helper to apply it…": "助手正在重新启动以生效…",
        "You can go back to DeskMind now.": "可以回到 DeskMind 了。",
        "Added. Now turn on the switch next to “DeskMind Hands”": "已添加，打开「DeskMind Hands」旁边的开关",
        "This confirms itself once the switch is on": "开关打开后这里会自动确认",
        "Drag the icon on the right into the “%@” list above": "把右边的图标拖进上方「%@」列表",
        "Then turn on the switch next to it": "再打开它旁边的开关",
        "Drag into the list in System Settings": "拖到系统设置的列表里",

        // MARK: Examples screen (Main/RunView.swift)
        "Real run · the local model works in %@ inside a sandbox folder, never touching your files":
            "真实操作 · 本地模型在沙盒文件夹里操作%@，不碰你的文件",
        "Mock desktop · works on virtual windows in memory, never touching your files":
            "模拟桌面 · 只在内存里的虚拟窗口上操作，不会碰你的文件",
        "6 smoke tests": "6 个冒烟任务",
        "Mock desktop": "模拟桌面",
        "Make a new folder": "新建一个文件夹",
        "%@ isn't installed on this Mac. Install it, or name an app you have.": "这台 Mac 上没有安装%@。请先安装，或换成已有的应用。",
        // The mock desktop's six smoke tasks (Shared/SelfTest.swift).
        "Rename a file and keep its contents": "重命名文件并保留内容",
        "Open a document, add a line and save": "打开文档、追加一行并保存",
        "Type Chinese text exactly": "中文普通文本逐字写入",
        "Finish without wiping the clipboard": "完成任务且不破坏用户剪贴板",
        "Start no new write after a cancel": "取消后不得启动新的写操作",
        "Find the window again after it moves": "窗口移动后重新定位再动手",
        "Move a file into a folder": "把文件移进已有文件夹",
        "Sort files by type": "按类型归档文件",
        "Type exact Chinese text and save": "中文精确写入并保存",
        "Finder": "访达",
        "TextEdit": "文本编辑",
        "The local model is still loading. One moment.": "本地模型还在载入，稍等片刻",
        "Preparing the sandbox and starting the local model…": "正在准备沙盒并启动本地模型…",
        "Starting the Python runtime…": "正在启动 Python 运行时…",
        "Pick a task and click “Start”": "选一个任务，点「开始」",
        "Details": "详细信息",
        "Back": "返回",
        "Stop": "停止",
        "Start": "开始",
        "Run again": "再跑一次",
        "Not started": "待开始",
        "Running %.1fs": "运行中 %.1fs",
        "Not finished": "未完成",
        "Passed": "通过",
        "Failed": "未通过",
        "What it saw at this step (click to enlarge)": "它做这一步时看到的画面（点击放大）",
        "Task": "任务",
        "Can't reach the helper": "连不上助手",
        "The helper cut this run short": "助手中断了这次运行",
        "Exit code %d\n%@": "退出码 %d\n%@",
        "%d/%d tasks passed": "%d/%d 个任务通过",
        "Task done, and the result checks out": "任务完成，结果已通过检查",
        "Something went wrong": "出错了",
        // RunModel.friendly(): a failed run in one sentence the user can act on.
        "The helper seems to have lost its permissions. Check “Accessibility” and “Screen Recording” on the home screen, then run it again.":
            "助手的权限好像失效了：回到首页检查「辅助功能」「屏幕录制」，然后再跑一次。",
        "Couldn't see the window this time (it happens when the Mac is busy). Wait a moment and run it again.":
            "这次没能读到窗口的画面（机器太忙时会这样）。稍等一下再跑一次。",
        "The local model couldn't handle this step. Please report it on GitHub so it can be fixed.":
            "本地模型处理不了这一步。请到 GitHub 报告，方便我们修复。",
        "The local model couldn't handle this step (%@). Please report it on GitHub so it can be fixed.":
            "本地模型处理不了这一步（%@）。请到 GitHub 报告，方便我们修复。",
        "The local model didn't answer in time. Check that “Local model” is ready on the home screen, then run it again.":
            "本地模型没有及时回应。确认首页的「本地模型」已就绪，再跑一次。",
        "The last task is still running. Wait for it to finish, or click “Stop” first.":
            "上一个任务还在进行，等它结束或先点「停止」。",

        // MARK: Results of the user's own instruction (Main/RunView.swift FreeResult)
        // The file example names the sample files the helper seeds in each language.
        "Make a folder called Receipts and move expenses.csv into it": "新建一个「报销」文件夹，把 报销单.csv 移进去",
        "Make a folder called Receipts and move %@ into it": "新建一个「报销」文件夹，把 %@ 移进去",
        "Show in Finder": "在访达中显示",
        "Reset folder": "重置文件夹",
        "Cancel": "取消",
        "Finished": "已结束",
        "Finished. Check what changed in DeskMind.": "已结束，请回到 DeskMind 检查改动。",
        "Stopped before finishing. Check what changed in DeskMind.": "没做完就停下了，请回到 DeskMind 检查改动。",
        "Created": "新建",
        "New folder": "新文件夹",
        "This Mac has %.0f GB of memory. The local model needs about 7 GB while it runs, so it may be slow or fail to load; quit other apps before starting.": "这台 Mac 只有 %.0f GB 内存。本地模型运行时约占 7 GB，可能很慢或加载失败；开始前请先退出其他应用。",
        "Only %.1f GB of disk space is free. The download needs about 7.5 GB free; free up some space first.": "磁盘只剩 %.1f GB。下载模型需要约 7.5 GB 可用空间，请先腾出空间。",
        "Moved": "移动",
        "Paused while you use your Mac": "你在用电脑，已暂停，停手后继续",
        "Using your mouse and screen for now": "正在使用你的鼠标和屏幕",
        "Let it use the Mac · 5 min": "交给它用 5 分钟",
        "For the next 5 minutes DeskMind brings apps forward and uses the mouse without waiting for you": "接下来 5 分钟，DeskMind 会直接把应用切到前台并使用鼠标，不再等你停手",
        "Give it back": "收回",
        "DeskMind needs the screen for a moment": "DeskMind 需要用一下屏幕",
        "Waiting until you're done (until %@)": "等你用完（到 %@）",
        "Taking the screen in %d s": "%d 秒后开始使用屏幕",
        "Waiting for a still mouse": "等你停下鼠标",
        "I need it back": "我要用",
        "Go ahead now": "现在就用",
        "I'm using it · 5 min": "我在用 · 5 分钟",
        "This app only responds when it is in front. DeskMind brings it forward for a second or two per step and then gives your app back.": "这个应用只在前台时才响应操作。DeskMind 每一步会把它切到前台一两秒，然后把你的应用还给你。",
        "Next: %@": "下一步：%@",
        "This app only responds when it is in front, so DeskMind waits until you leave the mouse and keyboard alone for a few seconds.": "这个应用只在前台时才响应操作，所以 DeskMind 会等你几秒钟不动鼠标键盘时再做。",
        "Got stuck: the same step kept failing, so DeskMind stopped. Check what changed below.": "卡住了：同一步一直失败，DeskMind 已停下。请查看下面的改动。",
        "Open-source notices": "开源许可",
        "Renamed": "重命名",
        "Name the new folder %@": "给新文件夹起名 %@",
        "Create the folder": "新建文件夹",
        "Move %1$@ into %2$@": "把 %1$@ 移到 %2$@",
        "Save": "保存",
        "Undo the last change": "撤销上一步",
        "Name the file %@": "文件名填 %@",
        "Choose where to save it": "选择保存位置",
        "Save it as a new file": "另存为新文件",
        "Start a new document": "新建文稿",
        "Change the Finder view": "切换 Finder 显示方式",
        "Modified": "修改",
        "Deleted": "删除",
        "No files changed": "没有文件被改动",
        "Did it do what you asked?": "它做对了吗？",
        "Saved on this Mac.": "已记在这台 Mac 上。",
        "What went wrong?": "哪里不对？",
        "It did what I asked": "做对了",
        "It didn't do what I asked": "没做对",
        "It guessed instead of asking": "它没问就猜了",
        "Wrong result": "结果不对",
        "It got stuck": "卡住了",
        "Report on GitHub": "在 GitHub 上反馈",
        "Opens a GitHub issue for you to check and submit. Nothing is sent from DeskMind.":
            "会打开一个 GitHub issue 页面，由你检查后提交；DeskMind 不会发送任何内容。",
        "This run hit an error. Run it again; if it keeps happening, report it on GitHub.":
            "这次运行出错了。再跑一次；如果反复出现，请在 GitHub 上反馈。",
        "Report an Issue…": "反馈问题…",
        "DeskMind on GitHub": "GitHub 上的 DeskMind",
        "Self-test": "自检",

        // MARK: Home (Main/HomeView.swift)
        "What should DeskMind do?": "让 DeskMind 帮你做什么？",
        "Everything runs on this Mac, offline.": "所有操作都在本机完成，不联网。",
        "Finish the setup below first.": "先完成下面的准备。",
        "Describe a task in your own words…": "用你自己的话说说要做什么…",
        "Attach folder": "附加文件夹",
        "Attach": "附加",
        "Use the sample folder": "用示例文件夹",
        "Sample folder": "示例文件夹",
        "Remove the folder": "移除文件夹",
        "Reset": "重置",
        "DeskMind will only change files inside this folder.": "DeskMind 只会改动这个文件夹里的文件。",
        "That isn't a folder. Drop or choose a folder.": "这不是文件夹。请拖入或选择一个文件夹。",
        "Pick a folder inside your home folder, not the whole home folder or a system folder.":
            "请选择个人文件夹里的某个文件夹，不能是整个个人文件夹或系统文件夹。",
        "Put the sample folder back to its sample files? Everything else in it is removed.":
            "把示例文件夹恢复成示例文件？里面的其他内容都会被删除。",
        "Which app should it use? Name it in the instruction, or attach a folder.":
            "要在哪个应用里做？请在指令里说出应用名，或者附加一个文件夹。",
        "The instruction names %@, but no folder is attached. Attach the folder they're in, or open them first.":
            "指令里提到了 %@，但没有附加文件夹。请附加它们所在的文件夹，或者先打开这些文件。",
        "The instruction names files, but no folder is attached and none of them is open. Attach the folder they're in, or open them, then run it again.":
            "指令里提到了文件，但没有附加文件夹，这些文件也没有打开。请附加它们所在的文件夹，或者先打开它们，再运行一次。",
        "Use %@": "使用 %@",
        "Or type an answer": "或者输入回答",
        "Uses": "将使用",
        "· no files will be changed": "· 不会改动任何文件",
        "· files only in the attached folder": "· 只改动附加文件夹里的文件",
        "Recent": "最近的任务",
        "Starting": "启动中",
        "Connecting": "连接中",
        "Model": "加载模型",
        "Vision": "加载视觉",
        "Looking": "观察屏幕",
        "%ds": "%d 秒",
        "Keep DeskMind Open While a Task Runs": "运行任务时保持 DeskMind 窗口打开",
        "Show a Live View of the Task": "显示任务窗口的实时画面",
        // The live view (Helper/LiveCard.swift).
        "DeskMind live view": "DeskMind 实时画面",
        "Click to answer in DeskMind": "点击在 DeskMind 里回答",
        "Larger": "放大",
        "Smaller": "缩小",
        "Collapse": "收起",
        "Stop the task": "停止任务",
        "Working": "工作中",
        "Needs you": "需要你",
        "Paused": "已暂停",
        "Window not visible": "窗口不可见",
        "Starting the recording…": "正在开始录屏…",
        "Next task…": "下一个任务…",
        "Clear all": "全部清除",
        "Remove from the list": "从列表中移除",
        "Show What It Did": "查看这次运行",
        "Show Recording in Finder": "在访达中显示录像",
        "Clear the recent tasks?": "清除最近的任务？",
        "Answer: %@": "答案：%@",
        "Open NetEase Cloud Music, search 张悬 宝贝 and play it": "打开网易云音乐，搜索张悬的《宝贝》并播放",
        "In NetEase Cloud Music, search 夜空中最亮的星 — who sings the first song?":
            "在网易云音乐里搜索《夜空中最亮的星》，第一首是谁唱的？",
        "Open Safari and search for the weather in Singapore": "打开 Safari，搜索新加坡的天气",
        "In Safari, search for the height of Mount Everest — how tall is it?": "在 Safari 里搜索珠穆朗玛峰的高度，它有多高？",
        "Setup · everything is ready": "准备工作 · 全部就绪",
        "Show setup": "展开准备工作",
        "Hide setup": "收起准备工作",

        // MARK: Confirmation sheet (Main/HomeView.swift ConfirmSheet)
        "Before DeskMind starts": "开始之前",
        "Apps it will use": "将要操作的应用",
        "Don't ask again for this app": "这个应用以后不再确认",
        "Folder": "文件夹",
        "No folder — no files will be changed": "没有附加文件夹，不会改动任何文件",
        "Apps that can't be read through accessibility may be brought to the front for a moment. Touching the mouse or keyboard pauses DeskMind.":
            "读不到辅助功能信息的应用可能会被短暂切到前台。运行中动鼠标或键盘会让 DeskMind 暂停。",
        "Optional: for an app whose window can't be read through accessibility (NetEase Cloud Music and the like), DeskMind uses a vision model, a one-time 3.3 GB download. You can start without it.":
            "可选：如果应用的窗口无法通过辅助功能读取（比如网易云音乐），DeskMind 会用视觉模型，需一次性下载 3.3 GB。不下载也可以先开始。",

        // MARK: Vision model row (Main/HomeView.swift EyesRow)
        "Vision model": "视觉模型",
        "For apps without accessibility (NetEase Cloud Music and the like). Download 3.3 GB":
            "用于没有辅助功能信息的应用（比如网易云音乐）。需下载 3.3 GB",
        "For apps without accessibility. Loaded only while a task needs it.": "用于没有辅助功能信息的应用，只在任务需要时载入",
        "Download 3.3 GB": "下载 3.3 GB",

        // MARK: A run of the user's own instruction (Main/GoalRunView.swift)
        "No folder": "无文件夹",
        "Edit": "修改",
        "Use this instruction": "用这条指令",
        "Loading the vision model…": "正在载入视觉模型…",
        "Starting the local model and the apps…": "正在启动本地模型和应用…",
        "Connecting to the helper…": "正在连接助手…",
        "Loading the local model…": "正在载入本地模型…",
        "Looking at the screen and choosing the first step…": "正在查看屏幕、决定第一步…",
        "%d s": "%d 秒",
        "(usually about %d s)": "（通常约 %d 秒）",
        "No steps": "没有步骤",
        "Waiting for you": "等你回复",
        "DeskMind has a question": "DeskMind 有个问题",
        "DeskMind needs your approval": "DeskMind 需要你的批准",
        "Record this run": "录制这次运行",
        "Include DeskMind's Window in Recordings": "录制时包含 DeskMind 窗口",
        "Record the Whole Screen": "录制整个屏幕",
        "Only the apps this task uses are recorded, other apps stay out; it goes to Movies › DeskMind.": "只录制这次任务用到的 app，其他 app 不会出现；录像保存在“影片 › DeskMind”。",
        "Recorded": "已录制",
        "Watch": "观看",
        "Show Decisions While Running": "运行时显示决策浮层",
        "Step %d": "第 %d 步",
        "decided in %d ms": "决策 %d ms",
        "4B · %@": "4B · %@",
        "0.8B unsure": "0.8B 不确定",
        "checking before done": "完成前复核",
        "checking a key": "复核按键",
        "Sending, deleting, paying, publishing or sharing waits for your approval first.": "发送、删除、付款、发布或分享之前，都会先等你批准。",
        "Approve": "批准",
        "Deny": "拒绝",
        "Your answer": "你的回答",
        "Send": "发送",
        "Answer": "答案",
        "Finished.": "已完成。",
        "Stopped before finishing.": "没做完就停下了。",
        "Got stuck: the same step kept failing, so DeskMind stopped.": "卡住了：同一步一直失败，DeskMind 已停下。",
        "Getting ready…": "正在准备…",
        "Waiting for your answer in DeskMind": "在 DeskMind 窗口里等你回答",
        "Waiting for your approval in DeskMind": "在 DeskMind 窗口里等你批准",
        "Got your answer. Carrying on…": "收到回复，继续…",
        "Asked for your approval": "请你批准",

        // MARK: Run overlay and notifications (Main/RunOverlay.swift)
        "Preparing the sandbox…": "正在准备沙盒…",
        "DeskMind is getting ready": "DeskMind 正在准备",
        "DeskMind is working in %@": "DeskMind 正在操作 %@",
        "Done": "完成了",
        "Couldn't finish": "没能完成",
        "Didn't finish": "没做完",
        "Stopped": "已停止",
        "Show Details": "查看详情",
        "Dismiss": "关闭",
        "· Step %d": "· 第 %d 步",
        "Stop this task (or press ⌘. in the DeskMind window)": "停止这次任务（在 DeskMind 窗口里也可以按 ⌘.）",
        "DeskMind finished the task": "DeskMind 完成了任务",
        "Port %d is used by another program, so DeskMind will not talk to it. Quit that program (or restart the Mac), then click “Retry”.":
            "端口 %d 被其他程序占用，DeskMind 不会和它通信。请退出那个程序（或重启 Mac），然后点“重试”。",
        "This also deletes their step screenshots and records from this Mac. Recordings stay in Movies › DeskMind.":
            "同时会从这台 Mac 上删除这些任务的步骤截图和运行记录。录像会保留在“影片 › DeskMind”里。",
        "Found it useful? Star DeskMind on GitHub.": "觉得有用？在 GitHub 上给 DeskMind 点个 star。",
        "Star on GitHub": "去 GitHub 点 star",
        "Don't show again": "不再显示",
        "DeskMind couldn't finish the task": "DeskMind 没能完成任务",

        // MARK: Model download failures (Main/ModelDownloader.swift)
        "downloaded files": "已下载的文件",
        "No model list to download": "没有可下载的模型清单",
        "Not enough disk space: %.1f GB needed, only %.1f GB free": "磁盘空间不够：还需要 %.1f GB，现在只剩 %.1f GB",
        "Download interrupted: %@ (click again to pick up where it stopped)": "下载中断：%@（再点一次会接着下载）",
        "The download server refused the request (HTTP %d). Try again later.":
            "下载服务器拒绝了请求（HTTP %d），请稍后再试。",
        "Download failed (HTTP %d): %@": "下载失败（HTTP %d）：%@",
        "Checksum mismatch: %@ (deleted, please retry)": "校验失败：%@（已删除，请重试）",
        "Couldn't write %@: %@": "无法写入 %@：%@",

        // MARK: Step texts (Helper/Runner.swift humanize())
        // How a UI element's label is quoted inside a step.
        "“%@”": "「%@」",
        "Type %2$@ into %1$@": "在%1$@里输入%2$@",
        "Add %2$@ to the end of %1$@": "在%1$@末尾追加%2$@",
        "Change the text in %1$@ to %2$@": "修改%1$@里的文字为%2$@",
        "Click %@": "点击%@",
        "Open %@": "打开%@",
        "Choose %2$@ in %1$@": "在%1$@里选择%2$@",
        "Scroll %@": "滚动%@",
        "Press %@": "按下 %@",
        "a key": "按键",
        "Switch to another window": "切换到另一个窗口",
        "Switch to another app": "切换到另一个应用",
        "Finish the task": "完成任务",
        "Stuck, so it stopped": "无法继续，停下来了",
        "Asked you a question": "向你提了一个问题",
        "Give the answer": "给出答案",
        "The local model isn't ready yet (%@). Please try again in a moment.": "本地模型还没就绪（%@），请稍后再试",

        // MARK: Model server hints (Helper/BrainServer.swift diagnose())
        "Port %d is taken: an old model server may still be running. Click “Retry” to restart it.":
            "端口 %d 被占用：可能还有一个旧的模型服务没退出。点「重试」会重新启动它。",
        "Not enough memory: the models need about 7 GB free. Quit a few memory-hungry apps, then click “Retry”.":
            "内存不够：模型需要约 7 GB 可用内存。关掉一些占内存的应用后点「重试」。",
        "The model files look incomplete or damaged. Click “Re-download” to check them and fetch what's missing.":
            "模型文件好像不完整或已损坏。点「重新下载」会重新校验并补齐文件。",
        "The model took over 3 minutes to load; the Mac may be busy. Click “Retry” to try again.":
            "模型载入超过 3 分钟还没完成，可能是机器太忙。点「重试」再试一次。",
        "The model server quit unexpectedly. Click “Retry”; if it keeps happening, open the log in Developer tools and send it to us.":
            "模型服务意外退出了。点「重试」；如果反复出现，请在开发者工具里导出日志反馈给我们。",

        // MARK: Helper notes (Helper/HandsHelper.swift)
        "Allow it in System Settings, then restart the helper": "请在系统设置里授权，然后重启助手",
    ]
}
