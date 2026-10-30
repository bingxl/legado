// 书源编辑表单的字段定义。
//
// 字段清单与分组顺序对齐 Legado 官方 Web 编辑器（modules/web 的 bookSourceEditConfig），
// 这样桌面端编辑过的书源推到手机端不会出现「字段对不上」的困惑。
//
// 为什么用配置驱动而不是手写 70 个 el-form-item：字段会随上游增加，
// 手写意味着每次都要改模板；配置化后只需在这里加一行，表单、JSON 视图、
// 调试面板都会跟着走。
//
// path 是字段在书源 JSON 里的路径，除首层外都在 ruleSearch / ruleBookInfo 这类
// 规则命名空间下——与 Legado 的 bookSource 序列化结构完全一致。

export type SourceFieldType = "String" | "Boolean" | "Number" | "Array";

export interface SourceFieldDef {
  /** 表单标签 */
  title: string;
  /** 字段在 JSON 中的路径，长度 1 为顶层字段 */
  path: string[];
  type: SourceFieldType;
  /** 输入框占位符，同时充当字段说明 */
  hint?: string;
  /** 是否必填（保存前校验） */
  required?: boolean;
  /** type 为 Array 时的可选值，下标即存库值 */
  options?: string[];
}

export interface SourceFieldGroup {
  key: string;
  name: string;
  fields: SourceFieldDef[];
}

