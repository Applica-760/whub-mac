import WebKit

@MainActor
enum BrowserKeyboardNavigation {
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener('keydown', event => {
                if (event.key !== 'j' && event.key !== 'k') return;
                if (event.isComposing || event.keyCode === 229 ||
                    event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
                const path = event.composedPath();
                if (path.some(element => element instanceof HTMLElement &&
                    (element.isContentEditable || element.matches('input, textarea, select, [role="textbox"]')))) return;
                const target = path.find(element => element instanceof HTMLElement &&
                    element.scrollHeight > element.clientHeight &&
                    /^(auto|scroll|overlay)$/.test(getComputedStyle(element).overflowY)) || document.scrollingElement;
                if (!target) return;
                event.preventDefault();
                event.stopImmediatePropagation();
                target.scrollBy({ top: event.key === 'j' ? 120 : -120, behavior: 'instant' });
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
}
