package download

import (
	"reflect"
	"testing"
)

func TestExtractImages(t *testing.T) {
	in := `<img src="https://a.com/1.jpg">
　　<img src="https://a.com/2.webp">
https://a.com/3.png
<img data-src="https://a.com/4.jpg">
<img src="https://a.com/5.jpg,{'headers':{'Referer':'x'}}">
<img src="/rel/6.jpg">
<img src="https://a.com/1.jpg">
　　`
	got := ExtractImages(in)
	want := []string{
		"https://a.com/1.jpg",
		"https://a.com/2.webp",
		"https://a.com/3.png",
		"https://a.com/4.jpg",
		"https://a.com/5.jpg",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ExtractImages 结果不符\n got=%#v\nwant=%#v", got, want)
	}
}

func TestExtractImagesEmpty(t *testing.T) {
	if got := ExtractImages("普通文本\n没有图片"); len(got) != 0 {
		t.Fatalf("不应有水印: %#v", got)
	}
}
