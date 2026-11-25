# CloudFlow 0.3 — 手机直连版

SwiftUI iOS 应用：夸克、迅雷、百度链接识别，同平台批量转存到自己的账号、生成分享、AI 文案改写与本地链接替换。无需部署网盘服务器。

## 手机使用

1. 用 TrollStore 安装 CloudFlow-unsigned.ipa；最低 iOS 16.0，设备本身须支持 TrollStore。
2. 工作台点击网盘卡片，在 App 内打开官网登录，点“保存并验证”。验证通过才显示已连接。
3. 平台会话未能自动读取时，账号设置支持手动导入本人的 Cookie 或迅雷令牌、Client ID、Device ID、Captcha Token。验证码在官方登录页完成。
4. 粘贴链接或整段文案，识别并勾选任务，批量转存并生成新分享；任务页复制结果。
5. 设置模型中转站 HTTPS 地址（通常以 /v1 结尾）与 API Key，读取并选择模型，也支持手动填写模型 ID。
6. 文案页生成改写，替换已成功任务的链接，再复制发布稿。

凭证和模型密钥保存到 iPhone Keychain；任务、断点、草稿保存在本机。AI 改写会把文案发送至配置的中转站；识别到的网盘 URL 先以随机标记保护，然后在手机还原。

## 中断恢复

队列逐条处理，同平台转存，不是跨网盘搬运。保存所有转存后的文件 ID，创建的分享覆盖整个分享顶层。每次写请求前保存断点；拿到任务 ID 后可继续查询。未拿到远程任务编号的中断显示“待核对”，不会自动重新转存。到网盘核对后可导入已有分享；确认未执行后才重置任务。iOS 后台时间有限，批量任务期间请保持前台。

## 构建

Mac 上安装 Xcode 与 XcodeGen，运行 xcodegen generate，然后 xcodebuild -project CloudFlow.xcodeproj -scheme CloudFlow -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build。

GitHub Actions 的 Build iOS IPA 会运行链接及断点回归测试、真机 Release 编译、模拟器启动截图，打包未签名 IPA。无须 Apple 签名证书。

## 验证范围

构建与离线测试结果以当前 Actions 为准。未提供实际账号，三家真实登录、转存、分享及 AI 中转站调用仍待手机验收；编译通过不代表账号实测通过。适配参考 wgx0307/netdisk，版本及许可证见 THIRD_PARTY_NOTICES.md。平台接口与验证流程变动可能需要更新适配器。

旧 server/ 仅保留为历史实现，不参与手机端调用或构建。
