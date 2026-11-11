package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// DictionaryRepository 是**只读**词典库的访问端口。
//
// 词典库与 legado.db 完全独立：不进迁移、不参与事务、坏了删掉重装即可。
// 因此这里没有 Write/Update 之类的方法——词库是只读产物，不存在"改一个词条"
// 这种需求，给了写接口只会诱使上层去做不该做的事。
type DictionaryRepository interface {
	// LookupWord 精确查主表，未命中返回 domain.ErrNotFound。
	LookupWord(ctx context.Context, word string) (*domain.DictEntry, error)

	// LookupForm 在词形表里把变体还原成原型。
	//
	// 返回 (原型, 关系类型, 是否命中)。关系类型是 ECDICT exchange 的类型码，
	// 逗号分隔（`p,d` = 过去式且过去分词），空串表示库未记录关系。
	// 有了它才能对 had / were / been 这类不规则变化说出准确的中文说明，
	// 否则只能笼统地说「变形」。
	// 未命中不算错误，因此不返回 ErrNotFound。
	LookupForm(ctx context.Context, variant string) (lemma string, types string, ok bool, err error)

	// LookupZh 查汉英库。同一个中文词可能有多条（`东西`：east and west / thing），
	// 按拼音去重后全部返回。
	LookupZh(ctx context.Context, word string) ([]domain.DictEntry, error)

	// PrefixWords 取以 prefix 开头的前 limit 个词，用于「你是不是要找…」。
	PrefixWords(ctx context.Context, prefix string, limit int) ([]string, error)

	// Close 释放只读连接。
	Close() error
}

// DictPackageInstaller 管理扩展包的安装与删除。
//
// 这一层的接口只描述**动作**，不描述展示形态：
// 「装了什么、多大、什么时候装的」由 app 层组装成 dto 给界面，
// 端口里放 dto 会让 adapter 反过来依赖 app 层。
type DictPackageInstaller interface {
	// Install 后台安装扩展包，立即返回，进度走事件。
	Install(ctx context.Context, packID, sourceID, customURL string) error
	// RetryInstall 换源重试，保留已下载的字节。
	RetryInstall(ctx context.Context, packID, sourceID, customURL string) error
	// CancelInstall 取消安装并清理半截文件。
	CancelInstall(packID string) error
	// Remove 删除扩展包；内置核心拒绝删除。
	Remove(ctx context.Context, packID string) error
	// ImportLocal 用本地源文件安装。
	ImportLocal(ctx context.Context, packID, path string) error
}
