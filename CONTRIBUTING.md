# Contributing

欢迎提交 issue 和 pull request。请勿提交真实数据库地址、密码、查询结果或连接配置。

使用 macOS 14+ 和 Xcode 26+（Swift 6.2+）的 Swift 工具链。运行 `swift test` 检查核心逻辑，运行 `bash scripts/build-app.sh` 打包应用。

数据库集成测试默认跳过。使用独立、可删除的本地 MySQL 实例：

```sh
HARBOR_TEST_PORT=13317 HARBOR_TEST_USER=root swift test
```

如需密码，通过 `HARBOR_TEST_PASSWORD` 环境变量提供。测试会创建并删除以 `harbor_test_` 开头的随机数据库；不要指向生产服务器。

UI 与 AppKit 表格位于 `Sources/Harbor`，连接、SQL 生成和存储位于 `Sources/HarborCore`。变更筛选、分页、排序、转义或字段更新时，请添加相应行为测试。
