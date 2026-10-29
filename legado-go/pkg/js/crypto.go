package js

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/des"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/dop251/goja"
	"github.com/legado/legado-go/pkg/util"
)

// —— 对称加解密（java.createSymmetricCrypto） ——
//
// 原版 legado 直接暴露 Hutool 的 SymmetricCrypto：
//
//	java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv).decrypt(bytes)
//	java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv).decryptStr(bytes, 'UTF-8')
//	java.createSymmetricCrypto('AES/ECB/PKCS5Padding', key).encryptBase64('明文')
//
// 部分漫画源把整个章节图片清单用 AES 加密后放在页面里，没有这套 API 就取不到正文。
// 这里按 Java 的 transformation 语法（算法/模式/补码）做一个最小子集。

// symmetricCrypto 复刻 Hutool SymmetricCrypto 的常用方法。
type symmetricCrypto struct {
	transformation string
	alg            string // AES / DES / DESEDE
	mode           string // ECB / CBC / CTR / CFB / OFB / GCM
	padding        string // PKCS7PADDING / NOPADDING / ZEROPADDING
	key            []byte
	iv             []byte
}

// newSymmetricCrypto 解析 transformation 并校验密钥。
func newSymmetricCrypto(transformation string, key, iv []byte) (*symmetricCrypto, error) {
	t := strings.TrimSpace(transformation)
	if t == "" {
		t = "AES"
	}
	if len(key) == 0 {
		return nil, fmt.Errorf("密钥不能为空")
	}

	parts := strings.Split(t, "/")
	c := &symmetricCrypto{
		transformation: t,
		alg:            strings.ToUpper(strings.TrimSpace(parts[0])),
		mode:           "ECB", // Java 对 "AES" 的默认模式
		padding:        "PKCS7PADDING",
		key:            key,
		iv:             iv,
	}
	if len(parts) > 1 {
		c.mode = strings.ToUpper(strings.TrimSpace(parts[1]))
	}
	if len(parts) > 2 {
		switch p := strings.ToUpper(strings.TrimSpace(parts[2])); p {
		case "PKCS5PADDING", "PKCS7PADDING", "PKCS5", "PKCS7":
			c.padding = "PKCS7PADDING"
		case "NOPADDING", "NONE":
			c.padding = "NOPADDING"
		case "ZEROPADDING":
			c.padding = "ZEROPADDING"
		default:
			return nil, fmt.Errorf("不支持的补码方式: %s", parts[2])
		}
	}
	// 提前建一次 cipher，密钥长度不对时立刻报错（和 Java 的 InvalidKeyException 对应）。
	if _, err := c.block(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *symmetricCrypto) block() (cipher.Block, error) {
	switch c.alg {
	case "AES":
		return aes.NewCipher(c.key)
	case "DES":
		return des.NewCipher(c.key)
	case "DESEDE", "TRIPLEDES", "3DES":
		return des.NewTripleDESCipher(c.key)
	}
	return nil, fmt.Errorf("不支持的算法: %s", c.alg)
}

// decrypt 对齐 Hutool SymmetricCrypto.decrypt(byte[])：输入是密文原始字节。
func (c *symmetricCrypto) decrypt(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, nil
	}
	block, err := c.block()
	if err != nil {
		return nil, err
	}
	bs := block.BlockSize()

	if c.mode == "GCM" {
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		nonce := c.iv
		if len(nonce) == 0 {
			nonce = data[:gcm.NonceSize()]
			data = data[gcm.NonceSize():]
		}
		return gcm.Open(nil, nonce, data, nil)
	}
	if c.mode != "ECB" && len(c.iv) != bs {
		return nil, fmt.Errorf("%s 模式需要 %d 字节的 IV，实际 %d", c.mode, bs, len(c.iv))
	}

	var out []byte
	switch c.mode {
	case "ECB":
		out, err = c.ecb(block, data, true)
	case "CBC":
		if len(data)%bs != 0 {
			return nil, fmt.Errorf("密文长度 %d 不是分组长度 %d 的整数倍", len(data), bs)
		}
		out = make([]byte, len(data))
		cipher.NewCBCDecrypter(block, c.iv).CryptBlocks(out, data)
	case "CTR":
		out = make([]byte, len(data))
		cipher.NewCTR(block, c.iv).XORKeyStream(out, data)
	case "CFB":
		out = make([]byte, len(data))
		cipher.NewCFBDecrypter(block, c.iv).XORKeyStream(out, data)
	case "OFB":
		out = make([]byte, len(data))
		cipher.NewOFB(block, c.iv).XORKeyStream(out, data)
	default:
		return nil, fmt.Errorf("不支持的工作模式: %s", c.mode)
	}
	if err != nil {
		return nil, err
	}
	return c.unpad(out, bs), nil
}

