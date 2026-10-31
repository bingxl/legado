/** 全局替换规则 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/replaceruleapi";
import { call, callList } from "./client";

export const replaceRuleApi = {
  /** 全部替换规则。 */
  list: () => callList(binding.List()),

  get: (id: number) => call(binding.Get(id)),

  /** 新增或更新；id 为 0 表示新增。raw 传空串时后端兜成 `[]`。 */
  save: (
    id: number,
    name: string,
    group: string,
    raw: string,
    enabled: boolean,
    order = 0,
  ) => call(binding.Save(id, name, group, raw, enabled, order)),

  delete: (id: number) => call(binding.Delete(id)),

  setEnabled: (id: number, enabled: boolean) =>
    call(binding.SetEnabled(id, enabled)),

  /** 导入规则文本。传内容而非路径：安卓端选文件返回的是内容 URI，后端按路径读不一定有权限。 */
  import: (payload: string, overwrite: boolean) =>
    call(binding.Import(payload, overwrite)),

  /** 导出为 JSON 文本；ids 为空表示全部。 */
  export: (ids: number[] = []) => call(binding.Export(ids)),
};
