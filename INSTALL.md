# 在 iPhone 17 Pro Max（iOS 27.2.1）上安装墨阅

Windows 电脑侧载，全程约 20 分钟。**免费 Apple ID 签一次管 7 天**，到期重签，App 里的书和进度不会丢。

---

## 阶段 0 · 先确认你手里有 IPA

```powershell
dir D:\AI\DS\Inkwell\dist\*.ipa
```

没有的话先出包（GitHub Actions，8~15 分钟）：

```powershell
winget install --id GitHub.cli
gh auth login
cd D:\AI\DS\Inkwell
pwsh .\scripts\build_ipa.ps1 -RepoOwner 你的GitHub用户名 -RepoName inkwell
```

拿到后验一下结构：

```powershell
pwsh .\scripts\verify_ipa.ps1 -Ipa .\dist\Inkwell-xxxx-unsigned.ipa
```

四项全绿（`Payload/*.app`、`Info.plist`、`Mach-O 头 CF FA ED FE`、`Assets.car`）再往下走。

---

## 阶段 1 · 补齐 Apple 驱动

> 你这台机器上 `Apple Mobile Device Service` 已在运行、`MobileDevice.dll` 也在，
> 但缺 `iTunesMobileDevice.dll`，且没有装 iTunes 本体。Sideloadly 认不到设备
> 十有八九就是这里缺。

**做法**：装一次 iTunes（**官网版**，不是 Microsoft Store 版，Store 版经常认不到设备）。

```
https://www.apple.com/itunes/download/win64
```

装完**打开 iTunes 一次**，插上手机，确认 iTunes 左侧能看到「设备」图标（能看到 = 驱动通了）。看到就关掉 iTunes，后面用不到它。

装的时候如果提示要 iCloud，可以跳过。

---

## 阶段 2 · 装 Sideloadly

```
https://sideloadly.io
```

下载 Windows 版 `.exe`，双击装，**装完重启一次 Sideloadly**（它要先找到阶段 1 的驱动）。

---

## 阶段 3 · 手机端准备

**3.1 开启开发者模式**

iOS 16 之后必须开，否则装上的 App 点开就闪退。

- 路径：**设置 → 隐私与安全性 → 拉到最底 → 开发者模式 → 打开**
- 如果**找不到这一项**（新手机常见），说明还没被开发者工具标记过。先把阶段 4 走一遍，手机会弹「需要开启开发者模式」，再回来开。
- 开了之后会要求**重启手机**，重启后还要再确认一次「打开」。

**3.2 准备 App 专用密码**（有双重认证就必须要）

Sideloadly 不能直接用你的 Apple ID 登录密码。

1. 浏览器打开 `https://appleid.apple.com`
2. 登录 → **登录与安全** → **App 专用密码** → 生成
3. 名字随便填（比如 `sideloadly`）
4. 得到形如 `abcd-efgh-ijkl-mnop` 的 16 位码，**复制保存**（只显示一次）

**3.3 用数据线连电脑**

- 必须是**数据线**，纯充电线认不到
- 手机弹「要信任此电脑吗」→ **信任** → 输入锁屏密码
- 如果没弹，拔了重插，或者换一个 USB 口（优先主板后面的 USB-A 口，别用前置 hub）

---

## 阶段 4 · 签名并安装

1. 打开 Sideloadly，顶部应该已经显示 `iPhone (iOS 27.2.1)`。**没显示就回阶段 1**
2. 把 `Inkwell-xxxx-unsigned.ipa` **拖进 Sideloadly 的 IPA 框**
3. `Apple account` 填你的 Apple ID 邮箱
4. 点 **Start**
5. 弹框要密码 → 填阶段 3.2 生成的 **App 专用密码**（不是登录密码）
6. 等 1~3 分钟，进度条走完，日志出现 `Done.` 和 `Installation complete`

**Sideloadly 会自动改 Bundle ID**，不用你手动处理冲突。日志里形如：

```
Signing...
Installing...
Installed Inkwell (com.xxx.inkwell)
```

---

## 阶段 5 · 手机上信任

装上了但点开闪退 = 还没信任。

1. **设置 → 通用 → VPN与设备管理**
2. 找到 `Apple Development: 你的邮箱 (XXXXXXXXXX)`
3. 点进去 → **信任 "你的邮箱"** → 再确认一次
4. 回桌面点开墨阅

如果这时提示「开发者模式未开启」，回阶段 3.1 打开并重启。

---

## 阶段 6 · 首次启动做什么

1. 允许「本地网络」（局域网导书源用）、「相册」（保存漫画图）
2. **书源 → ＋ → 源商店** → 装内置源
3. **源商店 → 订阅** → 粘一个社区书源 JSON 的 Raw 地址 → 拉取（这是主力，内置源只是起点）
4. **源商店 → 一键建源** → 输一个你常看的站点域名 → 试搜 → 保存
5. 书架 → ＋ → 导入本地 epub/txt 验证排版

---

## 阶段 7 · 7 天到期怎么办

**表现**：点图标闪一下就退，或者提示「无法验证 App」。

**处理**：再跑一次 Sideloadly（IPA 拖进去、Apple ID 填好、Start）。**不用先删 App**，直接覆盖安装，书架和进度都在。

想免去每周插线：

| 方案 | 做法 | 代价 |
|---|---|---|
| **SideStore** | 先用 Sideloadly 装上 SideStore，电脑配对一次，之后手机自己续签 | 需要一台常开的电脑或 WireGuard 中继 |
| **AltStore Classic** | Windows 装 AltServer，同一 WiFi 下自动刷新 | 电脑要开机 |
| **开发者账号** | 年费 $99，证书 1 年有效 | 花钱 |

---

## 常见失败对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| Sideloadly 看不到设备 | 缺 Apple 驱动 / 线不行 / 没信任 | 阶段 1 + 重插 + 信任 |
| `Unable to connect to device` | iTunes 版本太旧或 Store 版冲突 | 卸载 Store 版，装官网版 iTunes |
| `Invalid Apple ID or password` | 用了登录密码 | 改用 App 专用密码 |
| `This app cannot be installed because its integrity could not be verified` | 没信任开发者 | 阶段 5 |
| 装上点开秒退 | 没开开发者模式 | 阶段 3.1，然后重签一次 |
| `Maximum number of apps for free development profiles has been reached` | 免费账号同时只能 3 个 App | 删掉另外两个自签 App |
| `Anisette data is invalid` | Apple 验证服务器问题 | 换网络/关代理重试，或改用 SideStore |
| 装完没有图标 | iOS 桌面缓存 | 重启手机 |
| IPA 拖进去报 `Invalid IPA` | 包结构坏了 | 跑 `verify_ipa.ps1` |
| 阅读时网页打不开 | 书源站挂了 | 源详情 →「自动校准规则」，看四段日志哪段红 |

---

## 一句话总结

```
装 iTunes（官网版）→ 插线信任 → Sideloadly 拖 IPA + App 专用密码 + Start
→ 设置里信任开发者 → 开开发者模式 → 打开墨阅
```

你需要我帮你确认哪一步，把 Sideloadly 的日志贴过来就行。
