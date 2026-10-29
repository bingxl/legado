package domain

import "errors"

// 领域错误。
//
// 约定：app 层返回这些错误，api 层统一转换为前端可展示的消息，
// 绝不允许把 database/sql 等基础设施的原始错误直接抛给前端。
var (
	// ErrNotFound 表示目标资源不存在。
	ErrNotFound = errors.New("资源不存在")

	// ErrAlreadyExists 表示资源冲突（如重复导入同一本书）。
	ErrAlreadyExists = errors.New("资源已存在")

	// ErrInvalidArgument 表示调用方传入的参数不合法。
	ErrInvalidArgument = errors.New("参数不合法")

	// ErrUnsupportedFormat 表示书籍格式不受支持。
	ErrUnsupportedFormat = errors.New("不支持的书籍格式")

	// ErrParseFailed 表示解析书籍或规则失败。
	ErrParseFailed = errors.New("解析失败")

	// ErrNotConfigured 表示功能所需的配置缺失（如未配置 WebDAV）。
	ErrNotConfigured = errors.New("功能未配置")

	// ErrRemoteFailed 表示调用外部服务（WebDAV、书源站点）失败。
	ErrRemoteFailed = errors.New("远程服务调用失败")
)
