# LingoSave 语影（Windows）

LingoSave 是本机视频下载客户端。支持一次粘贴多个网站的视频和 Radio France 播客链接；播放列表按整份列表下载，预览只显示前 20 项。请只保存有权下载的内容。

## 启动

For a fresh Git clone, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-desktop.ps1` to build `LingoSave.exe`. Install `yt-dlp.exe` in `tools\` and `deno.exe` in `tools\deno\`. Put `ffmpeg.exe` and `ffprobe.exe` in `tools\ffmpeg\bin\` or on PATH.

双击本目录的 `LingoSave.exe`。启动器会运行隐藏的 PowerShell 服务，并在 Edge 应用窗口中打开界面。关闭窗口后，托盘服务会继续处理下载；从托盘可重新打开界面或退出。若没有 Edge，启动器依次尝试 Chrome 和系统默认浏览器。

整个项目目录须一起保留，包括 `run.ps1`、`server.ps1`、下载与解析工作脚本、`state-io.ps1`、`history-store.ps1`、`credential-store.ps1`、`site-catalog.ps1`、`sites.json`、`resource-coordinator.ps1`、`resource-pipeline.ps1`、`media-cache.ps1`、`media-normalization.ps1`、`playlist-folders.ps1`、`transfer-slots.ps1`、网页文件和 `tools` 目录。目前没有安装包。首次打开时请稍等本机服务启动；若端口 8765 已占用，启动器会选择其他本机端口。

也可在本目录手动启动：

```powershell
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

然后打开 <http://127.0.0.1:8765/>。直接打开 `index.html` 无法调用下载服务。服务只监听 `127.0.0.1`。

## 使用

1. 在“新建下载”中粘贴 1 至 200 条链接，每行一条，也可粘贴包含链接的文字。播放列表链接会展开并下载其中全部可访问的视频。
2. 勾选“完整视频”“独立音轨”“外部字幕”。默认三项全选：保存可播放的完整视频（带声音、不嵌入字幕），并分别保存选中的音轨和字幕文件。三项可独立选择。仅勾选音轨或字幕时，只下载该资源；确实没有所选资源则提示不可用并跳过，不自动下载视频，也无需先手动解析才能独立下载。多项组合中所选资源缺失时跳过该项、补存完整视频，并保留其他可用的所选资源。例如英语音轨存在而法语字幕缺失，保存完整视频和英语音轨；两者都缺失则只保存完整视频。
3. 点击“解析链接”只预览基础信息。点击某个视频的“解析音轨与字幕”才加载轨道列表，按英文语言名称 A–Z 排序，可直接勾选具体轨道；有效缓存可以复用，也可重新解析。播放列表内的视频也可按需解析。未手动解析时，正式下载仍按语言偏好逐条匹配。播放列表预览仅显示前 20 项，不限制下载范围。
4. 选择视频画质、视频格式和字幕格式。独立音轨保存为 MP3，字幕可保存为 SRT、VTT 或 Word（DOCX）。Word 版去掉时间戳和字幕序号，每句独立一行。保存位置可以手动输入 Windows 绝对路径，也可点“选择文件夹”打开系统目录选择窗口；取消时保留原路径。“设置”页可保存默认目录。
5. 点“加入下载队列”，在“下载任务”查看进度、速度、已下载量和预计剩余时间，以及每个资源的结果。界面每 500 毫秒读取进度，百分比与进度条同步更新。可暂停、继续或取消；合并、转换和校验期间会在安全位置暂停。断网进入等待重连，网络恢复后自动继续；手动暂停的任务始终等待用户继续。重试复用已校验成品和有效下载断点。已完成文件旁的“在文件夹中查看”按钮会将资源管理器显示在应用前面，选中实际保存文件并滚动到该文件；文件被移动或删除时打开原保存目录。
6. “链接历史”分别提供最近输入和失败记录。输入历史按单条来源链接去重保留最近 10 条，播放列表只计一条；可以复制、回填、删除或清空。失败记录独立持久保存，显示失败资源、原因和次数，可只重试失败视频；原失败资源全部恢复后标为已恢复。清除历史不会删除成品、任务或断点。
7. 下载任务默认同时运行 3 个，可在任务页调整为 1–5 个。同一批次或播放列表内的视频也可并行下载，所有批次共享实际下载名额，默认 3 个、最多 4 个；选择 5 个任务时第五个会等待下载名额。可清除单条已结束任务或全部已结束记录，进行中和暂停的任务会保留；清除记录保留下载文件及独立链接历史。播放列表预览及任务明细限制高度，长列表可上下滚动查看。
8. 右击托盘图标可查看当前任务的标题、状态和进度，并直接退出。托盘最多显示 6 个任务，更多任务可打开应用查看。