// encrypt 对齐 Hutool SymmetricCrypto.encrypt(byte[])。
func (c *symmetricCrypto) encrypt(data []byte) ([]byte, error) {
	block, err := c.block()
	if err != nil {
		return nil, err
	}
	bs := block.BlockSize()

	if c.mode == "GCM" {
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		nonce := c.iv
		if len(nonce) == 0 {
			nonce = make([]byte, gcm.NonceSize())
		}
		return gcm.Seal(nil, nonce, data, nil), nil
	}
	if c.mode != "ECB" && len(c.iv) != bs {
		return nil, fmt.Errorf("%s 模式需要 %d 字节的 IV，实际 %d", c.mode, bs, len(c.iv))
	}
	if c.mode == "ECB" || c.mode == "CBC" {
		data = c.pad(data, bs)
	}

	switch c.mode {
	case "ECB":
		return c.ecb(block, data, false)
	case "CBC":
		out := make([]byte, len(data))
		cipher.NewCBCEncrypter(block, c.iv).CryptBlocks(out, data)
		return out, nil
	case "CTR":
		out := make([]byte, len(data))
		cipher.NewCTR(block, c.iv).XORKeyStream(out, data)
		return out, nil
	case "CFB":
		out := make([]byte, len(data))
		cipher.NewCFBEncrypter(block, c.iv).XORKeyStream(out, data)
		return out, nil
	case "OFB":
		out := make([]byte, len(data))
		cipher.NewOFB(block, c.iv).XORKeyStream(out, data)
		return out, nil
	}
	return nil, fmt.Errorf("不支持的工作模式: %s", c.mode)
}

// ecb 手写 ECB：Go 标准库不提供，因为它在多数场景下不安全；
// 但书源规则里 ECB 很常见，只能自己拼。
func (c *symmetricCrypto) ecb(block cipher.Block, src []byte, decrypt bool) ([]byte, error) {
	bs := block.BlockSize()
	if len(src)%bs != 0 {
		return nil, fmt.Errorf("数据长度 %d 不是分组长度 %d 的整数倍", len(src), bs)
	}
	dst := make([]byte, len(src))
	for i := 0; i < len(src); i += bs {
		if decrypt {
			block.Decrypt(dst[i:i+bs], src[i:i+bs])
		} else {
			block.Encrypt(dst[i:i+bs], src[i:i+bs])
		}
	}
	return dst, nil
}

func (c *symmetricCrypto) pad(src []byte, bs int) []byte {
	switch c.padding {
	case "NOPADDING":
		return src
	case "ZEROPADDING":
		if n := len(src) % bs; n != 0 {
			return append(src, make([]byte, bs-n)...)
		}
		return src
	}
	n := bs - len(src)%bs
	return append(src, bytes.Repeat([]byte{byte(n)}, n)...)
}

