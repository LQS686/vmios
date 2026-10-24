# vmios

**在虚拟机里运行真实的 iOS 16。**

vmios 让 Apple 原版的 iOS 16.7.16（20H392，iPhone X / `iPhone10,3` / D22AP）
用户态运行在打了补丁的开源 XNU 8796 内核之上。客户机里是**真实的 iOS 根文件
系统与共享缓存**：launchd、系统守护进程、backboardd、SpringBoard 和系统自带
应用，而不是重写或伪造的界面。

同一套内核与客户机镜像支持两个目标：

| 目标 | 状态 |
| --- | --- |
| **Android 应用**（`android/`，`dev.vmios.sweetvm`） | QEMU TCG + 自定义 UFS 控制器 + 面向宿主 Adreno GPU 的 virtio GPU 线缆 + 共享内存面板；可启动真实 iOS 用户态 |
| **裸机 shim**（`shim/`） | 早期 Redmi Note 10 Pro（`sweet`，SM7150）移植；保留作参考，当前暂停 |

## 结构

```
+--------------------- Android 应用（或 PC 上的 QEMU） ---------------------+
|  QEMU virt，1~2 个 vCPU，TCG                                             |
|   SWEETXNU payload：XNU 8796 + Apple 设备树 + 可选根镜像                  |
|   存储：sweet-ufs -> HFSX 格式 iOS 根镜像（userdata 中的 16 GiB 文件）      |
|   显示：共享客户机内存中的 sweet-fb 面板                                   |
|   GPU：virtio console 线缆 -> 宿主 EGL/GLES（Adreno）                      |
+---------------------------------------------------------------------------+
        内核补丁位于 xnu/patches，Metal 插件位于 vm/metal
```

内核补丁补齐真实 iOS 用户态所需的存储、显示、触摸、HID、AppleKeyStore、电源
和 GPU 基础服务。`vm/metal` 构建 `SweetMetal`：内核把它安装进客户机的
`AGXMetalA11.bundle`，向 CoreAnimation 注册一个虚拟 `MTLDevice`，再把渲染
pass 通过 GPU 线缆转发给宿主。

## 当前进度

- **启动**：真实 iOS 16.7.16 用户态可在 QEMU TCG 下启动；launchd、backboardd、
  SpringBoard 和 Setup 进程都能运行，SpringBoard 会创建窗口树。
- **显示**：面板由客户机内存提供；内核控制台可静音，把面板让给合成器。
- **GPU**：虚拟 Metal 设备是客户机的系统默认设备，CoreAnimation 的 Metal
  上下文能完成初始化；客户机用户态已经可以经内核线缆驱动宿主 GPU 完成填充
  （已在真机上端到端验证）。
- **待解决**：CoreAnimation 的 WindowServer 仍提交空 swap（没有 layer
  surface），iOS 界面尚未上屏；宿主端的 draw/blit 翻译也还没实现。当前
  handoff、证据与下一步见 `NOTES.md`。

早期裸机里程碑（官方主页、触摸、按键）记录在 `docs/` 与 `NOTES.md`。

## 目录

| 路径 | 用途 |
| --- | --- |
| `xnu/patches/` | 按编号顺序应用的内核补丁；CI 产出 `kernel.development.sweet` |
| `vm/` | 虚拟硬件：UFS、framebuffer、触摸、GPU 线缆、Metal 插件（`vm/metal`） |
| `android/` | Android 应用（`dev.vmios.sweetvm`）、QEMU 引擎、宿主 GPU 服务 |
| `tools/` | payload/ADT 构建、镜像工具、日志与崩溃分析工具 |
| `shim/` | 裸机启动 shim（旧目标） |
| `docs/` | 设计、启动分析、性能记录与 `NAMING.md` |
| `site/` | 项目网站 |
| `research/`、`artifacts/`、`.tools/` | 本地分析输入与临时产物，不入库 |

## 构建

内核：修改 `xnu/patches/` 后由 `xnu` 的 GitHub Actions 工作流构建（或使用
同样的 blacktop 构建树在本地构建）。

Payload：

```sh
python3 tools/mkadt.py out.adt --qemu --gpu-wire --gpu-bundle vm/metal/build/SweetMetalAccel.sgb
python3 tools/mkpayload.py xnu/out/kernel.development.sweet out.adt payload.bin --cmdline "..."
```

Android 应用：

```sh
cd android && ./gradlew assembleDebug
```

iOS 根镜像由使用者自行准备；本仓库不包含 Apple 的系统文件。

## 鸣谢

见 [CREDITS.md](CREDITS.md)。vmios 建立在 XNU、blacktop 的
`darwin-xnu-build`、UniXNU 的 virtio console 实现、QEMU、Ghidra，以及更早的
`hackios` / iOS-on-Android 研究之上。

## 命名与约定

项目标识符、前缀与符号规则见 [`docs/NAMING.md`](docs/NAMING.md)。简要原则：
面向用户与宿主侧统一使用 `vmios`；客户机平台 ABI 保留历史 `sweet` 前缀，
它是冻结的命名空间，按版本整体迁移，不做零散重命名。

## 许可证

MIT（见 `LICENSE`）。Apple 的 iOS 文件版权归 Apple，本仓库不包含它们。
