# 鸣谢与致谢

vmios 建立在前人大量工作的基础上。本文件记录所依赖的项目、它们贡献了什么，
以及许可与引用方面的注意事项。

## 研究前身

- **hackios** —— 更早的 iOS-on-Android 研究项目，它的记录、bring-up 方法与
  ABI 结论为本项目提供了重要参考。vmios 沿着这条研究路线继续，但以自己的
  名义独立演进。若该项目已公开，请在此补充上游地址。
- **ios-sweet** —— 最早的 Redmi Note 10 Pro 裸机移植（本仓库 `shim/` 目标）。
  它的显示、UFS 与 HID 工作构成了虚拟机路径的基础。vmios 是该项目重命名后的
  后继。

## 开源软件

- **Apple XNU**（`xnu-8796`，iOS 16 世代）：vmios 打补丁并启动的内核，
  Apple 开源发布。
- **blacktop/darwin-xnu-build**：`xnu` GitHub Actions 工作流使用的
  macOS 构建框架（固定提交见 `.github/workflows/xnu.yml`）。
- **UniXNU**：其 `NativeVirtioConsole.cpp`（BSD-2-Clause-Patent）是内核
  virtio console 与 GPU 线缆的基础。
- **QEMU**：在 Android 与 PC 上运行客户机的模拟器。
- **Ghidra**（NSA）与 **Eclipse Temurin JDK 21**：用于 QuartzCore、
  IOMobileFramebuffer 与共享缓存的反向工程。
- **LLVM / lld**（`ld64.lld`）：在没有 Xcode 的环境下构建 Metal 插件。
- **libhfsp / hfsplus-tools**：bring-up 阶段的 HFS+ 镜像检查。
- **Android / Adreno EGL 与 OpenGL ES**：宿主 GPU 后端。

## 反向工程知识

- 来自越狱与模拟社区的 IOMobileFramebuffer、IOSurface 与 IOKit ABI
  公开研究。具体引用写在 `xnu/patches/` 对应补丁的注释里。

## 不随仓库分发的产物

Apple 的 iOS 根文件系统、共享缓存及其他 Apple 二进制不随本仓库分发。使用者
需自备 iPhone X 的 iOS 16.7.16 IPSW，并用 `tools/mkiosroot.sh` 生成根镜像。
