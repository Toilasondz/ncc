# VideoStarTool Pro (Version 3 - Ultimate Clean Build)

Bản cập nhật hoàn chỉnh 100% được tối ưu hóa cho Theos và GitHub Actions:
- **Tweak.x**: Chuyển sang đuôi `.x` để Logos và Clang biên dịch thuần Objective-C (`.m`), miễn nhiễm hoàn toàn với lỗi thiếu thư viện C++ (`<cmath>`).
- **Makefile**: Rút gọn Frameworks, chỉ liên kết `UIKit Foundation CoreGraphics CoreMedia`, khai báo file nguồn `Tweak.x`.
- **Workflow Actions**: Sử dụng `actions/checkout@v4`, `actions/upload-artifact@v4`, tự động dọn thư mục SDK và trích xuất cả `.deb` và `.dylib`.

## Cấu trúc thư mục:
```text
VideoStarTweakPro_v3/
├── Makefile
├── control
├── VideoStarTool.plist
├── Tweak.x
├── README.md
└── .github/
    └── workflows/
        └── build.yml
```
