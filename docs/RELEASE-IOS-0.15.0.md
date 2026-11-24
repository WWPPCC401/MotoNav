# MotoNav iOS 0.15.0

第一个包含**音乐专辑封面**功能的可编译版本（固件侧已就绪，就等这个 App）。

## 新增

- **专辑封面**（CoverArt.swift）：音乐页换歌时自动查封面（Apple Music 本地封面 / iTunes Search API），居中裁方 200×200 RGB565，经 bulk type 5 发给圆屏，收满自动切换显示。
- **导航播报静音**（MotoNavApp.swift）：监听 `T,V` 命令，翻转静音并立即停止当前播报，与圆屏大键（PWR）联动。

## 说明

- 高德 Key 不内置，首次打开在「Key 设置」里填自己的 Key（Bundle ID 见 App 内一键复制）。
- 本版本为未签名 IPA，用 Sideloadly + 自己的 Apple ID 签名安装，免费账号 7 天过期。
- 圆屏固件需为 v7.12.9-photo.4 及以上（含 bulk type 5 接收）。
