import Foundation

/// Web Element Matcher — fuzzy element matching via JS injection
///
/// Issue #26: Fuzzy Element Matching on Web Pages
/// - Enumerates all interactive elements (buttons, links, inputs, selects, textareas)
/// - Assigns refs (w1, w2, w3...) to each
/// - Fuzzy match by text, aria-label, placeholder, name, id
/// - Click and fill via injected JS
/// - Works even when screen is locked (all via do JavaScript)
public struct WebElementMatcher {

    /// JS script that enumerates all interactive elements and returns JSON
    public static let enumerationScript: String = """
    (function() {
        var els = document.querySelectorAll('a, button, input, select, textarea, [role="button"], [role="link"], [role="tab"], [onclick], [tabindex]');
        var results = [];
        var refIdx = 0;
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            if (el.offsetParent === null && el.tagName !== 'BODY') continue;
            refIdx++;
            var ref = 'w' + refIdx;
            el.setAttribute('data-agentview-ref', ref);
            var text = (el.innerText || '').trim().substring(0, 100);
            var ariaLabel = el.getAttribute('aria-label') || '';
            var placeholder = el.getAttribute('placeholder') || '';
            var name = el.getAttribute('name') || '';
            var id = el.id || '';
            var type = el.getAttribute('type') || '';
            var tag = el.tagName.toLowerCase();
            var role = el.getAttribute('role') || tag;
            var value = '';
            if (tag === 'input' || tag === 'textarea' || tag === 'select') {
                value = (el.value || '').substring(0, 100);
            }
            results.push({
                ref: ref,
                tag: tag,
                role: role,
                text: text,
                aria_label: ariaLabel,
                placeholder: placeholder,
                name: name,
                id: id,
                type: type,
                value: value,
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                width: Math.round(rect.width),
                height: Math.round(rect.height)
            });
        }
        return JSON.stringify({elements: results, count: results.length});
    })()
    """

    /// JS script that fuzzy-matches and clicks an element
    public static func clickScript(match: String) -> String {
        return """
        (function() {
            var match = '\(match)'.toLowerCase();
            var els = document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [role="link"], [role="tab"], [onclick], [tabindex]');
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var rect = el.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) continue;
                var score = 0;
                var text = (el.innerText || '').toLowerCase().trim();
                var ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
                var placeholder = (el.getAttribute('placeholder') || '').toLowerCase();
                var name = (el.getAttribute('name') || '').toLowerCase();
                var id = (el.id || '').toLowerCase();
                var title = (el.getAttribute('title') || '').toLowerCase();
                if (text === match) score += 100;
                else if (text.indexOf(match) !== -1) score += 80;
                else if (match.indexOf(text) !== -1 && text.length > 0) score += 40;
                if (ariaLabel === match) score += 100;
                else if (ariaLabel.indexOf(match) !== -1) score += 70;
                if (placeholder.indexOf(match) !== -1) score += 60;
                if (name.indexOf(match) !== -1) score += 50;
                if (id.indexOf(match) !== -1) score += 40;
                if (title.indexOf(match) !== -1) score += 50;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (best && bestScore > 0) {
                best.click();
                var bestText = (best.innerText || best.getAttribute('aria-label') || best.id || best.tagName).substring(0, 80);
                return JSON.stringify({success: true, action: 'click', matched: bestText, score: bestScore});
            }
            return JSON.stringify({success: false, error: 'No element matching: ' + match});
        })()
        """
    }

    /// JS script that fuzzy-matches and fills a form field
    public static func fillScript(match: String, value: String) -> String {
        return """
        (function() {
            var match = '\(match)'.toLowerCase();
            var fillValue = '\(value)';
            var els = document.querySelectorAll('input, textarea, select, [contenteditable="true"]');
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var rect = el.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) continue;
                var score = 0;
                var placeholder = (el.getAttribute('placeholder') || '').toLowerCase();
                var name = (el.getAttribute('name') || '').toLowerCase();
                var id = (el.id || '').toLowerCase();
                var ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
                var type = (el.getAttribute('type') || '').toLowerCase();
                var labelText = '';
                if (el.id) {
                    var lbl = document.querySelector('label[for="' + el.id + '"]');
                    if (lbl) labelText = (lbl.innerText || '').toLowerCase().trim();
                }
                if (!labelText) {
                    var parent = el.closest('label');
                    if (parent) labelText = (parent.innerText || '').toLowerCase().trim();
                }
                if (labelText === match) score += 100;
                else if (labelText.indexOf(match) !== -1) score += 80;
                if (placeholder === match) score += 100;
                else if (placeholder.indexOf(match) !== -1) score += 70;
                if (ariaLabel === match) score += 100;
                else if (ariaLabel.indexOf(match) !== -1) score += 70;
                if (name === match) score += 90;
                else if (name.indexOf(match) !== -1) score += 60;
                if (id === match) score += 80;
                else if (id.indexOf(match) !== -1) score += 50;
                if (type === match) score += 30;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (best && bestScore > 0) {
                best.focus();
                if (best.tagName.toLowerCase() === 'select') {
                    for (var j = 0; j < best.options.length; j++) {
                        if (best.options[j].text.toLowerCase().indexOf(fillValue.toLowerCase()) !== -1 ||
                            best.options[j].value.toLowerCase().indexOf(fillValue.toLowerCase()) !== -1) {
                            best.selectedIndex = j;
                            break;
                        }
                    }
                } else if (best.getAttribute('contenteditable') === 'true') {
                    best.innerText = fillValue;
                } else {
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value') ||
                                       Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
                    if (nativeSetter && nativeSetter.set) {
                        nativeSetter.set.call(best, fillValue);
                    } else {
                        best.value = fillValue;
                    }
                }
                best.dispatchEvent(new Event('input', {bubbles: true}));
                best.dispatchEvent(new Event('change', {bubbles: true}));
                var matchedName = best.getAttribute('name') || best.getAttribute('placeholder') || best.id || best.tagName;
                return JSON.stringify({success: true, action: 'fill', matched: matchedName, score: bestScore, value: fillValue});
            }
            return JSON.stringify({success: false, error: 'No input matching: ' + match});
        })()
        """
    }

    // MARK: - Pure Swift fuzzy matching (for non-JS contexts)

    /// Calculate fuzzy match score between a query and element properties
    public static func fuzzyScore(query: String, text: String?, ariaLabel: String?,
                                  placeholder: String?, name: String?, id: String?) -> Int {
        let q = query.lowercased()
        var score = 0

        if let text = text?.lowercased(), !text.isEmpty {
            if text == q { score += 100 }
            else if text.contains(q) { score += 80 }
            else if q.contains(text) { score += 40 }
        }

        if let ariaLabel = ariaLabel?.lowercased(), !ariaLabel.isEmpty {
            if ariaLabel == q { score += 100 }
            else if ariaLabel.contains(q) { score += 70 }
        }

        if let placeholder = placeholder?.lowercased(), !placeholder.isEmpty {
            if placeholder.contains(q) { score += 60 }
        }

        if let name = name?.lowercased(), !name.isEmpty {
            if name == q { score += 90 }
            else if name.contains(q) { score += 50 }
        }

        if let id = id?.lowercased(), !id.isEmpty {
            if id == q { score += 80 }
            else if id.contains(q) { score += 40 }
        }

        return score
    }
}
