/** 书源管理 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/sourceapi";
import { call, callList } from "./client";

export const sourceApi = {
  /** 书源列表；group 为空表示全部。 */
  list: (group = "") => callList(binding.List(group)),

  get: (id: number) => call(binding.Get(id)),

  /** 新增或更新；id 为 0 表示新增。 */
  save: (
    id: number,
    name: string,
    group: string,
    url: string,
    comment: string,
    raw: string,
    enabled: boolean,
    order: number,
  ) => call(binding.Save(id, name, group, url, comment, raw, enabled, order)),

  delete: (id: number) => call(binding.Delete(id)),

  setEnabled: (id: number, enabled: boolean) =>
    call(binding.SetEnabled(id, enabled)),

  /** 导入书源 JSON。 */
  import: (payload: string, overwrite: boolean) =>
    call(binding.Import(payload, overwrite)),

  /** 导出书源 JSON 字符串。 */
  export: (ids: number[] = []) => call(binding.Export(ids)),

  /** 校验书源。 */
  validate: (ids: number[] = []) => call(binding.Validate(ids)),

  /** 单源搜索。 */
  search: (sourceId: number, keyword: string, page = 1) =>
    callList(binding.Search(sourceId, keyword, page)),

  /** 全源搜索。 */
  searchAll: (keyword: string, page = 1) =>
    callList(binding.SearchAll(keyword, page)),

  /** 开启「发现」的书源（只含名字与分组，分类按需取）。 */
  listExploreSources: () => callList(binding.ListExploreSources()),

  /** 解析某个书源的发现分类，展开书源时调用。 */
  exploreKinds: (sourceId: number) => callList(binding.ExploreKinds(sourceId)),

  /** 拉取某个分类下的书单；url 为空表示用该书源的首个分类。 */
  explore: (sourceId: number, url = "", page = 1) =>
    callList(binding.Explore(sourceId, url, page)),

  /**
   * 搜索结果/发现书单加入书架。
   *
   * name/author 一定要传：书源的详情页规则可能取不到书名（改版、需登录等），
   * 后端会拿列表页这两个值兜底，否则落库时会因为「书名不能为空」失败。
   */
  addToShelf: (
    sourceId: number,
    bookUrl: string,
    name = "",
    author = "",
    groupId = 0,
  ) => call(binding.AddToShelf(sourceId, bookUrl, name, author, groupId)),
};
