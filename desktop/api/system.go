package api

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// safeAreaFunc 返回当前平台的安全区 JSON。由 main 注入，避免本层出现平台分支。
type safeAreaFunc func() string

// setFullscreenFunc 切换主窗口全屏态，返回操作后的实际状态。
//
// 与 safeAreaFunc 同样由 main 注入：桌面端操作窗口，安卓端没有"窗口宿主"这一层
// （全屏沉浸由阅读器的栏位开关负责），返回 false 即可。这样本层零平台分支。
type setFullscreenFunc func(on bool) bool

// isFullscreenFunc 查询主窗口当前是否全屏。
//
// 需要单独一个函数而不是复用 set 的返回值：系统级退出（Win+↓、mac 绿灯）
// 不经过我们的按钮，前端只能主动查一次来对账。
type isFullscreenFunc func() bool

// SystemAPI 提供与操作系统交互的能力（文件对话框、平台信息等）。
//
// 之所以把这些放在绑定层而非 app 层：它们本质上是 UI 交互，
// 依赖 Wails 运行时，放进来才能保持 app 层的纯粹。
type SystemAPI struct {
	mu  sync.RWMutex
	app *application.App
	// platform 是运行平台标识（"desktop" / "android"），前端据此切换布局。
	platform string
	// safeArea 返回刘海屏/系统手势区尺寸，桌面端恒为空串。
	safeArea safeAreaFunc
	// setFullscreen / isFullscreen 是主窗口全屏能力，由 main 按平台注入。
	setFullscreen setFullscreenFunc
	isFullscreen  isFullscreenFunc
}

// NewSystemAPI 创建系统服务。使用前需调用 Attach 绑定应用实例。
func NewSystemAPI(
	platform string,
	safeArea safeAreaFunc,
	setFullscreen setFullscreenFunc,
	isFullscreen isFullscreenFunc,
) *SystemAPI {
	return &SystemAPI{
		platform:      platform,
		safeArea:      safeArea,
		setFullscreen: setFullscreen,
		isFullscreen:  isFullscreen,
	}
}

// Attach 绑定 Wails 应用实例。
func (a *SystemAPI) Attach(app *application.App) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.app = app
}

// Platform 返回运行平台标识："desktop" 或 "android"。
//
// 前端据此在桌面侧边栏布局与移动端底部 Tab 布局之间切换——
// 两套布局共用同一批视图组件，只有外壳与导航形态不同。
func (a *SystemAPI) Platform() string { return a.platform }

// SafeArea 返回安全区 JSON（上/下/左/右避让尺寸），用于刘海屏与系统手势条。
// 桌面端返回空串，前端按 0 处理。
func (a *SystemAPI) SafeArea() string {
	if a.safeArea == nil {
		return ""
	}
	return a.safeArea()
}

// SetFullscreen 切换主窗口全屏，返回操作后的实际状态。
//
// 返回实际值而不是回显入参：窗口可能因为平台限制或时序没切成，
// 前端拿真实状态回填，避免界面显示"已全屏"而窗口其实没有。
// 安卓端没有窗口层，注入的实现恒返回 false，前端会退回「只收起栏位」的沉浸。
func (a *SystemAPI) SetFullscreen(on bool) bool {
	if a.setFullscreen == nil {
		return false
	}
	return a.setFullscreen(on)
}

// IsFullscreen 查询主窗口当前是否全屏。
//
// 用户可以用系统快捷键退出全屏（Win+↓、mac 绿灯），那条路不经过前端按钮，
// 前端靠这个接口把状态捞回来。
func (a *SystemAPI) IsFullscreen() bool {
	if a.isFullscreen == nil {
		return false
	}
	return a.isFullscreen()
}

// OpenFiles 打开选择文件对话框，返回选中的文件路径列表。
//
// filters 为扩展名模式列表（如 []string{"*.epub", "*.txt"}），为空表示不限制。
func (a *SystemAPI) OpenFiles(title string, multi bool, filters []string) ([]string, error) {
	app := a.current()
	if app == nil {
		return nil, errBadRequest("应用尚未就绪")
	}

	dialog := app.Dialog.OpenFile().
		CanChooseFiles(true).
		SetTitle(title)
	for _, f := range filters {
		dialog.AddFilter(f, f)
	}

	if multi {
		paths, err := dialog.PromptForMultipleSelection()
		if err != nil {
			return nil, err
		}
		return paths, nil
	}
	p, err := dialog.PromptForSingleSelection()
	if err != nil {
		return nil, err
	}
	if p == "" {
		return nil, nil
	}
	return []string{p}, nil
}

// OpenDirectory 打开选择目录对话框，用于导入漫画图片目录。
func (a *SystemAPI) OpenDirectory(title string) (string, error) {
	app := a.current()
	if app == nil {
		return "", errBadRequest("应用尚未就绪")
	}
	return app.Dialog.OpenFile().
		CanChooseDirectories(true).
		CanChooseFiles(false).
		SetTitle(title).
		PromptForSingleSelection()
}

// SaveFile 打开保存文件对话框，返回目标路径；用户取消时返回空串。
func (a *SystemAPI) SaveFile(title string, defaultName string) (string, error) {
	app := a.current()
	if app == nil {
		return "", errBadRequest("应用尚未就绪")
	}
	// SaveFileDialogStruct 没有 SetTitle，标题用 SetMessage 呈现，
	// 默认文件名用 SetFilename。
	return app.Dialog.SaveFile().
		SetMessage(title).
		SetFilename(defaultName).
		PromptForSingleSelection()
}

// SaveTextFile 把文本内容写入指定路径。
//
// 前端（WebView）无法直接写磁盘，因此导入导出类操作需要经此接口落地。
func (a *SystemAPI) SaveTextFile(path string, content string) error {
	if path == "" {
		return errBadRequest("缺少目标路径")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return fmt.Errorf("写入文件失败: %w", err)
	}
	return nil
}

// current 读取当前应用实例。
func (a *SystemAPI) current() *application.App {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.app
}
