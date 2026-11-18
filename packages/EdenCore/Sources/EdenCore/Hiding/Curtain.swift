import Combine
import Foundation
import WebKit

// Taking things off a page and keeping them off, on the Mac, iPhone and iPad.
//
// Point at a cookie bar, a newsletter overlay, a sidebar of related nonsense —
// it goes, and it is still gone next time. Everything is remembered by site, as
// a list of selectors (Curtain, hidden.json), and put back on by a stylesheet
// injected before the page has drawn a single frame (Veiling.style), so
// nothing is ever seen appearing and vanishing. Choosing what to hide is the
// picker's (Veiling.picker): pointing and clicking on the Mac; on a touch
// screen a tap offers the element, which can be widened to what holds it,
// and a second word hides it. Each app keeps its own controls.

public struct Veil: Codable, Identifiable, Equatable, Sendable {
    public var selector: String
    /// What it was, in words, so the list of what you have hidden reads like
    /// something rather than like a stylesheet.
    public var label: String
    /// How big it was and where it sat — measured when you hid it, because a
    /// hidden thing has no size to measure later. Two elements can easily read
    /// the same; they rarely have the same shape in the same corner.
    public var note: String?
    public var date: Date

    public var id: String { selector }

    public init(selector: String, label: String, note: String?, date: Date) {
        self.selector = selector
        self.label = label
        self.note = note
        self.date = date
    }
}

@MainActor
public final class Curtain: ObservableObject {
    @Published public private(set) var byHost: [String: [Veil]] = [:]
    private let file: URL

    /// `file`: where it is kept; tests hand one of their own.
    public init(file: URL = Store.file("hidden.json")) {
        self.file = file
        load()
    }

    /// The site, as what is hidden is kept by: its host, without "www.".
    public static func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func host(of url: URL?) -> String? { Self.host(of: url) }

    public func veils(on host: String?) -> [Veil] {
        guard let host else { return [] }
        return byHost[host] ?? []
    }

    public func hide(_ selector: String, label: String, note: String, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return }
        list.append(Veil(selector: selector, label: label, note: note, date: Date()))
        byHost[host] = list
        save()
    }

    /// Put one back.
    public func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        save()
    }

    /// Put the last one back — ⌘Z, while you are still pointing at things.
    @discardableResult
    public func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        save()
        return last
    }

    public func restoreAll(on host: String) {
        byHost[host] = nil
        save()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out — that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    public func css(on host: String?, without spared: String? = nil) -> String {
        Curtain.css(for: veils(on: host), without: spared)
    }

    /// The stylesheet for these veils (a private tab's own, say).
    public static func css(for veils: [Veil], without spared: String? = nil) -> String {
        veils
            .filter { $0.selector != spared }
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    // MARK: - the file

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let stored = try? JSONDecoder().decode([String: [Veil]].self, from: data) else {
            // Set aside rather than written over.
            Store.quarantine(file)
            return
        }
        byHost = stored
    }

    /// Off the main thread, the newest list winning (Disk).
    private func save() {
        let snapshot = byHost
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}

/// What the picker says (Veiling.picker).
public enum VeilMessage: Equatable, Sendable {
    /// What it is, in words, how big and where: enough to hide it by.
    public struct Choice: Equatable, Sendable {
        public var selector: String
        public var label: String
        public var note: String

        public init(selector: String, label: String, note: String) {
            self.selector = selector
            self.label = label
            self.note = note
        }
    }

    /// Chosen to hide.
    case picked(Choice)
    /// Tapped, on a touch screen: offered, to hide, widen or let go.
    case offered(Choice)
    /// What was offered left the page before it was hidden: a selector made
    /// for it now would name something else, so it must be tapped afresh.
    case withdrawn
    /// Picking ended from the page.
    case ended
    case trouble(String)

    /// What a message from the page says, or nil for one it doesn't.
    public init?(_ body: Any) {
        guard let body = body as? [String: Any] else { return nil }
        if let trouble = body["trouble"] as? String {
            self = .trouble(trouble)
        } else if body["off"] as? Bool == true {
            self = .ended
        } else if body["withdrawn"] as? Bool == true {
            self = .withdrawn
        } else if let selector = body["selector"] as? String, !selector.isEmpty {
            let choice = Choice(selector: selector, label: body["label"] as? String ?? selector,
                                note: body["note"] as? String ?? "")
            self = body["offered"] as? Bool == true ? .offered(choice) : .picked(choice)
        } else {
            return nil
        }
    }
}

/// Carries what the picker says back from the page, to whoever listens, with
/// where it came from: one relay can serve every page sharing a content
/// controller (a pop-up shares its opener's).
public final class VeilRelay: NSObject, WKScriptMessageHandler {
    public static let name = "officeVeil"

    /// Where a message came from.
    public struct Origin {
        /// The picking session it is for (Veiling.on), if one was named.
        public let session: String?
        /// The page that said it.
        public let page: WKWebView?
    }

    /// Told on the main actor.
    public var received: (@MainActor (VeilMessage, Origin) -> Void)?

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let said = VeilMessage(message.body) else { return }
        let origin = Origin(session: (message.body as? [String: Any])?["session"] as? String, page: message.webView)
        MainActor.assumeIsolated { received?(said, origin) }
    }
}

