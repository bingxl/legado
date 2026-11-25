/// legado 纯 Dart 内核的公开面。
///
/// 只导出宿主真正需要的东西：内核单例、错误、模块契约、方法表。
/// 领域模型与规则引擎内部实现不外露 —— 一旦外露，UI 就会绕过服务层直接拼规则，
/// 到时候「同一份逻辑两种行为」几乎必然发生。
library;

export 'src/core.dart';
export 'src/js/js_engine.dart';
export 'src/kernel/envelope.dart';
export 'src/kernel/errors.dart';
export 'src/kernel/module.dart';
export 'src/kernel/registry.dart' show MethodDef, MethodHandler, Registry;
// 反爬验证：宿主（App）要注册「内置浏览器」处理器，必须拿得到这几个类型。
// 只导出注册表与三条数据结构，CookieStore / HTTP 客户端仍然不外露。
export 'src/net/cloudflare.dart'
    show
        BrowserVerificationRequest,
        BrowserVerificationResult,
        BrowserVerificationHandler,
        CaptchaHandler,
        HostVerification,
        browserSafeHeaders;