需要登录的网站可在“设置 → 网站 Cookie”按 YouTube、Bilibili、ARTE 分别导入 Netscape 格式 `cookies.txt`。应用只保留所选网站的 Cookie，以当前 Windows 用户的 DPAPI 加密保存在应用数据目录。界面显示“待验证”表示文件格式通过检查；实际访问能力需解析或下载确认。下载时会临时解密并在任务结束后清理。Cookie 不能绕过会员权限、地区限制、DRM 或节目下架。

ARTE 的 HLS 音轨即使没有声明音频编码，也会按播放器的音轨名称识别。法语、德语、多语言及法语/德语口述音轨分别列出，按英文语言名称 A–Z 排序；默认按语言偏好选普通音轨，口述音轨可以单独勾选。旧的完整媒体缓存也会经过同样的识别处理。

Bilibili 解析会主动查询外挂字幕；弹幕 XML 不作为外挂字幕列出。网站提示字幕需要登录时，界面显示“外部字幕（需登录）”，请导入有效的 Bilibili Cookie 后重新解析；该提示不会被误写成“无字幕”。字幕需要登录时，只记录字幕资源失败，其他已选择且可用的视频与音轨继续下载。

播放列表会在所选保存目录下自动创建以列表标题命名的子文件夹，视频、独立音轨和字幕一起保存其中；同名目录追加 `(2)` 等数字，暂停、继续及失败重试沿用已分配的文件夹。单条视频产物写入所选目录。默认设置、任务状态和浏览器应用配置存于 `%LOCALAPPDATA%\LingoSave`；也可在启动前设置 `LINGOSAVE_DATA_DIR`。首次使用默认数据目录时，程序会从项目内旧版 `.lingosave-data` 迁移任务和设置（仅当目标尚不存在）。启动错误写入数据目录下的 `startup-error.log`。成品按标题命名，例如 `标题.mkv`、`标题.fr.mp3`、`标题.fr.srt`；同名文件自动增加 `(2)` 等序号，避免并行任务互相覆盖。

退出托盘会停止服务；未完成任务在下次启动后重新排队，手动暂停的任务保持暂停。有效断点保存于下载目录下 `.lingosave-partials`，请保留到任务完成。程序复用通过校验的成品与有效片段；续传取决于网站和协议，不支持 Range 的来源会重新下载当前未完成文件。状态和历史使用共享读取、串行原子替换和有限重试，诊断写入对应 `.io.log`。

## 下载速度优化（第一轮）

- DASH/HLS 原生分片并发从 2 调整为 4。普通 HTTP 单文件沿用网站支持的续传方式。
- 批量链接和播放列表按视频调度。实际网络下载、媒体处理和元数据解析分别限流：默认 3 个下载、2 个合并/转换、2 个解析。同一批次最多安排 5 个在途视频，其余等待；多个批次共享这些名额。
- 下载与合并/转换交错进行。视频传输结束后立即释放下载名额，其他视频可以继续下载；当前视频在独立处理名额内合并为完整视频或转换为 MP3。视频合并使用流复制，保持原画质。处理先写临时文件，成功并校验后再发布成品；取消或失败留下的处理中产物不会被当作已完成文件。
- 完整视频与独立音轨选择了同一个原始格式时，仅传输一次音频流，再分别合并视频和生成 MP3。不同语言或不同格式保持独立。
- 完整元数据缓存有效期为 5 分钟，按链接与网站 Cookie 版本隔离；已过期或接近到期的媒体地址重新解析。遇到签名地址过期会刷新地址，核对媒体 ID、格式和已知内容信息后再续传。
- 暂停会阻止新增下载；正在合并或转换的资源完成当前安全处理后暂停。有效原始流、成品、Range 字节断点和 HLS 分片记录可复用。升级前的兼容断点也会被接入新流程；资源格式改变时保留旧断点并重新下载当前资源。

实际提速取决于带宽、站点限速、连接延迟与本机磁盘。并发优先提高批量吞吐量；此轮保持既有画质和 MP3 输出设置。

## 依赖与构建

- 项目自带 `tools\yt-dlp.exe` 和 `tools\deno\deno.exe`。
- FFmpeg 优先从 `tools\ffmpeg\bin` 查找，其次是 `LINGOSAVE_FFMPEG_DIR` 指定的目录、系统 `PATH`，最后尝试 `E:\ffmpeg\bin`。ffprobe 同样必须可用。访问 `/api/health` 可查看实际路径与错误。
- 下载服务使用 Windows PowerShell 5.1；系统目录选择窗口需要 STA，`run.ps1` 会处理。
- 正式图标来自 `assets\icons\lingosave-03-brand.png`，保留原文件；`prepare-app-icon.ps1` 缩减外侧透明留白，生成界面 PNG 和 16、20、24、32、40、48、64、80、96、128、192、256 像素的 ICO。EXE 内嵌 `lingosave-app.ico`，窗口、任务栏、托盘及 favicon 使用同内容的 `lingosave-app-v2.ico`。桌面启动器按屏幕 DPI 加载原生图标，并给浏览器承载的窗口设置独立的 LingoSave 任务栏标识及重新启动信息。
- 如需重新生成图标及编译，先从托盘退出，再依次运行 `& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\assets\icons\prepare-app-icon.ps1`、`& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\build-desktop.ps1`、`& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\desktop\refresh-icons.ps1`。使用 Windows 自带的 .NET Framework C# 编译器，不需要 .NET SDK。

