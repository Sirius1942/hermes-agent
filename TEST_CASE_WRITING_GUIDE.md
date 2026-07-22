# Hermes Rodski 用例编写指南

**版本**: Rodski 8.1.1 / Hermes 适配 1.0  
**日期**: 2026-07-14  
**适用范围**: `.testloop/rodski/`

本文件是 Hermes 仓库内 Rodski 用例的项目级入口。完整框架契约由当前本机 Rodski CLI、
`rodski capabilities`、安装包 XSD 与 Rodski 源码仓的
`rodski/docs/TEST_CASE_WRITING_GUIDE.md` 共同提供；出现冲突时必须执行最窄 dry-run，不得
静默猜测或为通过测试而迁就产品缺陷。

## 目录与三元结构

每个模块必须包含：

```text
case/*.xml
model/model.xml
data/data.sqlite
data/globalvalue.xml
plan/*.xml
result/                 # 本地生成，不提交
```

用例遵循“关键字/action + model + data”结构：Case 负责编排，Model 负责 UI/API/DB 定位，
SQLite 负责输入与期望数据，GlobalValue 只保存非秘密的环境值。`run` 关键字的 `model`
表示 `fun/` 下的脚本工程名，`data` 表示脚本和参数。

## Hermes 强制规则

- WebUI 导航使用 `navigate`；接口使用 `send + verify`；UI 原子操作放入 `type` 数据行；
  禁止 `open/http_get/http_post/assert_json/assert_status` 等伪关键字。
- Web 定位器必须来自真实 DOM 探查或现有稳定属性，优先 CSS `data-*`、`id`、ARIA、稳定
  href/name，再考虑文本；不使用 hash class、脆弱 nth-child 或未经验证的绝对 XPath。
- 原生 macOS App 无稳定 DOM 时，可以用 `run` 调用标准库脚本、系统窗口 API、OCR、截图、
  Xcode 测试与端口/进程检查，但脚本必须返回结构化 JSON，失败时返回非零退出码。
- App 进程用例禁止调用全局 `hermes dashboard --stop`；只允许终止用例自己启动且已记录的
  PID，用户已有 9119 Dashboard PID 必须保持不变。
- 测试不得写入或泄露密码、API Key、Session token、OAuth 凭据、真实消息正文或秘密值。
- 默认只执行只读页面和隔离端口；涉及写操作的场景必须自建数据、可清理、可重复执行。
- 每条 XML 必须独立执行；不依赖其他 case 产生的可变状态。
- Rodski 实跑失败先区分产品缺陷、用例问题和环境问题，不允许直接修改正确期望来“变绿”。

## 必跑校验

```bash
rodski --version
rodski capabilities
python3 <rodski-case-writer>/scripts/rodski_case_guard.py \
  --repo "$PWD" --target <module> --rodski-bin <rodski>
rodski data validate <module>
rodski run <module>/case --dry-run --output-format json
rodski run <module>/case --output-format json
```

Web 模块真实执行增加 `--browser chromium --headless`；需要截图或报告时增加 `--report html`。
原始结果保存在模块 `result/`，TestLoop 追溯矩阵记录最近证据路径与结论。
