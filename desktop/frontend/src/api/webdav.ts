/** WebDAV API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/webdavapi";
import { call, callList } from "./client";

export const webdavApi = {
  /** 当前配置（不含密码）。 */
  getConfig: () => call(binding.GetConfig()),

  /** 保存配置；password 为空表示保持原密码。 */
  saveConfig: (
    url: string,
    username: string,
    password: string,
    rootPath: string,
    autoSync: boolean,
  ) => call(binding.SaveConfig(url, username, password, rootPath, autoSync)),

  /** 连接测试。 */
  test: () => call(binding.Test()),

  /** 列出远端目录。 */
  list: (relPath = "") => callList(binding.List(relPath)),

  /** 上传数据库备份。 */
  uploadBackup: () => call(binding.UploadBackup()),

  /** 下载备份到本地目录。 */
  downloadBackup: (remotePath: string, localDir = "") =>
    call(binding.DownloadBackup(remotePath, localDir)),

  /** 删除远端文件。 */
  delete: (relPath: string) => call(binding.Delete(relPath)),
};