public enum Veiling {
    /// A stylesheet put in before the document has a body, so nothing is ever
    /// seen arriving and then leaving.
    public static func style(_ css: String) -> String {
        "(function () {\n" +
        "  var css = \(literal(css));\n" +
        "\(sheet)" +
        "})();"
    }

    /// Every site's stylesheet in one script, which puts on the one for the
    /// site the page is actually on — or takes away what was on, for a site
    /// with nothing hidden: the same script serves every page of a content
    /// controller (a pop-up shares its opener's), whatever site each is at,
    /// and restyles a page already showing. `byHost`: CSS by host as Curtain
    /// keys it (Curtain.host(of:)).
    public static func style(byHost: [String: String]) -> String {
        let rules = byHost.filter { !$0.value.isEmpty }
        let map = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "(function () {\n" +
        "  var rules = \(map);\n" +
        "  var host = location.hostname.toLowerCase().replace(/^www\\./, '');\n" +
        "  var css = Object.prototype.hasOwnProperty.call(rules, host) ? rules[host] : '';\n" +
        "\(sheet)" +
        "})();"
    }

    /// The page's one hiding stylesheet set to `css`, made only when there is
    /// something to put in it.
    private static let sheet = """
          var sheet = document.getElementById('office-veil');
          if (!sheet) {
            if (!css) return;
            sheet = document.createElement('style');
            sheet.id = 'office-veil';
            (document.head || document.documentElement).appendChild(sheet);
          }
          sheet.textContent = css;

        """

    /// Picking on: by touch (a tap offers) or by pointer (a press hides).
    /// `session`: carried back on everything the picker says, so what a page
    /// said for one session is never taken for another's.
    public static func on(touch: Bool, session: String? = nil) -> String {
        call("on", touch ? "true" : "false", session.map(literal) ?? "null")
    }

    /// Picking off — only that session's, when one is named.
    public static func off(session: String? = nil) -> String { call("off", session.map(literal) ?? "null") }
    /// The element offered, widened to what holds it (touch).
    public static let widen = call("widen")
    /// The element offered, hidden (touch).
    public static let confirm = call("confirm")
    /// The element offered, let go (touch).
    public static let clear = call("clear")

    /// One hidden thing shown, outlined and scrolled to: the stylesheet
    /// without it, so it comes back with the layout it had.
    public static func peek(_ selector: String, keeping css: String) -> String {
        call("peek", literal(css), literal(selector))
    }

    public static func unpeek(_ css: String) -> String { call("unpeek", literal(css)) }

    private static func call(_ method: String, _ arguments: String...) -> String {
        "window.__officeVeil && window.__officeVeil.\(method)(\(arguments.joined(separator: ", ")))"
    }