## 检查

启动本机服务后运行：

```powershell
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\resource-plan-acceptance.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\arte-audio-plan.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\arte-audio-download.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\arte-audio-selection-api.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\inspect.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\resource-worker-acceptance.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\history-acceptance.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\server-improvements.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\playlist-folders.ps1
& "$PSHOME\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\playlist-folder-integration.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\state-io-acceptance.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\download-stability.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\real-local-resume.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\live-progress.ps1
& "$PSHOME\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\file-location.ps1
& "$PSHOME\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\tray-menu.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\parallel-queue.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\bilibili-resources.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\transfer-slots.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\manual-metadata-cache.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\speed-coordinator.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\speed-cancel-state.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\speed-resources.ps1
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\speed-integration.ps1
```

`tests\resource-worker-acceptance.ps1` 用模拟提取器检查逐文件下载、播放列表、进度和失败文件重试；`tests\async-preview.ps1` 检查异步预览和服务响应；`tests\cookies.ps1` 用合成 Cookie 检查加密与站点隔离。`tests\real-blender-acceptance.ps1` 使用 Blender 发布的开放授权短片做真实网络下载验收，会产生实际媒体文件并在成功后清理临时目录。

新增验收均使用独立临时数据：`history-acceptance.ps1` 检查历史去重与失败资源恢复；`server-improvements.ps1` 检查真实服务 API、重启与路径定位；`state-io-acceptance.ps1` 检查共享读写和文件占用重试；`download-stability.ps1` 检查下载控制和断点。`real-local-resume.ps1` 使用真实 yt-dlp、FFmpeg 和 localhost 限速服务器验证 Range 字节续传、HLS 已完成分片复用及缺片失败，不需要访问外部视频站点。`frontend-v2.mjs` 提供可从 Node 导入运行的 DOM 交互验收函数。`bilibili-resources.ps1` 使用真实 yt-dlp 与本机媒体、字幕验证独立资源下载、字幕登录不足时保留可用媒体、简洁命名和并行同名输出；该验收不证明某个未登录的 Bilibili 视频一定提供字幕。

`live-progress.ps1` 用真实 yt-dlp 和限速 localhost 下载，检查两个下载工作脚本写出的连续中间进度、字节数、速度及处理阶段顺序。`file-location.ps1` 需要交互式 Windows 桌面，通过真实 API 验证资源管理器位于前台、中文及逗号文件名定位、同一窗口复用、多次请求不增加窗口、最小化恢复和文件缺失回退；只打开并关闭测试自建窗口及临时目录。加 `-NoForegroundFixture` 可只显示临时资源管理器窗口。

`transfer-slots.ps1` 检查跨进程共享预算、暂停等待和异常退出后的名额回收；`manual-metadata-cache.ps1` 检查手动解析工作进程保存完整缓存、界面字段保持一致及 Cookie 版本失效。`speed-coordinator.ps1` 检查播放列表内并行、进度聚合、下载转换交错、慢来源解析、暂停恢复和异常子进程清理；`speed-resources.ps1` 用真实 yt-dlp 与 FFmpeg 在 localhost 验证同格式音轨只传输一次、完整视频与独立资源、元数据刷新、旧版断点复用及独立处理预算。`speed-cancel-state.ps1` 检查取消时父快照落后于子任务，已提交成品仍会立即显示且保留断点。`speed-integration.ps1` 检查真实本机服务、协调器、下载工作进程和 FFmpeg 的整体接入。这些测试使用独立临时数据与本地样本，不下载用户任务或访问外部视频站点。

`arte-audio-plan.ps1` 复刻五种 ARTE 音轨缺少编码字段的元数据，检查普通/口述身份、旧版本兼容与默认选择。`arte-audio-download.ps1` 用真实 yt-dlp、FFmpeg 和 localhost 的五种 HLS 音频信号验证精确独立下载、所选音轨的视频合并、音源复用、旧缓存及缺失字幕跳过；不访问外部站点或修改用户任务。

`arte-audio-selection-api.ps1` 通过独立本机服务验证五种 ARTE 音轨的真实 ID 提交，包括法语 Unicode 字符、最近解析结果匹配、精确身份保留和非法选择拒绝；不影响用户下载。

