package api

import (
	"context"
	"fmt"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
)

// DictAPI 暴露阅读器取词与词库管理能力。
type DictAPI struct {
	svc dictService
}

// dictService 是词典服务的能力契约。
//
// 只声明绑定层真正用到的方法，不引整个 *app.DictService：
// 这样单测可以塞一个极小的假实现，不必构造词库文件。
type dictService interface {
	Lookup(ctx context.Context, text, hint string) (dto.DictResultView, error)
	Status(ctx context.Context) dto.DictStatusView

	SourcesFor(ctx context.Context, packID string) ([]dto.DictSourceView, error)
	SourceConfig(ctx context.Context, packID string) (dto.DictSourceConfigView, error)
	Preview(ctx context.Context, packID, sourceID, customURL string) (dto.DictSourceConfigView, error)
	SetSource(ctx context.Context, mode, sourceID, customURL string) error
	Probe(ctx context.Context, packID, sourceID, customURL string) (dto.DictProbeView, error)

	Install(ctx context.Context, packID, sourceID, customURL string) error
	RetryInstall(ctx context.Context, packID, sourceID, customURL string) error
	CancelInstall(packID string) error
	Remove(ctx context.Context, packID string) error
	ImportLocal(ctx context.Context, packID, path string) error
}

// NewDictAPI 创建词典绑定服务。
func NewDictAPI(svc dictService) *DictAPI {
	return &DictAPI{svc: svc}
}

// Lookup 查询选区文本。
//
// hint 取 en / zh / auto：前端已经判过方向时可以指定，
// 避免「全大写英文被当成中文」这类误判。
func (a *DictAPI) Lookup(text string, hint string) (dto.DictResultView, error) {
	if strings.TrimSpace(text) == "" {
		return dto.DictResultView{}, errBadRequest("缺少要查的内容")
	}
	// 长度闸门放在绑定层：这里是所有调用路径的必经之处，
	// 前端误把整章正文传进来时不会打到词库上。
	if n := len([]rune(text)); n > domain.MaxQueryRune {
		return dto.DictResultView{}, errBadRequest(fmt.Sprintf("一次最多查 %d 个字符", domain.MaxQueryRune))
	}
	switch hint {
	case "", "auto", "en", "zh":
	default:
		return dto.DictResultView{}, errBadRequest("hint 只能是 auto / en / zh")
	}
	return a.svc.Lookup(newCtx(), text, hint)
}

// DictStatus 返回各词库包的就位状态。
func (a *DictAPI) DictStatus() (dto.DictStatusView, error) {
	return a.svc.Status(newCtx()), nil
}

// DictSources 返回针对某个包过滤后的下载源列表。
//
// 必须带 packID：jsDelivr 能不能用取决于包体大小（20 MB 上限），
// 不带包就无从判断，只能给出一个与实际不符的列表。
func (a *DictAPI) DictSources(packID string) ([]dto.DictSourceView, error) {
	if strings.TrimSpace(packID) == "" {
		return nil, errBadRequest("缺少词库包 ID")
	}
	return a.svc.SourcesFor(newCtx(), packID)
}

// GetDictSource 返回当前下载源配置，并回显最终会请求的地址。
func (a *DictAPI) GetDictSource(packID string) (dto.DictSourceConfigView, error) {
	return a.svc.SourceConfig(newCtx(), packID)
}

// PreviewDictSource 预演「这组配置会请求哪个地址」，不发网络请求。
//
// 设置页每改一次选中项就调它：用户填 https://ghfast.top 之后要能一眼看到
// 最终 URL 长什么样，否则「填了却生效成另一种意思」根本发现不了。
func (a *DictAPI) PreviewDictSource(packID string, sourceID string, customURL string) (dto.DictSourceConfigView, error) {
	if strings.TrimSpace(packID) == "" {
		return dto.DictSourceConfigView{}, errBadRequest("缺少词库包 ID")
	}
	return a.svc.Preview(newCtx(), packID, sourceID, customURL)
}

// SetDictSource 保存下载源配置（模式、选中源、自定义地址）。
func (a *DictAPI) SetDictSource(mode string, sourceID string, customURL string) error {
	return a.svc.SetSource(newCtx(), mode, sourceID, customURL)
}

// ProbeDictSource 对指定源做一次 64 KB Range 探测。
func (a *DictAPI) ProbeDictSource(packID string, sourceID string, customURL string) (dto.DictProbeView, error) {
	if strings.TrimSpace(packID) == "" {
		return dto.DictProbeView{}, errBadRequest("缺少词库包 ID")
	}
	if strings.TrimSpace(sourceID) == "" {
		return dto.DictProbeView{}, errBadRequest("缺少下载源 ID")
	}
	return a.svc.Probe(newCtx(), packID, sourceID, customURL)
}

// InstallDict 开始安装扩展包；立即返回，进度走 dict:install:progress 事件。
func (a *DictAPI) InstallDict(packID string, sourceID string, customURL string) error {
	if strings.TrimSpace(packID) == "" {
		return errBadRequest("缺少词库包 ID")
	}
	return a.svc.Install(newCtx(), packID, sourceID, customURL)
}

// RetryInstall 换源重试，保留已下载的字节。
func (a *DictAPI) RetryInstall(packID string, sourceID string, customURL string) error {
	if strings.TrimSpace(packID) == "" {
		return errBadRequest("缺少词库包 ID")
	}
	return a.svc.RetryInstall(newCtx(), packID, sourceID, customURL)
}

// CancelInstall 取消安装并清理半截文件。
func (a *DictAPI) CancelInstall(packID string) error {
	if strings.TrimSpace(packID) == "" {
		return errBadRequest("缺少词库包 ID")
	}
	return a.svc.CancelInstall(packID)
}

// RemoveDict 删除扩展包；内置核心会被拒绝。
func (a *DictAPI) RemoveDict(packID string) error {
	if strings.TrimSpace(packID) == "" {
		return errBadRequest("缺少词库包 ID")
	}
	return a.svc.Remove(newCtx(), packID)
}

// ImportDictFile 用本地文件安装扩展包。
//
// path 由前端通过系统文件对话框取得——安卓上拿不到桌面路径，
// 所以这条路径在移动端隐藏，而不是给一个点了会失败的按钮。
func (a *DictAPI) ImportDictFile(packID string, path string) error {
	if strings.TrimSpace(packID) == "" {
		return errBadRequest("缺少词库包 ID")
	}
	if strings.TrimSpace(path) == "" {
		return errBadRequest("没有选择文件")
	}
	return a.svc.ImportLocal(newCtx(), packID, path)
}
