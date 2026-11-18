# 三步拿到 IPA

这台机器是 Windows，没有 `swift` / `xcodebuild` / `xcodegen`，因此**不可能在本机生成可运行的 iOS 二进制**——iOS 可执行文件必须用 Apple 的 iOS SDK 在 macOS 上链接。下面是能真正跑通的路径。

---

## 路线 A：没有 Mac（当前环境，推荐）

### 第 0 步：装 GitHub CLI 并登录（一次性）

```powershell
winget install --id GitHub.cli
# 装完重开一个终端，然后：
gh auth login
# 选 GitHub.com → HTTPS → Login with a web browser → 浏览器里授权
```

### 第 1 步：一条命令出 IPA

```powershell
cd D:\AI\DS\Inkwell
pwsh .\scripts\build_ipa.ps1 -RepoOwner 你的GitHub用户名 -RepoName inkwell
```

脚本会自动：初始化仓库 → 建远程仓库（默认 public，加 `-Private` 建私有）→ push → 触发 `build-ipa.yml` → 轮询状态 → 把 IPA 下载到 `dist\`。

首次大概 8~15 分钟（要拉 SwiftSoup / GRDB / ZIPFoundation 三个包）。

### 第 2 步：验结构 + 侧载

```powershell
pwsh .\scripts\verify_ipa.ps1 -Ipa .\dist\Inkwell-xxxx-unsigned.ipa
```

看到 `✓ Payload/*.app`、`✓ Info.plist`、`✓ Mach-O 头 (CF FA ED FE)`、`✓ Assets.car` 全绿，再装。

Windows 侧载用 **Sideloadly**：拖入 IPA → 填 Apple ID → Start。签名有效期 7 天，同一 Apple ID 最多同时签 3 个 App。

---

## 路线 B：有 Mac

```bash
git clone <你的仓库> && cd Inkwell
brew install xcodegen
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

出未签名 IPA 到 `dist/`。

要直接签名：

```bash
./scripts/build_ipa.sh --sign \
  --team ABCD123456 \
  --identity "Apple Development: you@example.com (ABCD123456)"
```

先把 `entitlements.plist` 里的 `TEAMID` 和 Bundle ID 改成你自己的。

---

## 路线 C：Xcode 里直接跑（调试用）

```bash
brew install xcodegen && cd Inkwell && xcodegen generate && open Inkwell.xcodeproj
```

Xcode → Target `Inkwell` → Signing → Team 选你的 Apple ID → Bundle Identifier 改成全局唯一 → 连 iPhone 17 Pro Max → Run。

iOS 27 首次运行要去「设置 → 通用 → VPN与设备管理 → 开发者App」点信任。

---

## 出问题时看哪里

| 现象 | 位置 |
|---|---|
| Actions 构建失败 | 脚本会打印 `archive.log` 尾部；也可 `gh run view --log-failed` |
| 依赖解析失败 | `xcodebuild -resolvePackageDependencies -scheme Inkwell -project Inkwell.xcodeproj` |
| 装上了打不开 | 先跑 `verify_ipa.ps1`，多半是没签或 Bundle ID 冲突 |
| 书源解析不出内容 | App 内「书源 → 源详情 → 自动校准规则」，看四段日志哪段红 |

---

## 版本与产物命名

```
dist/Inkwell-1.0.0-20261118-141500-unsigned.ipa
dist/Inkwell-1.0.0-20261118-141500-signed.ipa
```

打 tag 时 Actions 会自动把 IPA 附到 GitHub Release：

```bash
git tag v1.0.0 && git push origin v1.0.0
```
