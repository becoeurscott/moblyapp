# Fonts

The app currently uses system fonts as a stand-in:
- **Wordmark / headings** → `SF Rounded SemiBold` (close to Fredoka)
- **Body** → `SF Pro` (close to Inter)

To ship the exact brand look, drop TTF files into this folder and rebuild — the app auto-registers them at launch and `Font.moblyWordmark(...)` / `Font.moblyBody(...)` switch to them automatically.

Files to add (from Google Fonts):
```
Fredoka-Regular.ttf
Fredoka-Medium.ttf
Fredoka-SemiBold.ttf
Fredoka-Bold.ttf
Inter-Regular.ttf
Inter-Medium.ttf
Inter-SemiBold.ttf
```

Download:
- Fredoka → https://fonts.google.com/specimen/Fredoka
- Inter → https://fonts.google.com/specimen/Inter

No `UIAppFonts` plist entry needed — registration happens in `MoblyApp.init()` via `CTFontManagerRegisterFontsForURL`.
