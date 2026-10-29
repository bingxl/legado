package api

import (
	"fmt"

	"github.com/legado/desktop/internal/domain"
)

// errBadRequest 构造参数错误。
//
// 绑定层统一用它做入参校验，使前端收到语义一致的错误：
// 携带 domain.ErrInvalidArgument 标记，便于前端区分「用户输入问题」与「系统故障」。
func errBadRequest(msg string) error {
	return fmt.Errorf("%w: %s", domain.ErrInvalidArgument, msg)
}
