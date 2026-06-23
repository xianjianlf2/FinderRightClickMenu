# FinderRightClickMenu

macOS 访达（Finder）右键菜单小工具：在右键菜单里加入「复制路径 / 上一层 / 在此打开终端」。

- **MenuExtension**：沙箱内的 Finder Sync 扩展，负责构建菜单、拿到选中路径；需要权限的动作通过 `frcm://` URL 交给配套 App。
- **App**：非沙箱配套 App，菜单栏常驻，接收 `frcm://` 执行打开终端 / 导航 / 通知，并提供「授权与设置」窗口。
- **ThirdParty/PermissionFlow**：随仓库内置的本地 Swift Package（MIT，源自 capcap）。点设置窗里的「辅助功能 / 完全磁盘访问」槽位时，会打开对应系统设置面板并弹出一个跟随其窗口的浮动面板，引导把 App 图标拖入权限列表完成授权。

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

## 打包 DMG / 发布

```sh
scripts/release-dmg.sh 1.0.0              # 构建 Release 并打成 dist/FinderRightClickMenu-1.0.0.dmg
PUBLISH=1 scripts/release-dmg.sh 1.0.0    # 额外用 gh 发布 GitHub Release 并上传 DMG
```

本仓库默认 ad-hoc 签名，未做 Developer ID 签名与公证；从 GitHub 下载的 DMG 在别的 Mac 上会被 Gatekeeper 拦截（见下）。要正经公开分发，需配置 Developer ID 证书并对产物做 `notarytool` 公证 + `stapler` 装订。

## macOS 校验拦截（「已损坏 / 无法验证」）

如果 macOS 弹出类似 `Apple 无法验证 "FinderRightClickMenu" 是否包含恶意软件` 或「已损坏，无法打开」的提示，对你信任的应用包移除 quarantine 标记后再重新打开：

```sh
xattr -dr com.apple.quarantine /Applications/FinderRightClickMenu.app
```

如果运行的是本地构建版本而非 `/Applications` 里的副本，把路径换成实际位置，例如：

```sh
xattr -dr com.apple.quarantine ./build/Build/Products/Debug/FinderRightClickMenu.app
```

只对你信任的构建执行此命令（本仓库下载的版本或你本地自行构建的版本）。移除后正常打开 App，再到「系统设置 → 隐私与安全性 → 扩展 / 访达扩展」启用扩展即可。