`playlist-folders.ps1` 检查真实目录创建、标题清理、同名编号、目录映射复用和跨进程分配；`playlist-folder-integration.ps1` 通过隔离 API、协调器和下载器验证播放列表的三类产物、共享视频、暂停继续，以及清除任务后从失败历史恢复到原文件夹。这些检查不访问用户下载或外部站点。

## Radio France 播客

支持 `radiofrance.fr` 的播客单集和系列（France Culture、France Inter、France Info、France Musique、FIP、Mouv）。粘贴链接即可解析，系列会展开所有分集，自动在保存目录下创建系列标题文件夹，并按分集标题保存为 MP3，例如 `Épisode 1_5 · La veillée.mp3`。保留网站给出的分集编号；同名文件照常编号避免覆盖。

广播节目自动识别为音频，无需取消默认的视频与字幕选项；单独请求不存在的字幕会跳过，不会额外下载音频。支持现有并行、进度、暂停继续、失败记录和重试。音频下载完成后可通过文件夹按钮定位文件。

站点适配通过 `tools/yt-dlp-plugins/lingosave` 加载，必须与 `tools/yt-dlp.exe` 一起保留。兼容网页结构化音频及官方播放器 AOD 接口；使用公开页面中的标题和分集信息，解析网页数据时不执行网页 JavaScript。网站尚未提供音源或限制下载时，任务显示原因，可稍后重试。

验收：在 Windows PowerShell 5.1 中运行 `tests/radio-france.ps1`，通过独立服务、真实 yt-dlp/FFmpeg 和 localhost MP3 检查系列、播放器音源、文件命名及仅音频输出，不下载用户节目。

## 视频网站

支持 YouTube、Bilibili、ARTE，以及新增的 Vimeo、Dailymotion、TED、X / Twitter、Facebook、Instagram、TikTok、抖音、小红书、AcFun、央视网；Radio France 继续支持播客。界面从服务读取平台名单和 Cookie 设置，支持常见分享短链接。播放列表的数量与展开能力取决于网站和提取器返回的信息。

新平台沿用视频、独立音轨和字幕选择，英文语言名称排序，播放列表目录、并发下载、进度、暂停继续及失败历史。Vimeo、Dailymotion 等列表只有条目 ID 时，会恢复其视频页面链接，避免丢失分集。仅音轨或字幕时仍不会擅自保存完整视频。

当前实站核对：TED 已适配网页新的 `videoPlayerData` 字段；明确无画面的 HLS 音轨即使缺少编码名称，也能正常列出和下载。Vimeo 的现有提取器要求登录 Cookie；本轮 Dailymotion 样例曾成功解析，后续媒体清单访问返回 HTTP 403，外网完整下载验收未通过，不能据此保证该站点所有视频可下载。Instagram 当前优先使用帖子或 Reels 链接，账号主页提取器不可用。网站要求登录时，可在“设置”的对应网站卡片导入 Cookie；导入成功并不等同于网站已允许访问。

平台识别和域名范围统一配置在 `sites.json`，由 `site-catalog.ps1` 供服务、预览、轨道解析和下载器共享。Cookie 只保留匹配平台域名的条目，并沿用 Windows 用户加密和临时文件清理。`tools/yt-dlp-plugins/lingosave` 包含 Radio France 与 TED 兼容适配，搬动项目时须一并保留。

验收：`tests/site-catalog.ps1` 检查平台识别、短域名、域名边界和实际 DPAPI 凭据隔离；`tests/multi-site-integration.ps1` 用独立服务和合成输出检查十一新平台完整流程；`tests/multi-site-media.ps1` 检查通用 HLS 音频与静音、缩略图的区别；前端验收检查动态平台列表和 Cookie 控件。这些验收不访问用户任务。`tests/real-dailymotion.ps1` 是可选的真实外网 25 秒公开样例下载检查，受网站访问和网络状态影响，成功后清理测试视频。

## 当前边界

- 可用格式、音轨和字幕取决于网站返回的数据；字幕的“网站字幕”来源不一定能证明由人工制作。真实网站可能限制访问、变更格式或拒绝自动字幕下载。
- 多站点多音轨与字幕的真实样本仍需逐站回归。Cookie 导入窗口和系统目录选择窗口尚需人工点选验收。
- 本机服务打开系统目录选择窗口时可能暂时阻塞其他接口请求，选择或取消后恢复。
- 本版本依赖本机浏览器、项目脚本与工具，没有安装器或自动更新。

音频输出支持“原始音频”和“MP3”多选，新任务默认原始音频。原始音频保留原编码，必要时仅无损提取；同时选择时复用原始下载缓存。原资源已经是 MP3 时直接保存；两项都选则分别保存，文件名冲突按现有规则编号。已有任务继续使用原 MP3 设置以保留恢复兼容性。
