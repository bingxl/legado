package kernel

// Binding 把一个服务对象挂到某个方法域。
type Binding struct {
	// Domain 是方法名前缀，例如 "Source" → "Source.List"。
	Domain string
	// Service 是实现了业务方法的对象（通常来自 core/app）。
	Service any
}

// serviceModule 是用反射批量注册服务的最小模块实现。
//
// 迁移期用它把已有的 app 层服务直接暴露给三宿主：
// 业务代码一行不改，宿主侧立刻获得全部方法；等模块内聚度提高后，
// 再按需把服务拆进各自模块目录并换成手写 handler（Architecture §9 M3）。
type serviceModule struct {
	name    string
	depends []string
	binds   []Binding
}

// NewServiceModule 构造一个「把现有服务暴露为方法」的模块。
func NewServiceModule(name string, depends []string, binds ...Binding) Module {
	return &serviceModule{name: name, depends: depends, binds: binds}
}

func (m *serviceModule) Name() string      { return m.name }
func (m *serviceModule) DependsOn() []string { return m.depends }

func (m *serviceModule) Register(r *Registry) {
	for _, b := range m.binds {
		RegisterService(r, b.Domain, b.Service)
	}
}