    /// A string as a JavaScript literal, whatever it holds.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    public static let picker = """
    (function () {
      if (window.__officeVeil) return;
      // `touch`: a tap offers what it landed on (`offered`), which can be
      // widened to what holds it and is hidden only when confirmed; with a
      // pointer, a press hides what it is over at once.
      var frame = null, tag = null, target = null, live = false, touch = false, session = null;

      function sheet(id) {
        var s = document.getElementById(id);
        if (!s) {
          s = document.createElement('style');
          s.id = id;
          (document.head || document.documentElement).appendChild(s);
        }
        return s;
      }

      function chrome() {
        if (frame) return frame;
        frame = document.createElement('div');
        frame.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;' +
          'border:2px solid rgba(23,23,23,.9);background:rgba(23,23,23,.07);' +
          'border-radius:4px;transition:all .07s ease-out;display:none';
        tag = document.createElement('div');
        tag.style.cssText = 'position:absolute;font:500 11px -apple-system,' +
          'BlinkMacSystemFont,sans-serif;color:#fff;background:#171717;padding:2px 7px;' +
          'border-radius:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
        frame.appendChild(tag);
        document.documentElement.appendChild(frame);
        return frame;
      }

      function place(el) {
        var box = chrome(), r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
        tag.textContent = name(el);
        // Above the element if there is sky above it, tucked inside its top
        // edge if there isn't — an element flush with the top of the window
        // would otherwise have its name cut off by the window.
        tag.style.top = r.top >= 26 ? '-21px' : '3px';
        // And never off the left or right edge either.
        tag.style.left = Math.max(2, -r.left + 4) + 'px';
        tag.style.maxWidth = Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px';
      }

      var known = {
        nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar',
        form: 'Form', dialog: 'Dialog', video: 'Video', img: 'Image',
        button: 'Button', iframe: 'Embed', figure: 'Figure', table: 'Table'
      };

      // What it is, in the order a person would answer the question: what it
      // calls itself, then what kind of thing it is, then what it says.
      function name(el) {
        var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
        if (said && said.trim()) return clip(said.trim(), 40);
        var tagName = el.tagName.toLowerCase();
        if (known[tagName]) return known[tagName];
        var role = el.getAttribute && el.getAttribute('role');
        if (role) return role.charAt(0).toUpperCase() + role.slice(1);
        var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
        return text ? clip(text, 40) : tagName;
      }

      /// How big, and which corner. Two sidebars read alike; they are rarely
      /// the same shape in the same place.
      function shape(el) {
        var r = el.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var side = cx < window.innerWidth / 3 ? 'left'
                 : (cx > window.innerWidth * 2 / 3 ? 'right' : 'centre');
        var band = cy < window.innerHeight / 3 ? 'top'
                 : (cy > window.innerHeight * 2 / 3 ? 'bottom' : 'middle');
        return Math.round(r.width) + '×' + Math.round(r.height) + ' · ' + band + ' ' + side;
      }

      function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

      // A class worth hanging a rule on: a word, not a build artefact.
      function steady(c) {
        return /^[a-zA-Z][\\w-]{2,29}$/.test(c) && !/\\d{3,}/.test(c) &&
               !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
      }

      function unique(sel) {
        try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
      }

      function selectorFor(el) {
        if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);

        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'aria-label', 'name', 'role'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) {
            var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
            if (unique(s)) return s;
          }
        }

        var classes = (el.className && typeof el.className === 'string')
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
        if (classes.length) {
          var byClass = el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.');
          if (unique(byClass)) return byClass;
        }

