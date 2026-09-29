import SwiftUI

enum PocketToolTheme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.025)

    // The host owns the baseline; generated layouts use the same compact panel controls.
    static func stylesheet(fontSize: CGFloat) -> String {
        """
        :root{color-scheme:dark!important;font:\(fontSize)px -apple-system,BlinkMacSystemFont,sans-serif!important;
        --pocket-background:#050506;--pocket-surface:#171719;--pocket-text:#eeeeef;--pocket-muted:#a2a2aa;
        --pocket-border:#343438;--pocket-accent:#fac240;--pocket-radius:8px;--pocket-gap:8px}
        *{box-sizing:border-box}html,body{margin:0!important;min-width:0!important;width:100%!important;
        background:var(--pocket-background)!important;color:var(--pocket-text)!important;
        font:inherit!important;line-height:1.45!important;overflow-wrap:anywhere}
        body{padding:12px!important}main{max-width:100%!important;margin:0!important;padding:0!important}
        h1{font-size:1.1rem!important;line-height:1.35;margin:0 0 8px!important}
        h2,h3{font-size:1rem!important;line-height:1.35;margin:0 0 6px!important}
        p{margin:6px 0}button,input,select,textarea{font:inherit!important;max-width:100%;min-width:0;
        border:1px solid var(--pocket-border)!important;border-radius:6px!important;
        background:var(--pocket-surface)!important;color:var(--pocket-text)!important;padding:5px 9px!important}
        button,input,select{min-height:28px}button{cursor:pointer}button:disabled{opacity:.45;cursor:default}
        button.primary,button[type=submit]{background:var(--pocket-accent)!important;color:#211b0a!important;border-color:transparent!important;font-weight:600!important}
        button.danger{color:#ff9696!important}input::placeholder,textarea::placeholder{color:#8e8e98;opacity:1}
        :focus-visible{outline:2px solid var(--pocket-accent)!important;outline-offset:2px}
        form,.card,article{background:var(--pocket-surface)!important;border:1px solid var(--pocket-border)!important;
        border-radius:var(--pocket-radius)!important;padding:10px!important;margin:8px 0!important}
        label{display:block;margin-bottom:8px}label input:not([type=checkbox]),label select,label textarea{display:block;width:100%;margin-top:4px}
        .muted,small{color:var(--pocket-muted)!important}.toolbar,.actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
        .toolbar{justify-content:space-between;margin-bottom:8px}.records{display:grid;gap:8px}
        .records>article{margin:0!important}.error,[role=alert]{color:#ff9696!important}
        [hidden]{display:none!important}img,canvas{max-width:100%}textarea{resize:vertical}
        @media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
        """
    }
}
