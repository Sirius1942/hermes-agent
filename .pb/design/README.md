# 设计索引

本目录保存跨迭代设计资料，帮助贡献者定位所有权并维护系统不变量。

- `CODEBASE_MAP.md`：当前架构和执行路径指南。
- `SECONDARY_DEVELOPMENT_ARCHITECTURE.md`：面向二次开发的分层架构、扩展选型和验证路线。
- `.pb/specs/SPECS_CONTRACT_ARCHITECTURE.md`：契约层级和变更门禁。
- 迭代专属设计：`.pb/iterations/iteration-XX/design.md`。

设计文档应说明边界、状态转换、失败模式、兼容性、验证和回滚。不要逐行重复源码，
也不要在没有具体消费者时引入基础设施。
