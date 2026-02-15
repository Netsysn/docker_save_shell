package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/schollz/progressbar/v3"
)

func main() {
	filePath := flag.String("file", "", "要上传的文件路径 (必须)")
	serverURL := flag.String("url", "", "后端接收地址 (必须)")
	flag.Parse()

	if *filePath == "" || *serverURL == "" {
		fmt.Println("错误：缺少必要参数")
		flag.Usage()
		os.Exit(1)
	}

	file, err := os.Open(*filePath)
	if err != nil {
		fmt.Printf("无法打开文件: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		fmt.Printf("无法获取文件信息: %v\n", err)
		os.Exit(1)
	}

	fileSize := fileInfo.Size()
	fileName := filepath.Base(*filePath)

	fmt.Printf("📁 文件: %s\n", fileName)
	fmt.Printf("📊 大小: %s\n", formatBytes(fileSize))
	fmt.Printf("🎯 目标: %s\n", *serverURL)

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	// 创建multipart部分
	part, err := writer.CreateFormFile("file", fileName)
	if err != nil {
		fmt.Printf("创建表单字段失败: %v\n", err)
		os.Exit(1)
	}

	// ==================== 4. 创建进度条 ====================
	bar := progressbar.NewOptions64(
		fileSize,
		progressbar.OptionSetDescription(fmt.Sprintf("📤 上传 %s", fileName)),
		progressbar.OptionSetWriter(os.Stderr),
		progressbar.OptionShowBytes(true),
		progressbar.OptionSetWidth(30),
		progressbar.OptionThrottle(65*time.Millisecond),
		progressbar.OptionShowCount(),
		progressbar.OptionOnCompletion(func() {
			fmt.Fprint(os.Stderr, "\n")
		}),
		progressbar.OptionSpinnerType(14),
		progressbar.OptionSetRenderBlankState(true),
		progressbar.OptionSetTheme(progressbar.Theme{
			Saucer:        "=",
			SaucerHead:    ">",
			SaucerPadding: " ",
			BarStart:      "[",
			BarEnd:        "]",
		}),
	)

	// 使用带进度条的Reader包装文件
	teeReader := io.TeeReader(file, bar)

	// 复制文件内容到表单（通过进度条Reader）
	_, err = io.Copy(part, teeReader)
	if err != nil {
		fmt.Printf("读取文件失败: %v\n", err)
		os.Exit(1)
	}

	writer.Close()

	// ==================== 5. 发送请求（带上传进度） ====================
	fmt.Println("\n🚀 正在连接到服务器...")

	// 创建请求
	req, err := http.NewRequest("POST", *serverURL, body)
	if err != nil {
		fmt.Printf("创建请求失败: %v\n", err)
		os.Exit(1)
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	// 发送请求
	client := &http.Client{
		Timeout: 30 * time.Minute, // 大文件需要更长时间
	}

	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("发送请求失败: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	// ==================== 6. 读取响应（带下载进度） ====================
	fmt.Println("\n📥 正在接收服务器响应...")

	// 获取响应体大小（如果服务器提供了Content-Length）
	contentLength := resp.ContentLength

	var responseBody []byte
	if contentLength > 0 {
		// 如果知道响应体大小，显示进度条
		bar2 := progressbar.NewOptions64(
			contentLength,
			progressbar.OptionSetDescription("📥 下载响应"),
			progressbar.OptionSetWriter(os.Stderr),
			progressbar.OptionShowBytes(true),
			progressbar.OptionSetWidth(30),
		)

		// 使用带进度条的Reader读取响应
		respBodyReader := progressbar.NewReader(resp.Body, bar2)
		responseBody, err = io.ReadAll(&respBodyReader)
	} else {
		// 不知道大小，直接读取
		responseBody, err = io.ReadAll(resp.Body)
	}

	if err != nil {
		fmt.Printf("读取响应失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("\n 响应状态码: %d\n", resp.StatusCode)

	if resp.StatusCode == http.StatusOK {
		fmt.Println("上传成功!")
	} else {
		fmt.Printf("上传失败\n")
	}

	fmt.Printf("📝 服务器返回: %s\n", string(responseBody))
}

// ==================== 辅助函数 ====================

// 格式化字节大小为可读格式
func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// ProgressReader 用于跟踪进度的Reader
type ProgressReader struct {
	io.Reader
	Size       int64
	read       int64
	OnProgress func(progress float64)
}

func (pr *ProgressReader) Read(p []byte) (int, error) {
	n, err := pr.Reader.Read(p)
	pr.read += int64(n)

	if pr.OnProgress != nil && pr.Size > 0 {
		progress := float64(pr.read) / float64(pr.Size) * 100
		pr.OnProgress(progress)
	}

	return n, err
}
