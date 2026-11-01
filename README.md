# Ruinsss格式快转 · V1.0.1 · Beta 19

> 把视频里的声音留下来，也把声音和画面转成更顺手的格式。  
> 作者：**Ruinsss** · 包名：`com.ruinsss.format` · 版本：**V1.0.1 · Beta 19**
>
> GitHub：**[Ruinsss233](https://github.com/Ruinsss233)**  
> 开源仓库：**[Ruinsss233/RuinsssFormat](https://github.com/Ruinsss233/RuinsssFormat)**

一个原生 HarmonyOS（ArkTS + NAPI/C++）的轻量音视频工具：从视频中提取音轨，或把音频、视频转换成主流格式。处理过程流式读写文件描述符，不把大文件读入内存，支持 10GB 以上文件；界面使用原生 ArkUI 的液态玻璃底栏与樱花动态背景。

---

## 1. 功能

- **音轨提取**：从常见视频容器中取第一条音频轨，支持无损直提与解码转码。
- **音频输出**：MP3（320kbps）、FLAC（16-bit）、WAV（PCM 16-bit）、AAC（192kbps ADTS）、AIFF（PCM 16-bit）。源编码匹配时直接封装；不匹配时在设备内解码后编码。**OGG** 仅在源音轨本身为 Opus/Vorbis 时无损转封装，系统没有 Vorbis/Opus 编码器。
- **音频转音频**：选择 MP3 / FLAC / M4A / AAC / WAV / OGG 等音频，输出上述格式之一；OGG 仅支持同源 Opus/Vorbis 无损转封装。
- **视频转视频**：用系统 `AVTranscoder` 把视频转成 MP4，视频编码可选 H.264 / H.265，音频固定 AAC 192kbps。
- **格式边界**：系统原生 API 不支持 AVI / MKV / MOV / WMV / FLV 视频输出，也不支持 WMA / APE 编码；这些格式不会被假装支持，界面和文档都会明确说明。
- **另存为**：使用系统 `DocumentViewPicker` 选择目录和文件名，直接写入目标文件。
- **实时进度**：百分比、已写入体积、耗时、写入速度；低码率输出自动显示 KB/s，不再出现 `0.0 MB/s`。支持取消并清理未完成文件。
- **后台继续**：处理中可切换页签，按 Home 或返回键将 Ability 转入后台，并通过 `DATA_TRANSFER` 持续任务尽量保持进程存活。
- **中断恢复**：源/目标 URI 权限会持久化；进程被系统终止后重新打开，可恢复上次提取（重新封装到原目标，不是字节级续写）。
- **记录与定位**：记录页显示输出格式和源编码；点击“查看位置”直接拉起系统文件管理器并传入文件夹 URI，不再用音频播放器或邮件应用兜底。
- **诊断日志**：本地日志页支持查看最近 60 行、复制全部、清空；日志同时写入应用沙箱文件。
- **樱花动态背景**：所有页面共用樱花天空图，触摸位置生成多层扩散水波和柔光。
- **全玻璃底栏**：五个页签 **提取 / 转换 / 记录 / 日志 / 关于**，半透明渐变、高光描边、弹性选中态。
- **品牌**：提供粉色像素兔图标，界面署名 `Ruinsss`，版本展示 `V1.0.1 · Beta 19`。
- **作者主页与开源地址**：关于页展示 GitHub 头像、`Ruinsss233`、主页链接和仓库地址；头像从 GitHub 加载，失败时使用本地兔标兜底。仓库可直接打开或复制。
- **界面细节**：视频头像统一为完整圆形，图片覆盖裁切，不留方形黑边；MP3 / FLAC 等格式选项统一蓝底粉字；更新日志支持收起 / 展开。
- **本地优先**：媒体处理全部在本机完成，不上传文件；仅加载 GitHub 头像、打开作者主页/仓库时联网。

### 1.1 更新日志（Beta 1–19）

- **Beta 1**：初版。ArkTS + NAPI、像素兔图标、液态玻璃底栏、音轨直提、另存为、进度条、大文件流式处理。
- **Beta 2**：错误码 3 排查。补齐阶段定位和封装参数检查。
- **Beta 3**：诊断日志。日志页、最近 60 行、复制全部、清空。
- **Beta 4**：MP3 / FLAC 输出。不再显示 AAC / M4A；直提与转码分流。
- **Beta 5**：后台提取。处理中可切页签，Home/返回键转后台。
- **Beta 6**：速度显示。B/s、KB/s、MB/s 自适应。
- **Beta 7**：中断恢复。持久化 URI 和任务格式，重新打开可恢复。
- **Beta 8**：FLAC 编码器。补齐 bitrate、bits-per-coded-sample、compliance level，修复“无法配置音频编码器”。
- **Beta 9**：记录格式。徽标按输出扩展名显示，源编码单独标注。
- **Beta 10**：取消误选。选完视频后可“取消当前选择”。
- **Beta 11**：记录定位。点击记录尝试打开所在位置；失败复制路径。
- **Beta 12**：樱花动态背景与水波。
- **Beta 13**：内置更新日志，按每次需求推进 Beta 版本。
- **Beta 14**：记录定位修正。直接拉起 `com.huawei.hmos.filemanager` 的 `MainAbility` 并传入文件夹 URI。
- **Beta 15**：转换工作台。新增音频转音频与视频转视频；五页签；转换进度、取消、另存为、后台任务和大文件流式处理。
- **Beta 16**：多格式与作者主页。音频新增 WAV / AAC / AIFF；关于页加入 GitHub 头像与 `Ruinsss233` 主页；版本升级到 V1.0.1。
- **Beta 17**：开源地址与一键上传。关于页加入仓库地址和打开/复制操作；新增 `一键上传源码.cmd` 与 `tools/upload-github.ps1`，输入 Token 后自动提交、建仓并推送。
- **Beta 18**：OGG 无损转封装。源音轨为 Opus / Vorbis 时可输出 OGG；MP3/AAC 等源因系统没有 Vorbis/Opus 编码器而明确禁用，不再伪装成可转换。
- **Beta 19**：界面细节。视频头像改为完整圆形并裁切铺满；格式选项改为蓝底粉字；更新日志新增收起 / 展开按钮。

## 2. 支持范围

### 2.1 输入

视频文件选择器允许：

`.mp4` `.mkv` `.mov` `.m4v` `.avi` `.flv` `.ts` `.webm` `.3gp` `.wmv` `.mpg` `.mpeg` `.m2ts`

音频文件选择器允许：

`.mp3` `.flac` `.m4a` `.aac` `.ogg` `.opus` `.amr` `.ape` `.wma`

实际解析能力由设备的 HarmonyOS demuxer / codec 决定。提取音轨时，文件至少要有一条可识别音频轨；视频转视频时，文件至少要有一条视频轨。

### 2.2 输出

| 场景 | 目标 | 处理方式 | 说明 |
|---|---|---|---|
| 视频提音轨 | MP3 | MP3 源直提；其他源解码后编码 | 默认 320kbps |
| 视频提音轨 | FLAC | FLAC 源直提；其他源解码后编码 | 16-bit；不会恢复有损源丢失的细节 |
| 视频提音轨 | WAV | 解码为 PCM，写 RIFF/WAVE | 16-bit，兼容性最好，体积大 |
| 视频提音轨 | AAC | AAC 源直提（ADTS）；其他源编码 | 192kbps ADTS `.aac` |
| 视频提音轨 | AIFF | 解码为 PCM，写 AIFF | 16-bit 大端，专业软件友好 |
| 音频转音频 | 上述格式（OGG 仅同源） | 源编码匹配则直提，否则解码重编码 | 本机完成，不上传 |
| 视频转视频 | MP4 | 系统 `AVTranscoder`，H.264 或 H.265，AAC 192kbps | 仅 MP4 输出；设备需支持 AVTranscoder |

> AAC/MP3 转 FLAC 只是把已损失的音质装进无损容器，不会变成录音室母带。界面会明确提示。

### 2.3 编码能力

- 系统编码器：AAC、FLAC、MP3、G711mu。
- 系统解码器：AAC、MP3、FLAC、Vorbis、AMR、APE、ALAC、AC3、WMA 等（以设备实际能力为准）。
- 本版本通过原生 API 输出 MP3 / FLAC / WAV / AAC / AIFF，OGG 仅支持 Opus/Vorbis 同源无损转封装；视频输出仅 MP4。
- **明确不支持**：AVI / MKV / MOV / WMV / FLV 视频输出；WMA / APE 音频输出；把任意音频转成 OGG / AMR（系统没有对应编码器，OGG/AMR 只能保留同格式源流）。
- 只处理第一条音频轨；多音轨选择属于后续版本。

## 3. 使用

### 3.1 提取音轨

1. 打开应用，在 **提取** 页点“选择视频”。
2. 读取时长、分辨率、音轨编码、采样率、声道等元数据。
3. 选择 **MP3 / FLAC / WAV / AAC / AIFF / OGG**；界面标记“无损直提”“解码转码”或“当前源不可用”。
4. 选错可点“取消当前选择”，不必退出应用。
5. 点“提取并保存”，在系统保存面板选目录和文件名。
6. 查看进度；可取消，也可切到其他页签或按 Home/返回键转入后台。
7. 完成后到 **记录** 查看，点“查看位置”定位输出文件。

### 3.2 转换

1. 进入 **转换** 页，选择 **音频转音频** 或 **视频转视频**。
2. 音频：选择 MP3/FLAC 等文件，指定 MP3 / FLAC / WAV / AAC / AIFF / OGG（OGG 仅同源），开始转换。
3. 视频：选择视频，指定 H.264 或 H.265，保存为 MP4。
4. 处理中可取消、切页签或转后台；完成后记录页会显示输出格式。

## 4. 构建

### 4.1 环境

- Windows 10/11
- DevEco Studio **26.0.0.821**（或兼容版本）
- HarmonyOS SDK **26.0.0 / API 26**
- 项目自带 `node_modules` 时可直接使用 `tools/build.ps1`；换机器时建议用 DevEco Studio 打开并 Sync。

### 4.2 一键构建（当前机器）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DSH\RuinsssFormat\tools\build.ps1 assembleHap
```

脚本会：

1. 用 `clang++.exe` 编译 `entry/src/main/cpp/ruinsss_media.cpp` 为
   `entry/libs/arm64-v8a/libruinsss_media.so`；
2. 调用 hvigor 打包 HAP。

产物：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

只清理构建产物：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DSH\RuinsssFormat\tools\build.ps1 clean
```

### 4.3 用 DevEco Studio

1. 打开 `D:\DSH\RuinsssFormat`。
2. 等待 Sync 完成。
3. 连接真机或启动模拟器，点 Run。
4. 修改 `ruinsss_media.cpp` 后，先运行 `tools/build-native.ps1` 生成 `.so`，再打包。

> 为什么不用 hvigor 的 CMake 流程？在本次 Windows 环境下，hvigor 的 CMake 编译器 ABI 探测和 Ninja 子进程会卡死；项目改为“脚本直接编译 `.so` + 预编译库打包”。`CMakeLists.txt` 保留，方便在其他环境恢复标准 NDK 构建。

### 4.4 签名与安装

仓库里的 HAP 是 **unsigned**，不能直接安装到零售 HarmonyOS 手机。正确做法：

- 用 DevEco Studio 打开项目；
- 登录华为开发者账号；
- 在 **File > Project Structure > Signing Configs** 中勾选自动签名；
- 让 DevEco Studio 重新签名并安装。

签名需要与目标设备匹配的证书/Profile。没有开发者证书时，只能完成编译和打包，不能真机安装。

## 5. 目录结构

```text
RuinsssFormat/
├─ AppScope/                         # 应用级配置与图标
├─ entry/
│  ├─ libs/arm64-v8a/
│  │  └─ libruinsss_media.so         # 预编译 NAPI 模块
│  └─ src/main/
│     ├─ cpp/
│     │  ├─ ruinsss_media.cpp        # 提取 / 直提 / 音频转码引擎
│     │  └─ CMakeLists.txt           # 可选的标准 NDK 构建配置
│     ├─ ets/
│     │  ├─ common/Theme.ets         # 配色、圆角、阴影
│     │  ├─ model/Types.ets          # 数据模型、解析、格式化
│     │  ├─ services/
│     │  │  ├─ MediaService.ets      # NAPI 调用封装
│     │  │  ├─ FileService.ets       # 选择文件 / 另存为 / URI 持久化
│     │  │  ├─ BackgroundService.ets # DATA_TRANSFER 持续任务
│     │  │  ├─ JobStore.ets          # 未完成任务持久化
│     │  │  ├─ HistoryStore.ets      # 最近记录
│     │  │  └─ AppLog.ets            # 本地诊断日志
│     │  ├─ entryability/EntryAbility.ets
│     │  └─ pages/Index.ets          # 主界面、状态机、转换页、日志页
│     ├─ resources/
│     │  └─ base/media/bg_sakura.jpg # 全部页面的背景图
│     └─ module.json5
├─ tools/
│  ├─ build.ps1                      # 原生编译 + HAP 打包
│  ├─ build-native.ps1               # 只编译 .so
│  ├─ cp-shim.js                     # 本机构建环境的管道兼容层
│  ├─ make_icons.py                  # 从原图生成应用图标
│  ├─ upload-github.ps1              # Token 验证 + 自动建仓 + 推送
│  └─ upload-github.cmd              # tools 目录内的上传入口
├─ 一键上传源码.cmd                   # 根目录一键上传入口
├─ build-profile.json5
├─ hvigorfile.ts
└─ oh-package.json5
```

## 6. 实现要点

### 6.1 提取：直提与转码

`ruinsss_media.cpp` 的 `RunExtract` 先探测第一条音频轨，再由 `ResolveOutput` 决定：

```text
目标编码 == 源编码（MP3 / FLAC）
  → 直接 remux：OH_AVSource → OH_AVDemuxer → OH_AVMuxer
  → 只搬运压缩样本，不碰 PCM

目标编码 != 源编码
  → Transcoder：
     OH_AVDemuxer 读压缩帧
       → OH_AudioCodec 解码为 PCM
       → 统一转 S16LE
       → 按编码器帧长切片
       → OH_AudioCodec 编码为 MP3 / FLAC
       → OH_AVMuxer 写入目标文件
```

直提路径：

- 只搬运压缩样本，不调用解码器/编码器；
- PTS 以第一帧为基准归零，并保证单调递增；
- FLAC 直提写入 `OH_MD_KEY_AUDIO_SAMPLE_FORMAT`（修复“错误码 3”的关键）；
- 输出 fd 先 `ftruncate(fd, 0)`，避免覆盖目标文件时留下旧内容；
- 缓冲区按轨道 `OH_MD_KEY_MAX_INPUT_SIZE` 动态确定（256KB–32MB，默认 4MB）；
- 进度按已写入样本 PTS / 容器时长估算，每 120ms 由 ArkTS 轮询；
- 取消通过原子标志在样本循环中检查，取消后停止封装，UI 删除未完成文件。

转码路径：

- 解码器/编码器使用同步模式（`QueryInputBuffer` / `QueryOutputBuffer`），运行在 NAPI async work 线程；
- 解码输出支持 S16LE / F32LE / S32LE / S24LE / U8，统一转 S16LE；
- MP3 编码帧长 1152 采样，FLAC 帧长 4608 采样；PCM 缓冲超过 1MB 会压缩；
- FLAC 编码器必须带 `OH_MD_KEY_BITRATE`；API 20 之前还必须写 `OH_MD_KEY_BITS_PER_CODED_SAMPLE=1` 和 `OH_MD_KEY_COMPLIANCE_LEVEL=0`；
- 编码器输出先暂存，等 `OH_AudioCodec_GetOutputDescription` 给出 codec config 后再 `AddTrack` / `Start`；
- 编码包 PTS 以第一帧为基准归零并保证单调；
- 转码完成同样 `Stop`、`fsync`（best-effort）、更新进度。

### 6.2 WAV / AIFF（PCM 封装）

WAV / AIFF 走 `PcmExporter`，不经过 `OH_AVMuxer`：

- `OH_AudioCodec` 解码为 S16LE，WAV 小端写入，AIFF 逐样本转大端；
- 先写 44 字节 WAV / 54 字节 AIFF 头，流式写 PCM，结束时回填 RIFF/FORM 与 data/SSND 长度；
- AIFF 的 80-bit sample rate 由采样率即时计算；
- 4GB 上限由容器字段决定，超过时提示改用 FLAC / MP3；
- WAV/AIFF 是未压缩 PCM，输出体积约等于 `采样率 × 声道 × 2 × 秒数`。

### 6.3 视频转视频

视频路径使用 ArkTS `media.createAVTranscoder()`：

- `fdSrc` 指向源视频，`fdDst` 指向系统保存面板返回的目标 fd；
- `AVTranscoderConfig` 指定 `CFT_MPEG_4`、`VIDEO_AVC/VIDEO_HEVC`、`AUDIO_AAC`；
- 音频码率 192kbps；视频码率按分辨率选择 3/6/12/24 Mbps；
- 监听 `progressUpdate`、`complete`、`error`，轮询进度并支持取消；
- 只支持 MP4 输出；设备不支持 AVTranscoder 时会给出明确错误。

### 6.4 原生模块接口

```ts
probe(fd: number, size: number): string
extract(inputFd: number, inputSize: number, outputFd: number, format: string): Promise<string>
getProgress(): string
cancel(): void
version(): string
```

`probe` 返回视频/音频轨道元数据；`extract` 在 NAPI async work 中执行；`getProgress` 返回进度 JSON；`cancel` 设置取消标志。

### 6.5 界面

- 状态机：`idle → analyzing → ready → working → success / error`
- 底部五个页签：**提取 / 转换 / 记录 / 日志 / 关于**
- 提取输出格式：**MP3 / FLAC / WAV / AAC / AIFF / OGG**，标记“无损直提 / 解码转码 / 当前源不可用”
- 转换页：音频转音频、视频转视频，各自选择格式/编码
- 记录页徽标按输出扩展名推导（`historyFormat`），源编码单独标为“源 AAC/MP3/FLAC”
- 查看位置：直接拉起 `com.huawei.hmos.filemanager` 的 `MainAbility`，参数 `fileUri` 为文件夹 URI；失败只复制路径
- 背景：`bg_sakura.jpg` 全屏 `ImageFit.Cover`，上层浅色渐变保证文字可读
- 水波：`Canvas` 监听全屏触摸，33ms 帧率绘制 3 层扩散圆环 + 径向柔光
- 玻璃效果：`BlurStyle.COMPONENT_ULTRA_THICK` + 半透明渐变 + 高光描边 + 阴影

## 7. 验证状态

已完成的验证：

- ArkTS 编译通过：五页签、转换页、日志页、格式选择、恢复卡片、取消选择、记录定位；
- C++ NAPI 模块以 `--target=aarch64-linux-ohos` 编译通过；
- `.so` 静态链接 libc++，不依赖 `libc++_shared.so`；
- HAP 打包成功，包含 `libs/arm64-v8a/libruinsss_media.so`、`ets/modules.abc`、图标与背景资源；
- 应用图标、樱花背景视觉检查通过；
- 后台持续任务、URI 持久化、未完成任务恢复、速度格式化代码通过编译；
- FLAC 编码器补充参数、历史格式推导、取消选择、文件管理器跳转代码通过编译；
- WAV / AIFF PCM 导出、AAC 编码分支、OGG 条件转封装、六种音频输出 UI、GitHub 作者卡通过编译；
- 构建机没有连接设备，因此未做运行时提取、保存、取消、转码、后台存活、恢复、文件管理器跳转、背景渲染与水波动画验证。

**首次真机测试建议**：

1. MP4 + AAC → MP3（转码）
2. MP4 + AAC → FLAC（转码）
3. MP4 + MP3 → MP3（直提）
4. FLAC 容器 → FLAC（直提，验证“错误码 3”修复）
5. 音频 MP3 → FLAC、M4A → MP3
6. 视频 H.264 → H.265 MP4、H.265 → H.264 MP4
7. 10GB 级文件，观察内存与进度
8. 处理中取消，确认输出文件被删除
9. 无音轨视频、无视频轨文件，确认显示错误而不是 0 字节成功
10. 处理中按 Home / 返回键，确认通知与后台继续
11. 强杀进程后重新打开，确认“恢复上次提取”
12. 记录页“查看位置”，确认进入文件管理器而不是音乐/邮件应用

## 8. 已知限制

- **转码无法提升音质**：AAC/MP3 转 FLAC 只是换容器；FLAC 源转 MP3 会丢弃细节。
- **只处理第一条音频轨**：多音轨视频目前取第一条。
- **采样率/声道沿用源**：HE-AAC、96kHz、多声道素材可能需要重采样/下混，当前未专门处理。
- **视频只输出 MP4**：系统 `AVTranscoder` 当前只支持 MP4；AVC/HEVC 支持取决于设备。AVI / MKV / MOV / WMV / FLV 没有系统封装器，未做支持。
- **WMA / APE 只解码不编码**：系统没有对应编码器，不能作为输出格式；OGG / AMR 也只有在源本来就是该格式时才能直接封装。
- **GitHub 头像需要联网**：关于页用 `https://github.com/Ruinsss233.png` 加载头像，失败时显示本地兔标；媒体文件不会上传。
- **恢复不是字节级续写**：`OH_AVMuxer` 不支持从文件中途追加，恢复会重新封装到原目标；大文件仍需重新处理。
- **后台不是“杀不死”**：`DATA_TRANSFER` 持续任务支持 Home/返回键/锁屏等场景；从最近任务强制划掉或系统强制停止仍会终止进程。
- **文件位置跳转依赖系统文件管理器**：直接拉起 `com.huawei.hmos.filemanager` 的 `MainAbility`；不同系统版本/文件管理器实现可能不同，失败时会复制文件路径。
- **系统能力依赖**：容器与编解码器是否可用取决于设备 `OH_AVMuxer` / `OH_AudioCodec` / `AVTranscoder` 实现。
- **版本号格式**：HarmonyOS 的 `versionName` schema 只接受 `1.0.1` 这类数字格式，因此元数据写 `1.0.1`；界面展示 `V1.0.1 · Beta 19`。
- **2in1 警告**：`setPreferredOrientation`、`setWindowKeepScreenOn` 等窗口 API 在 2in1 上会给出兼容性警告。
- **未签名**：见 4.4。

## 9. 路线图

- **V1.1**：批量队列、视频压缩、码率/分辨率选项、多音轨选择；
- **V1.2**：字幕、封面/ID3 标签、片段提取；
- **后续**：通知栏进度与暂停/继续操作。

## 10. 署名

- 作者：**Ruinsss**
- GitHub：**[Ruinsss233](https://github.com/Ruinsss233)**
- 应用名：**Ruinsss格式快转**
- 版本：**V1.0.1 · Beta 19**
- 图标：由提供的原图裁切、缩放生成（`tools/make_icons.py`）

## 11. 开源与上传

- 仓库地址：**https://github.com/Ruinsss233/RuinsssFormat**
- 应用内“关于 → 开源地址”可直接打开或复制该地址。
- 本目录已按“可直接上传 GitHub”的结构整理：`README.md`、`AppScope/`、`entry/`、`tools/`；`.gitignore` 排除 `node_modules`、`build`、`.hvigor`、`.cpshim`、日志和 `dist`。

### 一键上传（推荐）

双击项目根目录的：

```text
一键上传源码.cmd
```

按提示粘贴 GitHub Token。**输入时不显示，也不会写入 Git 配置或磁盘**，关闭窗口后即失效。

脚本会：

1. 初始化 Git（如果没有）；
2. 暂存并提交当前源码；
3. 用 Token 调用 GitHub API 验证身份；仓库不存在时自动创建（默认公开）；
4. 将 `origin` 指向 `https://github.com/Ruinsss233/RuinsssFormat.git`；
5. 推送 `main` 分支。

Token 权限建议：

- **Classic PAT**：勾选 `repo` 即可（自动建仓 + 推送）；
- **Fine-grained PAT**：`Contents: Read and write`；如果需要自动建仓，再加 `Administration: Read and write`；
- 不要把 Token 发到聊天、截图或提交到仓库。

构建机当前无法访问 `github.com`，所以本地提交可用，**远程推送请在你自己的电脑上运行这个 cmd**。

本地演练（不联网、不推送）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\upload-github.ps1 -NoPush -SkipCreate -SkipCommit
```

推到自己的仓库或建私有仓库：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\upload-github.ps1 `
  -Owner 你的用户名 -Repo 你的仓库名 -Private
```

如果远程仓库已有提交、与本地历史不一致，先执行 `git pull --rebase origin main`；脚本不会强制推送。

上传前建议补充 `LICENSE`（当前未替作者选择开源许可证）。

---

如果这个工具帮你省下了时间，记得把“Ruinsss”留在关于页里。🐰
