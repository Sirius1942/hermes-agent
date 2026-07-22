import Foundation

enum BrightTheme {
    static let styleIdentifier = "hermes-macos-bright-theme"

    static let css = """
    :root {
      color-scheme: light !important;
      --background: #fff8ec !important;
      --background-base: #fff8ec !important;
      --background-alpha: 1 !important;
      --midground: #17324d !important;
      --midground-base: #17324d !important;
      --midground-alpha: 1 !important;
      --foreground: transparent !important;
      --foreground-base: #17324d !important;
      --foreground-alpha: 0 !important;
      --color-foreground: #17324d !important;
      --color-card: #ffffff !important;
      --color-card-foreground: #17324d !important;
      --color-popover: #ffffff !important;
      --color-popover-foreground: #17324d !important;
      --color-primary: #2f80ed !important;
      --color-primary-foreground: #ffffff !important;
      --color-secondary: #fff1e6 !important;
      --color-secondary-foreground: #17324d !important;
      --color-muted: #edf6fc !important;
      --color-muted-foreground: #557086 !important;
      --color-accent: #e3f2ff !important;
      --color-accent-foreground: #155bb5 !important;
      --color-destructive: #dc3545 !important;
      --color-destructive-foreground: #ffffff !important;
      --color-success: #1f9d67 !important;
      --color-warning: #d98b00 !important;
      --color-border: #cfe3f4 !important;
      --color-input: #b9d7ee !important;
      --color-ring: #2f80ed !important;
      --series-input-token: #8b5cf6 !important;
      --series-output-token: #2ccb8e !important;
      --theme-radius: 0.9rem !important;
      --radius: 0.9rem !important;
      --theme-spacing-mul: 1.06 !important;
      --theme-font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif !important;
      --theme-font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif !important;
    }
    html, body, #root { background: #fff8ec !important; color: #17324d !important; }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      pointer-events: none;
      z-index: -1;
      background:
        radial-gradient(circle at 12% 8%, rgba(47,128,237,.12), transparent 30%),
        radial-gradient(circle at 90% 12%, rgba(255,122,89,.12), transparent 28%),
        radial-gradient(circle at 82% 88%, rgba(44,203,142,.10), transparent 30%),
        #fff8ec;
    }
    aside, [aria-label="Navigation"] { background-color: #eff8ff !important; }
    button, [role="button"], input, select, textarea { border-radius: .72rem !important; }
    """

    static func javascript(enabled: Bool) -> String {
        if enabled {
            let encoded = css
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")
            return """
            (() => {
              let style = document.getElementById('\(styleIdentifier)');
              if (!style) {
                style = document.createElement('style');
                style.id = '\(styleIdentifier)';
                document.documentElement.appendChild(style);
              }
              style.textContent = `\(encoded)`;
              document.documentElement.dataset.hermesMacos = 'bright';
            })();
            """
        }
        return """
        (() => {
          document.getElementById('\(styleIdentifier)')?.remove();
          delete document.documentElement.dataset.hermesMacos;
        })();
        """
    }
}

