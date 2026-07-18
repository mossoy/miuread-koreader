# v0.1.0-dev.14：公开单通道 OTA

- 固定更新清单：`https://raw.githubusercontent.com/miumiupy98-art/miuread-koreader/main/update.json`
- 删除公开版中的正式/内测通道切换和手动地址输入。
- 更新清单兼容 0.3.6.7 使用的 `package_url`、`sha256`、`delete_list` 字段。
- 下载时强制进行 SHA-256 校验。
- 安装前备份当前插件，安装失败时恢复旧版本。
- 用户登录、书籍、封面、阅读进度和设置存储在插件目录之外，不随 OTA 被覆盖。
- dev.14 需要手动安装一次；之后可以通过“检查更新”升级。
