# FinderRightClickMenu

macOS 访达（Finder）右键菜单小工具：在右键菜单里加入「复制路径 / 上一层 / 在此打开终端」。

- **MenuExtension**：沙箱内的 Finder Sync 扩展，负责构建菜单、拿到选中路径；需要权限的动作通过 `frcm://` URL 交给配套 App。
- **App**：非沙箱配套 App，菜单栏常驻，接收 `frcm://` 执行打开终端 / 导航 / 通知，并提供「授权与设置」窗口。

## 构建

Xcode 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，不纳入版本库（签名等本地配置也随之不提交）。

```sh
brew install xcodegen        # 如未安装
xcodegen generate            # 生成 FinderRightClickMenu.xcodeproj
xcodebuild -project FinderRightClickMenu.xcodeproj \
  -scheme FinderRightClickMenu -configuration Debug \
  -derivedDataPath build build
```

签名按本机情况在 Xcode「Signing & Capabilities」中自行配置（默认本地 ad-hoc 即可运行）。

## 安装

把构建出的 `FinderRightClickMenu.app` 拷到 `/Applications` 并打开，然后在
「系统设置 → 隐私与安全性 → 扩展 / 访达扩展」中启用本扩展。
