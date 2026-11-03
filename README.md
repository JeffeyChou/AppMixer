# AppMixer

macOS 菜单栏小工具：单独调节每个正在播放声音的 App 的音量（0–150%，可静音）。

- 基于 Core Audio **process tap**（macOS 14.2+ 公开 API），不需要安装虚拟声卡或驱动
- 音量为 100% 的 App 不做任何处理；只有调过音量的 App 才会被接管
- 设置按 App 保存，App 重启后自动生效
- 不需要付费开发者账号，用 Command Line Tools 就能编译

## 构建与安装

需要 macOS 14.2+ 和 Command Line Tools（`xcode-select --install`），不需要 Xcode。

```bash
./build.sh            # 生成 build/AppMixer.app（ad-hoc 签名）
./build.sh install    # 复制到 ~/Applications 并启动
./build.sh run        # 直接从 build/ 启动
```

启动后菜单栏会出现一个滑块图标：

- **左键**：打开面板。顶部有三个按钮：全部静音（再点一次取消）、全部重置为 100%、退出（⌘Q）。
- **右键**（或按住 ⌃ 点击）：弹出菜单，包含 Mute All / Reset All / Quit。
- 面板里先列出正在播放的 App。勾选「Show idle audio clients」后，在 IDLE 分组里还会显示其它音频客户端：真正的 .app 排前面，后台进程排后面，组内按名称排序。整个面板最高约为半个屏幕，超出部分可以滚动。

菜单栏图标可以不重新编译直接调整，改完重启 AppMixer 生效：

```bash
defaults write dev.appmixer.AppMixer iconPointSize -float 17   # 图标大小（pt）
defaults write dev.appmixer.AppMixer iconOffsetY -float -0.5   # 垂直偏移（pt）：正数往下，负数往上
defaults write dev.appmixer.AppMixer iconWeight semibold       # 粗细：regular / medium / semibold / bold / heavy
defaults delete dev.appmixer.AppMixer iconOffsetY              # 删除某一项，恢复默认值
```

调试工具（都不会改变任何音量，也不会请求权限）：

```bash
build/AppMixer.app/Contents/MacOS/AppMixer --list                    # 打印 Core Audio 识别到的音频进程和分组结果
build/AppMixer.app/Contents/MacOS/AppMixer --snapshot out.png [--idle]  # 把面板渲染成 PNG（可用于 README 截图或检查布局）
build/AppMixer.app/Contents/MacOS/AppMixer --icon-preview      # 在菜单栏临时显示图标 3 秒（用于调整图标位置）
build/AppMixer.app/Contents/MacOS/AppMixer --measure-open      # 自动开关面板 6 次，测量打开时主线程的卡顿
```

## 首次使用：系统音频录制权限

第一次把某个 App 的音量调离 100% 时，系统会请求「系统音频录制」权限，点允许即可。
如果点了拒绝，可以到 系统设置 → 隐私与安全性 → 录屏与系统录音 →「仅系统录音」里打开 AppMixer。

ad-hoc 签名每次重新编译后签名都会变，系统可能会再次要求授权。想避免这个问题，可以在「钥匙串访问 → 证书助理 → 创建证书」里建一个类型为「代码签名」的自签名证书（比如叫 `AppMixer Dev`），然后这样编译：

```bash
SIGN_ID="AppMixer Dev" ./build.sh install
```

## 工作原理

```
App 的音频 ──▶ process tap（读取期间，原声在硬件层被静音）
                  │
                  ▼
     私有 aggregate device [ tap 作为输入 + 当前输出设备作为输出 ]
                  │  IOProc：out = clamp(in × gain)，带增益平滑
                  ▼
             扬声器 / 耳机
```

- 识别 App：`kAudioHardwarePropertyProcessObjectList`，再读每个进程的 `IsRunningOutput`。浏览器等 App 的声音来自 helper / XPC 进程，用 responsible pid 和 bundle ID 前缀把这些进程归到所属 App 下。
- tap 和 aggregate device 都是本进程私有的。AppMixer 退出或崩溃时会自动销毁，被调节的 App 会恢复原音量。
- 切换默认输出设备时，会自动在新设备上重建 tap。
- 主线程上不做耗时操作：进程扫描在后台队列完成（pid 和所属 App 只解析一次，播放状态由 Core Audio 监听推送，热扫描约 0.03 ms）。tap 的创建和销毁放在独立的引擎队列里，滑块的连续变化会被合并。音量回到 100% 后，tap 会保留 3 秒再撤掉。拖动滑块时只重绘那一行。

## 已知限制

- 被接管的 App 会多出几毫秒到十几毫秒的输出延迟。
- 只会输出到系统默认输出设备。如果某个 App 自己选择了别的输出设备，暂不支持。
- 在 100% 和非 100% 之间切换时，会因为创建或销毁 tap 出现一次轻微的爆音或断音。
- 用到两个私有符号：`TCCAccessPreflight/Request`（检查权限）和 `responsibility_get_pid_responsible_for_pid`（把进程归到所属 App）。两者都通过 `dlsym` 动态查找，找不到时会自动降级。所以这个工具不能上架 Mac App Store，但可以通过 GitHub 或 Homebrew 分发。

## 分发

没有 Developer ID 时，别人下载的 zip 会被 Gatekeeper 拦截，需要到 系统设置 → 隐私与安全性 点「仍要打开」，或者执行：

```bash
xattr -dr com.apple.quarantine /Applications/AppMixer.app
```

从源码编译（`./build.sh install`）则不会遇到这个问题。
