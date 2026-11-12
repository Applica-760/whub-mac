import WebKit

@MainActor
enum BrowserKeyboardNavigation {
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener('keydown', event => {
                const key = event.key.toLowerCase();
                if (key !== 'j' && key !== 'k') return;
                if (event.isComposing || event.keyCode === 229 ||
                    event.metaKey || event.ctrlKey || event.altKey) return;
                const path = event.composedPath();
                if (path.some(element => element instanceof HTMLElement &&
                    (element.isContentEditable || element.matches('input, textarea, select, [role="textbox"]')))) return;
                const target = path.find(element => element instanceof HTMLElement &&
                    element.scrollHeight > element.clientHeight &&
                    /^(auto|scroll|overlay)$/.test(getComputedStyle(element).overflowY)) || document.scrollingElement;
                if (!target) return;
                event.preventDefault();
                event.stopImmediatePropagation();
                const distance = event.shiftKey ? 360 : 120;
                target.scrollBy({ top: key === 'j' ? distance : -distance, behavior: 'instant' });
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
}