export const BOOK_SOURCE_GROUPS: SourceFieldGroup[] = [  {
    key: "base",
    name: "基础",
    fields: [
      { title: "源类型", path: ["bookSourceType"], type: "Array", required: true, options: ["文本","音频","图片","文件"] },
      { title: "源域名", path: ["bookSourceUrl"], type: "String", hint: "通常填写网站主页,例: https://www.qidian.com", required: true },
      { title: "源名称", path: ["bookSourceName"], type: "String", hint: "会显示在源列表", required: true },
      { title: "源分组", path: ["bookSourceGroup"], type: "String", hint: "描述源的特征信息" },
      { title: "源注释", path: ["bookSourceComment"], type: "String", hint: "描述源作者和状态" },
      { title: "登录地址", path: ["loginUrl"], type: "String", hint: "填写网站登录网址,仅在需要登录的源有用" },
      { title: "登录界面", path: ["loginUi"], type: "String", hint: "自定义登录界面" },
      { title: "登录检测", path: ["loginCheckJs"], type: "String", hint: "登录检测js" },
      { title: "封面解密", path: ["coverDecodeJs"], type: "String", hint: "封面解密js" },
      { title: "链接验证", path: ["bookUrlPattern"], type: "String", hint: "书籍URL正则，当详情页URL与源URL的域名不一致时有效，用于添加网址" },
      { title: "请求头", path: ["header"], type: "String", hint: "客户端标识" },
      { title: "变量说明", path: ["variableComment"], type: "String", hint: "书源变量说明" },
      { title: "并发率", path: ["concurrentRate"], type: "String", hint: "并发率，如1000(访问间隔1000ms)或者1/1000(1000ms内访问1次)" },
      { title: "js库", path: ["jsLib"], type: "String", hint: "js库, 可填写js或者key-value object获取在线js文件" },
    ],
  },
  {
    key: "search",
    name: "搜索",
    fields: [
      { title: "搜索地址", path: ["searchUrl"], type: "String", hint: "[域名可省略]/search.php@kw={{key}}" },
      { title: "校验文字", path: ["ruleSearch","checkKeyWord"], type: "String", hint: "校验关键字，强烈建议填写" },
      { title: "列表规则", path: ["ruleSearch","bookList"], type: "String", hint: "选择书籍节点 (规则结果为List<Element>)" },
      { title: "书名规则", path: ["ruleSearch","name"], type: "String", hint: "选择节点书名 (规则结果为String)" },
      { title: "作者规则", path: ["ruleSearch","author"], type: "String", hint: "选择节点作者 (规则结果为String)" },
      { title: "分类规则", path: ["ruleSearch","kind"], type: "String", hint: "选择节点分类信息 (规则结果为String)" },
      { title: "字数规则", path: ["ruleSearch","wordCount"], type: "String", hint: "选择节点字数信息 (规则结果为String)" },
      { title: "最新章节", path: ["ruleSearch","lastChapter"], type: "String", hint: "选择节点最新章节 (规则结果为String)" },
      { title: "简介规则", path: ["ruleSearch","intro"], type: "String", hint: "选择节点书籍简介 (规则结果为String)" },
      { title: "封面规则", path: ["ruleSearch","coverUrl"], type: "String", hint: "选择节点书籍封面 (规则结果为String类型的url)" },
      { title: "详情地址", path: ["ruleSearch","bookUrl"], type: "String", hint: "选择书籍详情页网址 (规则结果为String类型的url)" },
    ],
  },
  {
    key: "find",
    name: "发现",
    fields: [
      { title: "发现地址", path: ["exploreUrl"], type: "String", hint: "单个发现格式<name>::<url>或者{url:<url>,title:<name>,style:...}；前者用换行符或者&&连接，后者放在数组内；可用js动态生成" },
      { title: "列表规则", path: ["ruleExplore","bookList"], type: "String", hint: "选择书籍节点 (规则结果为List<Element>)" },
      { title: "书名规则", path: ["ruleExplore","name"], type: "String", hint: "选择节点书名 (规则结果为String)" },
      { title: "作者规则", path: ["ruleExplore","author"], type: "String", hint: "选择节点作者 (规则结果为String)" },
      { title: "分类规则", path: ["ruleExplore","kind"], type: "String", hint: "选择节点分类信息 (规则结果为String)" },
      { title: "字数规则", path: ["ruleExplore","wordCount"], type: "String", hint: "选择节点字数信息 (规则结果为String)" },
      { title: "最新章节", path: ["ruleExplore","lastChapter"], type: "String", hint: "选择节点最新章节 (规则结果为String)" },
      { title: "简介规则", path: ["ruleExplore","intro"], type: "String", hint: "选择节点书籍简介 (规则结果为String)" },
      { title: "封面规则", path: ["ruleExplore","coverUrl"], type: "String", hint: "选择节点书籍封面 (规则结果为String类型的url)" },
      { title: "详情地址", path: ["ruleExplore","bookUrl"], type: "String", hint: "选择书籍详情页网址 (规则结果为String类型的url)" },
    ],
  },
  {
    key: "detail",
    name: "详情",
    fields: [
      { title: "预处理", path: ["ruleBookInfo","init"], type: "String", hint: "用于加速详情信息检索，只支持AllInOne规则" },
      { title: "书名规则", path: ["ruleBookInfo","name"], type: "String", hint: "选择节点书名 (规则结果为String)" },
      { title: "作者规则", path: ["ruleBookInfo","author"], type: "String", hint: "选择节点作者 (规则结果为String)" },
      { title: "分类规则", path: ["ruleBookInfo","kind"], type: "String", hint: "选择节点分类信息 (规则结果为String)" },
      { title: "字数规则", path: ["ruleBookInfo","wordCount"], type: "String", hint: "选择节点字数信息 (规则结果为String)" },
      { title: "最新章节", path: ["ruleBookInfo","lastChapter"], type: "String", hint: "选择节点最新章节 (规则结果为String)" },
      { title: "简介规则", path: ["ruleBookInfo","intro"], type: "String", hint: "选择节点书籍简介 (规则结果为String)" },
      { title: "封面规则", path: ["ruleBookInfo","coverUrl"], type: "String", hint: "选择节点书籍封面 (规则结果为String类型的url)" },
      { title: "目录地址", path: ["ruleBookInfo","tocUrl"], type: "String", hint: "选择书籍详情页网址 (规则结果为String类型的url, 与详情页相同时可省略)" },
      { title: "修改书籍", path: ["ruleBookInfo","canReName"], type: "String", hint: "允许修改书名作者(规则结果为String类型, 默认不允许)" },
      { title: "下载URL", path: ["ruleBookInfo","downloadUrls"], type: "String", hint: "文件类书源下载地址 (规则结果为String类型的url, 多个链接返回数组)" },
    ],
  },
  {
    key: "directory",
    name: "目录",
    fields: [
      { title: "更新前JS", path: ["ruleToc","preUpdateJs"], type: "String", hint: "更新目录前调用JS 动态更新目录链接" },
      { title: "列表规则", path: ["ruleToc","chapterList"], type: "String", hint: "选择目录列表的章节节点 (规则结果为List<Element>)" },
      { title: "章节名称", path: ["ruleToc","chapterName"], type: "String", hint: "选择章节名称 (规则结果为String)" },
      { title: "章节地址", path: ["ruleToc","chapterUrl"], type: "String", hint: "选择章节链接 (规则结果为String类型的Url)" },
      { title: "标题处理", path: ["ruleToc","formatJs"], type: "String", hint: "遍历去重后的章节列表的回调，提供index(章节序号从1开始)、title(章节标题)变量，额外提供gInt(初始值0)，返回值作为新的标题" },
      { title: "卷名标识", path: ["ruleToc","isVolume"], type: "String", hint: "章节名称是否是卷名 (规则结果为Bool)" },
      { title: "章节信息", path: ["ruleToc","updateTime"], type: "String", hint: "选择章节信息（如更新时间） (规则结果为String)" },
      { title: "收费标识", path: ["ruleToc","isVip"], type: "String", hint: "章节是否为VIP章节 (规则结果为Bool)" },
      { title: "购买标识", path: ["ruleToc","isPay"], type: "String", hint: "章节是否为已购买 (规则结果为Bool)" },
      { title: "翻页规则", path: ["ruleToc","nextTocUrl"], type: "String", hint: "选择目录下一页链接 (规则结果为List<String>或String)" },
    ],
  },
  {
    key: "content",
    name: "正文",
    fields: [
      { title: "正文规则", path: ["ruleContent","content"], type: "String", hint: "选择正文内容 (规则结果为String)" },
      { title: "标题规则", path: ["ruleContent","title"], type: "String", hint: "获取结果将会覆盖章节标题 (规则结果为String)" },
      { title: "翻页规则", path: ["ruleContent","nextContentUrl"], type: "String", hint: "选择下一分页(不是下一章)链接 (规则结果为String类型的Url)" },
      { title: "脚本注入", path: ["ruleContent","webJs"], type: "String", hint: "注入javascript，用于模拟鼠标点击等，必须有返回值，一般为String类型" },
      { title: "资源正则", path: ["ruleContent","sourceRegex"], type: "String", hint: "匹配资源的url特征，用于嗅探" },
      { title: "替换规则", path: ["ruleContent","replaceRegex"], type: "String", hint: "多页内容合并后替换，用于正文净化" },
      { title: "图片样式", path: ["ruleContent","imageStyle"], type: "String", hint: "FULL:铺满 不填:默认样式" },
      { title: "图片解密", path: ["ruleContent","imageDecode"], type: "String", hint: "填写JavaScript 返回解密图片的bytes " },
      { title: "购买操作", path: ["ruleContent","payAction"], type: "String", hint: "填写JavaScript 返回购买链接或者调用购买接口" },
    ],
  },
  {
    key: "other",
    name: "其他",
    fields: [
      { title: "启用搜索", path: ["enabled"], type: "Boolean" },
      { title: "启用发现", path: ["enabledExplore"], type: "Boolean" },
      { title: "CookieJar", path: ["enabledCookieJar"], type: "Boolean" },
      { title: "搜索权重", path: ["weight"], type: "Number" },
      { title: "排序编号", path: ["customOrder"], type: "Number" },
    ],
  },
];

/** 所有字段的扁平列表，便于按 path 查找。 */
export const BOOK_SOURCE_FIELDS: SourceFieldDef[] = BOOK_SOURCE_GROUPS.flatMap((g) => g.fields);

/** 必填字段的标签，保存时用于提示缺了哪一项。 */
export const REQUIRED_FIELD_TITLES: string[] = BOOK_SOURCE_FIELDS.filter((f) => f.required).map((f) => f.title);
