package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// CacheManager 对齐 legado help/CacheManager：内存缓存 + 可选落盘，支持 TTL
type CacheManager struct {
	mu    sync.RWMutex
	data  map[string]cacheItem
	file  string
	dirty bool
}

type cacheItem struct {
	Value     string `json:"value"`
	Deadline  int64  `json:"deadline"` // unix 秒，0 表示永不过期
	CreatedAt int64  `json:"createdAt"`
}

var defaultCache = NewCacheManager()

// DefaultCache 全局缓存
func DefaultCache() *CacheManager { return defaultCache }

func NewCacheManager() *CacheManager {
	return &CacheManager{data: map[string]cacheItem{}}
}

// SetFile 指定落盘文件
func (c *CacheManager) SetFile(path string) {
	c.mu.Lock()
	c.file = path
	c.mu.Unlock()
	_ = c.Load()
}

// Get 取值，过期返回空
func (c *CacheManager) Get(key string) string {
	c.mu.RLock()
	it, ok := c.data[key]
	c.mu.RUnlock()
	if !ok {
		return ""
	}
	if it.Deadline > 0 && time.Now().Unix() > it.Deadline {
		c.Delete(key)
		return ""
	}
	return it.Value
}

// Put 存值，saveTime<=0 表示不过期
func (c *CacheManager) Put(key, value string, saveTime int64) {
	c.mu.Lock()
	var dl int64
	if saveTime > 0 {
		dl = time.Now().Unix() + saveTime
	}
	c.data[key] = cacheItem{Value: value, Deadline: dl, CreatedAt: time.Now().Unix()}
	c.dirty = true
	c.mu.Unlock()
}

// Delete 删除
func (c *CacheManager) Delete(key string) {
	c.mu.Lock()
	delete(c.data, key)
	c.dirty = true
	c.mu.Unlock()
}

func (c *CacheManager) Clear() {
	c.mu.Lock()
	c.data = map[string]cacheItem{}
	c.dirty = true
	c.mu.Unlock()
}

func (c *CacheManager) Save() error {
	c.mu.RLock()
	if !c.dirty || c.file == "" {
		c.mu.RUnlock()
		return nil
	}
	cp := make(map[string]cacheItem, len(c.data))
	for k, v := range c.data {
		cp[k] = v
	}
	path := c.file
	c.mu.RUnlock()
	return writeJSONFile(path, cp)
}

func (c *CacheManager) Load() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.file == "" {
		return nil
	}
	b, err := os.ReadFile(c.file)
	if err != nil {
		return err
	}
	m := map[string]cacheItem{}
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	if c.data == nil {
		c.data = map[string]cacheItem{}
	}
	now := time.Now().Unix()
	for k, v := range m {
		if v.Deadline > 0 && now > v.Deadline {
			continue
		}
		c.data[k] = v
	}
	return nil
}

// —— 文件读写辅助 ——

func writeJSONFile(path string, v any) error {
	if path == "" {
		return nil
	}
	if dir := filepath.Dir(path); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

func readJSONFile(path string, out any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, out)
}
