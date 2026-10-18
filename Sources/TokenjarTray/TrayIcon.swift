import TokenjarCore
import WinSDK

/// The tray icon: the fullest account's number in white on a square of its level's color.
enum TrayIcon {
    /// nil when GDI refuses; the tray then keeps its previous icon.
    static func make(text: String, level: TraySummary.Level) -> HICON? {
        let size = GetSystemMetrics(SM_CXSMICON)
        guard let screen = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, screen) }
        guard let dc = CreateCompatibleDC(screen) else { return nil }
        defer { DeleteDC(dc) }
        guard let color = CreateCompatibleBitmap(screen, size, size) else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(color)) }
        // GDI leaves the color bitmap's alpha at zero, so Windows reads opacity from this mask, all zero meaning opaque.
        // Its rows are padded to 16 bits.
        let maskBits = [UInt8](repeating: 0, count: Int((size + 15) / 16 * 2 * size))
        guard let mask = maskBits.withUnsafeBytes({ CreateBitmap(size, size, 1, 1, $0.baseAddress) }) else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(mask)) }

        let previousBitmap = SelectObject(dc, UnsafeMutableRawPointer(color))
        var square = RECT(left: 0, top: 0, right: size, bottom: size)
        if let brush = CreateSolidBrush(background(level)) {
            FillRect(dc, &square, brush)
            DeleteObject(UnsafeMutableRawPointer(brush))
        }
        let height = Int32(Double(size) * (text.count >= 3 ? 0.6 : 0.8))
        let font = "Segoe UI".withCString(encodedAs: UTF16.self) { face in
            CreateFontW(
                -height, 0, 0, 0, Int32(FW_BOLD), 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                DWORD(CLIP_DEFAULT_PRECIS), DWORD(ANTIALIASED_QUALITY), DWORD(DEFAULT_PITCH), face
            )
        }
        let previousFont = font.map { SelectObject(dc, UnsafeMutableRawPointer($0)) }
        SetBkMode(dc, Int32(TRANSPARENT))
        SetTextColor(dc, rgb(255, 255, 255))
        _ = text.withCString(encodedAs: UTF16.self) { DrawTextW(dc, $0, -1, &square, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE)) }
        if let font, let previousFont {
            SelectObject(dc, previousFont)
            DeleteObject(UnsafeMutableRawPointer(font))
        }
        SelectObject(dc, previousBitmap)

        // CreateIconIndirect copies both bitmaps, so the deferred deletes are safe.
        var info = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        return CreateIconIndirect(&info)
    }

    /// Windows' default accent blue for ok, as the Mac menu bar uses the accent color.
    private static func background(_ level: TraySummary.Level) -> COLORREF {
        switch level {
        case .none: rgb(0x60, 0x60, 0x60)
        case .ok: rgb(0x00, 0x67, 0xC0)
        case .warning: rgb(0xC2, 0x5E, 0x00)
        case .critical: rgb(0xC4, 0x2B, 0x1C)
        }
    }

    /// The RGB macro, which Swift does not import.
    private static func rgb(_ red: UInt32, _ green: UInt32, _ blue: UInt32) -> COLORREF {
        red | green << 8 | blue << 16
    }
}
