# LibreTV 的 iOS 外壳（越狱安装用）

这是把 LibreTV 包成 iPhone App 的最小工程：全屏 WKWebView 加载你的 LibreTV 服务，
底部有「后退 / 主页 / 刷新 / 设置」，点「设置」可以改服务器地址（家里局域网地址、
或 Tailscale 地址、或穿透后的公网地址）。页面里的 `window.open` 不会跳出去，都在当前视图里打开。

## 为什么要在云端编译

iOS 的 `.app` 只能用 Xcode（macOS）编译。这台电脑是 Windows，所以用 GitHub 提供的
免费 macOS 机器编译，产出**未签名 IPA** —— 越狱机器正需要未签名的包。

## 一共四步

### 1. 传到 GitHub

**最简单（不用装 git）**：在 github.com 新建一个空仓库（Public 私有都行，**不要**勾选 Add README），
然后在仓库页面点 `Add file → Upload files`，把这个文件夹（`F:\LibreTV\ios-app`）**整个拖进去**
（包括 `.github`、`Sources`、`Resources`、`Support`、`project.yml`），提交即可。
网页上传会保留目录结构，`.github/workflows` 必须在仓库根目录下才算生效。

**会用 git 的话**（这台电脑目前没装 git，需要先装）：

```
git init
git add .
git commit -m "LibreTV iOS shell"
git branch -M main
git remote add origin https://github.com/你的用户名/仓库名.git
git push -u origin main
```

### 2. 云端自动编译

打开仓库的 **Actions** 页，点左侧 `build-unsigned-ipa`，再点右侧 `Run workflow`。
大约 5~10 分钟跑完，成功后这一条记录最下方有产物 **LibreTV-ipa**，点进去下载，
得到 `LibreTV-unsigned.ipa`。

### 3. 装到越狱手机

按你的越狱环境选一种：

- **有 TrollStore**：把 ipa 传到手机（AirDrop / 文件 App / QQ 传文件都行），用 TrollStore 打开 → Install。
  好处是「永久签名」，不会 7 天掉签。
- **有 AppSync Unified**（Cydia/Sileo 里装）：用 Filza 点 ipa → 安装；或用命令行
  `ipainstaller /path/to/LibreTV-unsigned.ipa`。
- **没有上面两个**：在电脑用 Sideloadly + 自己的 Apple ID 签一次（7 天有效，到期重签）。

安装后在「设置 → 通用 → VPN与设备管理」里信任对应描述文件（TrollStore/AppSync 装的通常不需要）。

### 4. 首次打开

App 默认地址是 `http://192.168.0.100:8080`。如果连不上：

1. 确认电脑上 LibreTV 正在运行；
2. 点底部「设置」，把地址改成实际的（`ipconfig` 看电脑 IP，或你的 Tailscale/穿透地址）；
3. 电脑上要放行过防火墙（见 `F:\LibreTV\允许手机访问.bat`）。

## 想改默认地址

改 `Sources/WebViewController.swift` 里的 `defaultServer`，重新跑一次 Actions 即可。

## 已知限制

- 这是网页外壳，不是重写的原生播放器；播放、搜索、片源都来自你电脑上的服务，**电脑关机就用不了**。
- 手机端页面已隐藏抖音 / 酷我入口（那是 Windows 桌面版专属）。
- 不能上架 App Store（聚合影视源过不了审核），本工程只用于自己的设备。
- 未签名 IPA 需要越狱环境（TrollStore / AppSync Unified）才能装；没有越狱就用 Sideloadly 签。

## 文件清单

```
project.yml                      XcodeGen 工程描述（改包名、版本、默认行为都在这里）
Sources/AppDelegate.swift        启动入口
Sources/WebViewController.swift   全屏 WebView + 底部工具栏（后退/主页/刷新/设置）
Resources/Assets.xcassets         App 图标（各尺寸已生成）
Support/Info.plist               由 project.yml 生成，不用手改
.github/workflows/build-ipa.yml  云端打包流程（macOS 机器编译出 ipa）
```