        // Last resort: a path, anchored on the nearest thing with a name.
        var parts = [], node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node.id && unique('#' + CSS.escape(node.id))) {
            parts.unshift('#' + CSS.escape(node.id));
            break;
          }
          var tagName = node.tagName.toLowerCase();
          var parent = node.parentElement;
          if (!parent) { parts.unshift(tagName); break; }
          var kin = Array.prototype.filter.call(parent.children, function (c) {
            return c.tagName === node.tagName;
          });
          parts.unshift(kin.length > 1
            ? tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')'
            : tagName);
          node = parent;
        }
        return parts.join(' > ');
      }

      function onMove(e) {
        if (!live) return;
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === frame || el === document.documentElement || el === document.body) return;
        target = el;
        place(el);
      }

      // Everything a press can be, swallowed. Real pages act on pointerdown or
      // mousedown and are gone before a click ever completes — which looked
      // exactly like nothing happening.
      function swallow(e) {
        if (!live) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      function choice(el) {
        return { selector: selectorFor(el), label: name(el), note: shape(el) };
      }

      // Everything said to the app carries the session it is for.
      function post(body) {
        if (session) body.session = session;
        window.webkit.messageHandlers.officeVeil.postMessage(body);
      }

      // `el`, to hide — or, by touch, offered. One the page has taken away
      // meanwhile is never named: its selector would be for some other thing
      // ('div', say) and hide all of that instead.
      function report(el, offered) {
        if (!el.isConnected) return withdraw();
        try {
          var said = choice(el);
          if (offered) said.offered = true;
          post(said);
        } catch (err) {
          post({ trouble: String(err) });
        }
      }

      // What was offered let go, the page having taken it away.
      function withdraw() {
        target = null;
        if (frame) frame.style.display = 'none';
        post({ withdrawn: true });
      }

      function plain(el) {
        return el && el !== frame && !el.__officeCover && el !== document.documentElement && el !== document.body;
      }

      // A finger touching down or lifting, kept from the page — which may act
      // on either — but never held back: a scroll is still a scroll, and the
      // tap still becomes a click.
      function muffle(e) {
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      // A tap: what it landed on, offered, outlined until it is hidden,
      // widened or let go. Only a tap — a scroll is still a scroll.
      function onTap(e) {
        if (!live) return;
        swallow(e);
        var el = under(e.clientX, e.clientY);
        if (plain(el)) offer(el);
      }

      // What is really on top at a point: looked for through the frames'
      // covers, which take every tap over a frame — the frame itself, or
      // whatever lies over it, a banner over a video, say.
      function under(x, y) {
        covers.forEach(function (c) { c.style.pointerEvents = 'none'; });
        var el = document.elementFromPoint(x, y);
        covers.forEach(function (c) { c.style.pointerEvents = ''; });
        return el;
      }

      function offer(el) {
        target = el;
        place(el);
        report(el, true);
      }

      // A frame's own taps never reach this page: while picking by touch,
      // each gets a cover of this page's, which takes them (see under), kept
      // over its frame as the page scrolls, resizes or changes.
      var covers = [];
      function cover() {
        var frames = document.querySelectorAll('iframe, frame, embed, object'), used = 0;
        for (var i = 0; i < frames.length; i++) {
          var r = frames[i].getBoundingClientRect();
          if (r.width < 4 || r.height < 4) continue;
          var c = covers[used] || makeCover();
          c.style.left = r.left + 'px';
          c.style.top = r.top + 'px';
          c.style.width = r.width + 'px';
          c.style.height = r.height + 'px';
          used++;
        }
        covers.splice(used).forEach(function (c) { c.remove(); });
      }
      function makeCover() {
        var c = document.createElement('div');
        c.__officeCover = true;
        c.style.cssText = 'position:fixed;z-index:2147483645;background:transparent;cursor:pointer';
        document.documentElement.appendChild(c);
        covers.push(c);
        return c;
      }
      function uncover() {
        covers.forEach(function (c) { c.remove(); });
        covers = [];
      }

      // The outline and the covers follow the page, about once a frame at
      // most: a scroll, or a page busy changing, says so far more often.
      var queued = false;
      function relayout() {
        if (queued || !live || !touch) return;
        queued = true;
        setTimeout(function () {
          queued = false;
          if (!live || !touch) return;
          if (target && target.isConnected) place(target);
          cover();
        }, 16);
      }

      // The page changing under the covers — never the picker's own outline
      // and covers changing, which would only start it again.
      function ours(node) {
        return !!node && (!!node.__officeCover || (!!frame && frame.contains(node)));
      }
      function theirs(node) { return !ours(node); }
      function onChange(records) {
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          if (ours(r.target)) continue;
          if (r.type !== 'childList' || Array.prototype.some.call(r.addedNodes, theirs) ||
              Array.prototype.some.call(r.removedNodes, theirs)) return relayout();
        }
      }

      function onPress(e) {
        if (!live) return;
        swallow(e);
        // The pointer may have arrived without ever moving — a click on the
        // very first element under it, or a trackpad tap.
        var el = (target && target.isConnected) ? target : document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === frame || el === document.documentElement || el === document.body) return;
        report(el, false);
        target = null;
        if (frame) frame.style.display = 'none';
      }

      // What picking listens to, to be let go of exactly.
      var listening = [], watcher = null, sizes = null;
      function listen(on, kind, fn, options) {
        on.addEventListener(kind, fn, options);
        listening.push([on, kind, fn, options]);
      }

      function start(byTouch, id) {
        live = true;
        touch = !!byTouch;
        session = id || null;
        chrome();
        var root = document.documentElement;
        if (touch) {
          // iOS sends a tap's click only to what looks tappable: with a
          // pointer cursor everything does, so any element can be offered.
          root.style.cursor = 'pointer';
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'dblclick', 'contextmenu'].forEach(function (kind) {
            listen(document, kind, swallow, true);
          });
          listen(document, 'click', onTap, true);
          listen(document, 'touchstart', muffle, { capture: true, passive: true });
          listen(document, 'touchend', muffle, { capture: true, passive: true });
          listen(window, 'scroll', relayout, { capture: true, passive: true });
          listen(window, 'resize', relayout, { passive: true });
          // What moves things without the markup changing: an image or a
          // font arriving, an animation finishing.
          ['load', 'transitionend', 'animationend'].forEach(function (kind) {
            listen(document, kind, relayout, { capture: true, passive: true });
          });
          watcher = new MutationObserver(onChange);
          watcher.observe(root, { childList: true, subtree: true, attributes: true, characterData: true });
          sizes = new ResizeObserver(relayout);
          sizes.observe(root);
          if (document.body) sizes.observe(document.body);
          cover();
        } else {
          root.style.cursor = 'crosshair';
          listen(document, 'mousemove', onMove, true);
          listen(document, 'pointermove', onMove, true);
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click',
           'dblclick', 'contextmenu', 'touchstart'].forEach(function (kind) {
            listen(document, kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
        }
      }

      // Picking stopped, saying nothing; true if it was on.
      function stop() {
        if (!live) return false;
        listening.forEach(function (l) { l[0].removeEventListener(l[1], l[2], l[3]); });
        listening = [];
        if (watcher) watcher.disconnect();
        if (sizes) sizes.disconnect();
        watcher = null;
        sizes = null;
        live = false;
        touch = false;
        target = null;
        if (frame) frame.style.display = 'none';
        document.documentElement.style.cursor = '';
        uncover();
        return true;
      }

      // A page leaving — for good, or into the back-forward cache — ends
      // picking, and says so: a page coming back is never found still
      // picking, nor the app still thinking it is.
      window.addEventListener('pagehide', function () { end(); });

      function end() {
        if (!stop()) return;
        post({ off: true });
        session = null;
      }

      window.__officeVeil = {
        // Begun again when already on, so the newest session is the one.
        on: function (byTouch, id) {
          stop();
          start(byTouch, id);
        },
        off: function (id) {
          if (!id || id === session) end();
        },
        // What was offered, widened to what holds it.
        widen: function () {
          if (!live || !target) return;
          if (!target.isConnected) return withdraw();
          var up = target.parentElement;
          if (plain(up)) offer(up);
        },
        // What was offered, hidden.
        confirm: function () {
          if (!live || !target) return;
          report(target, false);
          target = null;
          if (frame) frame.style.display = 'none';
        },
        // What was offered, let go.
        clear: function () {
          target = null;
          if (frame) frame.style.display = 'none';
        },
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          sheet('office-veil').textContent = css;
          sheet('office-peek').textContent = sel +
            ' { outline: 2px solid rgba(23,23,23,.9) !important; outline-offset: 2px !important; }';
          try {
            var el = document.querySelector(sel);
            if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          } catch (e) {}
        },
        unpeek: function (css) {
          sheet('office-veil').textContent = css;
          sheet('office-peek').textContent = '';
        }
      };
    })();
    """
}
