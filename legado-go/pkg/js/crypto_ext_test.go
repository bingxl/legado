package js

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"testing"
)

// 漫蛙漫画这类漫画源把章节图片清单整段加密后藏在页面里：
//
//	params = '<base64( iv[16] + AES-CBC( json ) )>'
//
// 解它需要 java.base64DecodeToByteArray、java.hexDecodeToByteArray、
// Packages.java.util.Arrays.copyOfRange、java.createSymmetricCrypto、
// java.bytesToStr —— 少任何一个都会抛
// "TypeError: Object has no member 'base64DecodeToByteArray'"。
func TestComicContentDecryptChain(t *testing.T) {
	const keyHex = "355626526f52254a6640704a50796446"
	key, _ := hex.DecodeString(keyHex)
	iv := []byte("0123456789abcdef")
	plain := `{"images_domain":"https://cdn.example.com/","chapter_images":["a/1.jpg","b/2.jpg"]}`

	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatalf("构造 AES 失败: %v", err)
	}
	// PKCS7 补码
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	body := append([]byte(plain), bytes.Repeat([]byte{byte(pad)}, pad)...)
	ct := make([]byte, len(body))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(ct, body)

	payload := base64.StdEncoding.EncodeToString(append(append([]byte{}, iv...), ct...))
	page := `<html><body><script>var params = '` + payload + `';</script></body></html>`

	// 与书源里的规则保持一致（去掉调试日志）。
	rule := `(function () {
	var m = result.match(/params\s*=\s*'([^']+)'/);
	if (!m) return '<div class="error">未找到 params</div>';
	var buf = java.base64DecodeToByteArray(m[1]);
	var Arrays = Packages.java.util.Arrays;
	var iv = Arrays.copyOfRange(buf, 0, 16);
	var ct = Arrays.copyOfRange(buf, 16, buf.length);
	var key = java.hexDecodeToByteArray('` + keyHex + `');
	var c = java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv);
	var plainBytes = c.decrypt(ct);
	var jsonStr = java.bytesToStr(plainBytes, 'UTF-8');
	var d = JSON.parse(jsonStr);
	var host = (d.images_domain || '').replace(/\/+$/, '');
	var imgs = d.chapter_images || [];
	var out = '';
	for (var i = 0; i < imgs.length; i++) {
	  var t = imgs[i];
	  if (/^(https?:|\/\/)/i.test(t)) { out += '<img src="' + t + '">'; }
	  else { out += '<img src="' + host + '/' + t.replace(/^\/+/, '') + '">'; }
	}
	return out;
})();`

	out, err := DefaultEngine().Eval(rule, &Bindings{Result: page})
	if err != nil {
		t.Fatalf("执行规则失败: %v", err)
	}
	got := valStr(out)
	want := `<img src="https://cdn.example.com/a/1.jpg"><img src="https://cdn.example.com/b/2.jpg">`
	if got != want {
		t.Fatalf("解密结果不符\n实际: %s\n期望: %s", got, want)
	}
}

// 字节数组要能当 Java byte[] 用：有 length，也能按下标取。
func TestByteArrayIsIndexable(t *testing.T) {
	cases := []struct{ js, want string }{
		{`java.base64DecodeToByteArray('5L2g5aW9').length`, "6"},
		{`java.bytesToStr(java.base64DecodeToByteArray('5L2g5aW9'))`, "你好"},
		{`java.hexDecodeToByteArray('e4bda0').length`, "3"},
		{`java.bytesToStr(java.hexDecodeToByteArray('e4bda0'))`, "你"},
		{`java.strToBytes('AB').length`, "2"},
		{`java.strToBytes('AB')[1]`, "66"},
		// GBK 解码：0xC4 0xE3 = 「你」
		{`java.bytesToStr(java.hexDecodeToByteArray('c4e3'), 'GBK')`, "你"},
		// JS 字符串字面量里的转义由引擎自己处理（这里确认没被我们的还原逻辑破坏）。
		{`java.base64DecodeToByteArray('+\/8=').length`, "2"},
		{`java.base64DecodeToByteArray('\u002b\/8=').length`, "2"},
		// 空入参返回 null（对齐原版）
		{`java.base64DecodeToByteArray('')`, ""},
		// Arrays.copyOfRange 越界补 0
		{`Packages.java.util.Arrays.copyOfRange(java.strToBytes('AB'), 0, 4).length`, "4"},
		{`java.util.Arrays.copyOf(java.strToBytes('AB'), 3).length`, "3"},
	}
	for _, c := range cases {
		v, err := DefaultEngine().Eval(c.js, &Bindings{})
		if err != nil {
			t.Fatalf("%s 执行失败: %v", c.js, err)
		}
		if got := valStr(v); got != c.want {
			t.Errorf("%s = %q，期望 %q", c.js, got, c.want)
		}
	}
}

// ECB 模式与加解密往返：不少源用 AES/ECB/PKCS5Padding 加密搜索参数。
func TestSymmetricCryptoECBRoundTrip(t *testing.T) {
	js := `(function () {
	var key = java.strToBytes('1234567890abcdef');
	var c = java.createSymmetricCrypto('AES/ECB/PKCS5Padding', key);
	var enc = c.encryptBase64('中文abc');
	var back = java.createSymmetricCrypto('AES/ECB/PKCS5Padding', key).decryptStr(enc, 'UTF-8');
	return back + '|' + (enc.length > 0);
})();`
	v, err := DefaultEngine().Eval(js, &Bindings{})
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if got := valStr(v); got != "中文abc|true" {
		t.Fatalf("ECB 往返结果异常: %q", got)
	}
}

// 密钥长度不合法要抛可捕获的 JS 异常，而不是让进程崩掉。
// 消息文案由 crypto/aes 决定（"invalid key size"），这里只断言「能被 catch 住且有内容」。
func TestSymmetricCryptoInvalidKey(t *testing.T) {
	js := `(function () {
	try {
	  java.createSymmetricCrypto('AES/CBC/PKCS5Padding', java.strToBytes('short'), java.strToBytes('0123456789abcdef'));
	  return 'no-error';
	} catch (e) {
	  return 'caught:' + (String(e).length > 0);
	}
})();`
	v, err := DefaultEngine().Eval(js, &Bindings{})
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	if got := valStr(v); got != "caught:true" {
		t.Fatalf("非法密钥应抛出可捕获异常，实际: %q", got)
	}
}