// unpad 去补码。
//
// 比 JVM 宽松：补码不合法时原样返回而不是抛异常。
// 一些站点用 ZeroPadding 却声明成 PKCS5Padding，严格校验会让整章正文变成错误页；
// 宁可交给上层按 UTF-8 尽力解码，也好过直接失败。
func (c *symmetricCrypto) unpad(src []byte, bs int) []byte {
	switch c.padding {
	case "NOPADDING":
		return src
	case "ZEROPADDING":
		return bytes.TrimRight(src, "\x00")
	}
	if len(src) == 0 {
		return src
	}
	n := int(src[len(src)-1])
	if n == 0 || n > bs || n > len(src) {
		return src
	}
	for _, b := range src[len(src)-n:] {
		if int(b) != n {
			return src
		}
	}
	return src[:len(src)-n]
}

// toJSObject 把实例包装成 JS 对象，方法名与 Hutool 保持一致。
func (c *symmetricCrypto) toJSObject(vm *goja.Runtime) *goja.Object {
	o := vm.NewObject()
	fail := func(err error) { panic(vm.NewGoError(err)) }

	o.Set("decrypt", func(call goja.FunctionCall) goja.Value {
		out, err := c.decrypt(cryptoInput(call.Argument(0)))
		if err != nil {
			fail(err)
		}
		return toJSBytes(vm, out)
	})
	o.Set("decryptStr", func(call goja.FunctionCall) goja.Value {
		out, err := c.decrypt(cryptoInput(call.Argument(0)))
		if err != nil {
			fail(err)
		}
		charset := "UTF-8"
		if s := strings.TrimSpace(fmt.Sprint(exportValue(call.Argument(1)))); len(call.Arguments) > 1 && s != "" {
			charset = s
		}
		return vm.ToValue(util.DecodeBytes(out, charset))
	})
	o.Set("encrypt", func(call goja.FunctionCall) goja.Value {
		out, err := c.encrypt(cryptoInput(call.Argument(0)))
		if err != nil {
			fail(err)
		}
		return toJSBytes(vm, out)
	})
	o.Set("encryptBase64", func(call goja.FunctionCall) goja.Value {
		out, err := c.encrypt(cryptoInput(call.Argument(0)))
		if err != nil {
			fail(err)
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(out))
	})
	o.Set("encryptHex", func(call goja.FunctionCall) goja.Value {
		out, err := c.encrypt(cryptoInput(call.Argument(0)))
		if err != nil {
			fail(err)
		}
		return vm.ToValue(hex.EncodeToString(out))
	})
	return o
}

// cryptoBytes 把 key/iv 入参转成字节。
//
// 与 cryptoInput 的区别：key/iv 传字符串时按 UTF-8 原文取字节（Java 的
// `createSymmetricCrypto(transformation, key: String)` 就是 str.toByteArray()），
// 绝不做 hex/base64 自动解码——否则密钥会被悄悄改掉，解出来是乱码。
func cryptoBytes(v goja.Value) []byte {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil
	}
	if s, ok := v.Export().(string); ok {
		return []byte(s)
	}
	return toBytes(v)
}

// cryptoInput 解释加解密入参。
//
// Hutool 的 decrypt(String) 会自动判断入参是 hex 还是 base64 后再解码，
// decrypt(byte[]) 则按原始密文处理。这里按同样的规则区分：
// 字符串 → 先试 hex、再试 base64；其它（数字数组 / ArrayBuffer）→ 原始字节。
func cryptoInput(v goja.Value) []byte {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil
	}
	s, ok := v.Export().(string)
	if !ok {
		return toBytes(v)
	}
	trimmed := strings.TrimSpace(util.UnescapeJSString(s))
	if trimmed == "" {
		return nil
	}
	if len(trimmed)%2 == 0 && isHexString(trimmed) {
		if b, err := hex.DecodeString(trimmed); err == nil {
			return b
		}
	}
	if b, err := base64.StdEncoding.DecodeString(trimmed); err == nil {
		return b
	}
	return []byte(trimmed)
}

func isHexString(s string) bool {
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		case r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}
