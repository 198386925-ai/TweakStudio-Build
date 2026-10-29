# 插件工坊 TweakStudio

把 axs-ios-tweaks 模板工具做成的 iOS App（SwiftUI，iOS 16+），B 方案：生成在 App 内做，打 deb 走 GitHub 云端。

功能（Build 1，只做确认清单内 6 项）：

- **一页表单**：插件英文名、中文名、小写标识、简单介绍、要改的 App（不填默认 SpringBoard）、最低 iOS 版本
- **两个开关**：要不要设置面板、要不要滑条
- **生成工程**：App 内置原包模板，在 App 里按原规则生成 Theos 插件工程 zip，可保存/分享（系统分享单）
- **导入源码 zip**（Build 3 新增）：从手机文件选现成的插件源码 zip，App 内解压并检查工程根的 `Makefile`/`control`（多包一层文件夹自动剥掉），缺云端打包说明时自动补模板 `build.yml`，存进历史后同样可送去打成品
- **送去打成品**：App 内填一次 GitHub 令牌（只存钥匙串），每插件一个 GitHub 仓库（tweakstudio-<标识>），推上去由工程自带的 Actions 打成 deb，App 再下载回来，在历史里可分享 deb
- **上传前检查**：名字/标识格式、生成文件齐不齐，缺了在 App 里提醒（静态检查，不等于真机可用）
- **历史列表**：做过的插件都在，可再分享工程 zip / deb，能删

不做：手机本地编译 deb、App 内安装插件或注销、改原包生成规矩（第一版完全照原模板默认值）。

## 打包

源码推到新仓库 `TweakStudio-Build` 的 `main`（排除 `.github/`），然后需要在 GitHub 网页端新建一个文件：`.github/workflows/build-ipa.yml`，内容见同批交付的 `workflow-for-user/build-ipa.yml`（在源码目录外单独发）。建好后推送/手动触发即在 GitHub Actions（macos-15-intel + Xcode 26）上构建**未签名** IPA：

- 产物命名：`TweakStudio-1.0.0-Build(7).ipa`
- 同时产出干净源码备份 `TweakStudio-1.0.0-Build(7)-src.zip`

IPA 未签名，安装前需自行签名。

## 版本规则

- 版本号 `CFBundleShortVersionString`：`1.0.0`
- 构建号 `CFBundleVersion`：`7`（下一版 +1；版本变更时按既有规则处理）
