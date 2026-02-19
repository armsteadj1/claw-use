import Foundation

/// Provides JavaScript snippets for semantic page analysis and content extraction.
public enum PageAnalyzer {

    // MARK: - Analysis Script

    /// Injected JS that detects page type and returns structured JSON.
    /// Returns: { pageType, title, url, meta, forms, links, headings, mainContent, tables }
    public static let analysisScript: String = #"""
    (function() {
        try {
        var result = {};
        result.url = location.href;
        result.title = document.title;

        // Meta
        var meta = {};
        var desc = document.querySelector('meta[name="description"]');
        if (desc) meta.description = desc.content;
        var author = document.querySelector('meta[name="author"]');
        if (author) meta.author = author.content;
        var ogImage = document.querySelector('meta[property="og:image"]');
        if (ogImage) meta.ogImage = ogImage.content;
        result.meta = meta;

        // Detect page type
        var hasPasswordField = !!document.querySelector('input[type="password"]');
        var hasSearchInput = !!document.querySelector('input[type="search"]') ||
                             !!document.querySelector('input[name*="search"]') ||
                             !!document.querySelector('input[name*="query"]') ||
                             !!document.querySelector('input[name="q"]');
        var hasArticle = !!document.querySelector('article') ||
                         !!document.querySelector('[role="article"]') ||
                         !!document.querySelector('.article, .post, .entry');
        var hasTables = document.querySelectorAll('table').length > 0;
        var hasSearchResults = !!document.querySelector('.search-results, .results, [data-search-results]') ||
                               (hasSearchInput && document.querySelectorAll('a').length > 10);

        if (hasPasswordField) {
            result.pageType = 'login';
        } else if (hasSearchResults && hasSearchInput) {
            result.pageType = 'search';
        } else if (hasArticle) {
            result.pageType = 'article';
        } else if (hasTables) {
            result.pageType = 'table';
        } else {
            result.pageType = 'generic';
        }

        // Forms
        var forms = [];
        document.querySelectorAll('form').forEach(function(form, i) {
            if (i >= 5) return;
            var fields = [];
            form.querySelectorAll('input, select, textarea').forEach(function(el, j) {
                if (j >= 20) return;
                fields.push({
                    tag: el.tagName.toLowerCase(),
                    type: el.type || '',
                    name: el.name || '',
                    id: el.id || '',
                    placeholder: el.placeholder || '',
                    ariaLabel: el.getAttribute('aria-label') || '',
                    value: el.type === 'password' ? '' : (el.value || '').substring(0, 100)
                });
            });
            var submitBtn = form.querySelector('button[type="submit"], input[type="submit"]');
            forms.push({
                action: form.action || '',
                method: form.method || 'get',
                fields: fields,
                submitText: submitBtn ? (submitBtn.textContent || submitBtn.value || 'Submit').trim() : null
            });
        });
        result.forms = forms;

        // Headings
        var headings = [];
        document.querySelectorAll('h1, h2, h3').forEach(function(h, i) {
            if (i >= 20) return;
            var text = h.textContent.trim();
            if (text) headings.push({ level: parseInt(h.tagName[1]), text: text.substring(0, 200) });
        });
        result.headings = headings;

        // Links (top 15)
        var links = [];
        document.querySelectorAll('a[href]').forEach(function(a, i) {
            if (i >= 15) return;
            var text = a.textContent.trim();
            if (text && text.length > 1) {
                links.push({ text: text.substring(0, 100), href: a.href });
            }
        });
        result.links = links;

        // Main content as text (limit to 2000 chars)
        var mainEl = document.querySelector('main, article, [role="main"], .content, #content');
        if (!mainEl) mainEl = document.body;
        var textContent = mainEl.innerText || mainEl.textContent || '';
        result.mainContent = textContent.substring(0, 1000).trim();

        // Reading time estimate
        var wordCount = textContent.split(/\s+/).length;
        result.wordCount = wordCount;
        result.readingTimeMin = Math.ceil(wordCount / 200);

        // Tables (first 3, max 10 rows each)
        if (hasTables) {
            var tables = [];
            document.querySelectorAll('table').forEach(function(table, ti) {
                if (ti >= 3) return;
                var headers = [];
                table.querySelectorAll('thead th, thead td, tr:first-child th').forEach(function(th) {
                    headers.push(th.textContent.trim().substring(0, 100));
                });
                var rows = [];
                table.querySelectorAll('tbody tr, tr').forEach(function(tr, ri) {
                    if (ri >= 10) return;
                    var cells = [];
                    tr.querySelectorAll('td, th').forEach(function(td) {
                        cells.push(td.textContent.trim().substring(0, 100));
                    });
                    if (cells.length > 0) rows.push(cells);
                });
                tables.push({ headers: headers, rows: rows });
            });
            result.tables = tables;
        }

        return JSON.stringify(result);
        } catch(e) {
            return JSON.stringify({error: e.message, url: location.href, title: document.title, pageType: 'error'});
        }
    })()
    """#

    // MARK: - Extraction Script

    /// Injected JS that extracts the main page content as clean markdown-ish text.
    public static let extractionScript: String = #"""
    (function() {
        function nodeToMarkdown(el) {
            var md = '';
            var children = el.childNodes;
            for (var i = 0; i < children.length; i++) {
                var node = children[i];
                if (node.nodeType === 3) {
                    md += node.textContent;
                } else if (node.nodeType === 1) {
                    var tag = node.tagName.toLowerCase();
                    if (tag === 'script' || tag === 'style' || tag === 'nav' || tag === 'footer' || tag === 'header') continue;
                    if (tag === 'h1') md += '\n# ' + node.textContent.trim() + '\n\n';
                    else if (tag === 'h2') md += '\n## ' + node.textContent.trim() + '\n\n';
                    else if (tag === 'h3') md += '\n### ' + node.textContent.trim() + '\n\n';
                    else if (tag === 'h4') md += '\n#### ' + node.textContent.trim() + '\n\n';
                    else if (tag === 'p') md += node.textContent.trim() + '\n\n';
                    else if (tag === 'li') md += '- ' + node.textContent.trim() + '\n';
                    else if (tag === 'br') md += '\n';
                    else if (tag === 'a') md += '[' + node.textContent.trim() + '](' + (node.href || '') + ')';
                    else if (tag === 'strong' || tag === 'b') md += '**' + node.textContent.trim() + '**';
                    else if (tag === 'em' || tag === 'i') md += '*' + node.textContent.trim() + '*';
                    else if (tag === 'code') md += '`' + node.textContent.trim() + '`';
                    else if (tag === 'pre') md += '\n```\n' + node.textContent.trim() + '\n```\n\n';
                    else if (tag === 'blockquote') md += '\n> ' + node.textContent.trim() + '\n\n';
                    else if (tag === 'img') md += '![' + (node.alt || '') + '](' + (node.src || '') + ')';
                    else if (tag === 'ul' || tag === 'ol') md += '\n' + nodeToMarkdown(node) + '\n';
                    else if (tag === 'div' || tag === 'section' || tag === 'article' || tag === 'main') md += nodeToMarkdown(node);
                    else md += node.textContent || '';
                }
            }
            return md;
        }
        var mainEl = document.querySelector('article, main, [role="main"], .content, #content');
        if (!mainEl) mainEl = document.body;
        var result = nodeToMarkdown(mainEl);
        return result.substring(0, 10000).trim();
    })()
    """#
}
