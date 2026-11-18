-- 书源登录信息（含漫画源：它们同为 bookSourceType 的书源）。
--
-- 主键用书源地址而不是书源 id：登录态跟着站点走。重新导入同一份书源 JSON
-- 会换 id，但地址不变，登录应该继续有效；反之换了域名，旧登录必然失效。
--
-- form_json 存 loginUi 表单的填写值（JSON 对象）。原版把它 AES 加密后放在
-- SharedPreferences，桌面端不再重复加密：同一份 cookie 本来就会以明文落在
-- cookies.json 里（引擎的 CookieStore），对数据库单加密只是自我安慰。
-- 真正要做的是别让它出现在日志里、界面上只显示掩码。
CREATE TABLE source_login (
    source_url TEXT    PRIMARY KEY,
    form_json  TEXT    NOT NULL DEFAULT '',
    header     TEXT    NOT NULL DEFAULT '',   -- 登录请求头 JSON（通常含 Cookie）
    updated_at INTEGER NOT NULL DEFAULT 0     -- Unix 秒
);
