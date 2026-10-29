/**
 * 领域类型出口。
 *
 * 这里只做「再导出」：把 Wails 生成的 DTO 类型以业务语义命名暴露给 UI。
 * UI 组件一律从 `@/types` 取类型，不直接引用 bindings 目录
 * （见 ARCHITECTURE.md R4），这样将来调整生成路径或重命名字段时，
 * 只需改动本文件。
 */

export type {
  BookBrief,
  BookDetail,
  BookGroupView,
  ChapterContent,
  ChapterItem,
  ExploreKindView,
  ExploreSourceBrief,
  ExportResult,
  ImportFailure,
  ImportResult,
  ReadingPosition,
  SearchResultView,
  SourceCheckResult,
  SourceFailure,
  SourceImportResult,
  SourceView,
  SyncProgress,
  ValidationIssue,
  WebDAVConfigView,
  WebDAVEntryView,
} from "@bindings/github.com/legado/desktop/internal/app/dto/models";

/** 书籍来源类型：网络书 / 本地书。 */
export type BookKind = "web" | "local";

/** 书籍格式。 */
export type BookFormat = "epub" | "txt" | "pdf" | "comic" | "unknown";
