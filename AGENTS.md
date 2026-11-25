# AGENTS.md — CloudFlow 0.4.0（给 Codex 的操作说明）

## 目标
把本目录推送到 GitHub 仓库，运行 GitHub Actions 工作流 **Build iOS IPA**，取回未签名 IPA（TrollStore 安装用）。

## 标准流程
1. 仓库根目录 = 本目录（含 `project.yml`、`App/`、`.github/workflows/ios-ipa.yml`）。
2. 推送到 `main`（推送 main 或 `v*` 标签都会自动触发；也可手动触发）：
   ```bash
   git add -A && git commit -m "CloudFlow 0.4.0 UI redesign" && git push origin main
   # 或手动触发：
   gh workflow run "Build iOS IPA" --ref main
   ```
3. 等待并查看：
   ```bash
   gh run list --workflow "Build iOS IPA" -L 1
   gh run watch <RUN_ID> --exit-status
   ```
4. 下载产物：
   ```bash
   gh run download <RUN_ID> -n CloudFlow-0.4.0-ipa -D dist
   gh run download <RUN_ID> -n CloudFlow-0.4.0-screens -D dist/screens   # 模拟器截图
   ```
   IPA：`dist/CloudFlow-0.4.0-unsigned.ipa`

## 编译失败时
- 看错误：`gh run view <RUN_ID> --log-failed`（工作流的 “Show compile errors” 步骤会列出 `error:` 行）。
- 只修复编译错误，**保持设计和行为不变**；修完重新推送，直到 IPA 产出。
- 约束：
  - 最低 iOS 16.0、Swift 5 语言模式。不要使用 iOS 17+ API（如 `symbolEffect`、`sensoryFeedback`、两参数 `onChange`、`containerRelativeFrame`、`scrollTargetBehavior`）；如需使用须加 `if #available`。
  - UI 文件：`App/CloudFlowApp.swift`、`App/WorkspaceStyle.swift`、`App/DriveBrowser.swift`（仅视图部分）。
  - **不要修改**网盘适配与数据逻辑：`DirectDrive.swift`、`DriveHTTP.swift`、`XunleiWebClient.swift`、`BaiduSharePage.swift`、`Domain.swift`、`Services.swift`、`DriveAccount.swift`，以及 `Tests/`。
  - `WorkspaceModel.swift` 中 `#if DEBUG verifyWorkspace()` 的断言是模拟器自检，不能删除或放宽。
  - 若提示表达式过于复杂（"unable to type-check this expression in reasonable time"），把该视图拆成小的子 View 或计算属性即可。
- 模拟器步骤失败不影响 IPA：IPA 在模拟器检查之前已上传为 `CloudFlow-0.4.0-ipa`。

## 版本
`project.yml` 中 `MARKETING_VERSION: 0.4.0`、`CURRENT_PROJECT_VERSION: 5`；Bundle ID `app.cloudflow.personal`（与旧版相同，可覆盖安装，数据保留）。
