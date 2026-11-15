import UIKit
import WebKit

/// 全屏 WKWebView 外壳：
/// - 顶部常驻原生状态条（永远可见）
/// - 底部诊断面板：把 WebView 内部的 JS 报错直接显示在屏幕上，便于排查白屏/黑屏
/// - 连不上时提供「重试 / 改地址 / 用 Safari 打开」
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private static let serverKey = "libretv.server"
    private static let defaultServer = "http://192.168.0.100:8080"
    private static let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?

    private let banner = UIView()
    private let bannerTitle = UILabel()
    private let bannerStatus = UILabel()

    private let diagPanel = UIView()
    private let diagText = UITextView()

    private var diagLines: [String] = []
    private var errorAlertVisible = false
    private var probeTask: URLSessionDataTask?

    private var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
        return URL(string: raw) ?? URL(string: Self.defaultServer)!
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)

        setupBanner()
        setupWebView()
        setupProgress()
        setupDiagPanel()
        buildToolbar()

        setStatus("正在连接…")
        connect()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(false, animated: false)
    }

    // MARK: - 顶部状态条

    private func setupBanner() {
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.backgroundColor = UIColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 1)
        view.addSubview(banner)

        bannerTitle.translatesAutoresizingMaskIntoConstraints = false
        bannerTitle.textColor = .white
        bannerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        bannerTitle.text = "LibreTV \(Self.appVersion) · \(serverURL.absoluteString)"
        bannerTitle.lineBreakMode = .byTruncatingMiddle
        banner.addSubview(bannerTitle)

        bannerStatus.translatesAutoresizingMaskIntoConstraints = false
        bannerStatus.textColor = UIColor(white: 0.85, alpha: 1)
        bannerStatus.font = .systemFont(ofSize: 12)
        bannerStatus.numberOfLines = 2
        bannerStatus.text = "启动中…"
        banner.addSubview(bannerStatus)

        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 50),

            bannerTitle.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            bannerTitle.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            bannerTitle.topAnchor.constraint(equalTo: banner.topAnchor, constant: 6),

            bannerStatus.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            bannerStatus.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            bannerStatus.topAnchor.constraint(equalTo: bannerTitle.bottomAnchor, constant: 2)
        ])
    }

    private func setStatus(_ text: String) {
        bannerStatus.text = text
    }

    // MARK: - WebView（含诊断脚本）

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()

        let ucc = WKUserContentController()
        ucc.add(self, name: "diag")
        ucc.addUserScript(WKUserScript(source: Self.diagScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    /// 在页面最早期注入：捕获语法错误、运行时报错、Promise 拒绝、console.error，并回传原生
    private static let diagScript = """
    (function(){
      function send(s){
        try { window.webkit.messageHandlers.diag.postMessage(String(s).slice(0, 600)); } catch(e){}
      }
      window.addEventListener('error', function(e){
        var where = (e.filename||'').split('/').pop() + ':' + (e.lineno||0);
        var msg = e.message || (e.error && e.error.message) || 'unknown error';
        var stack = (e.error && e.error.stack) ? String(e.error.stack).split('\\n').slice(0,2).join(' | ') : '';
        send('JS错误: ' + msg + ' @ ' + where + (stack ? ' || ' + stack : ''));
      }, true);
      window.addEventListener('unhandledrejection', function(e){
        var r = e.reason;
        send('Promise拒绝: ' + ((r && (r.stack || r.message)) || r));
      });
      var ce = console.error;
      console.error = function(){
        try { send('console.error: ' + Array.prototype.slice.call(arguments).join(' ')); } catch(e){}
        return ce.apply(console, arguments);
      };
      function report(){
        try {
          var len = document.body ? document.body.innerText.replace(/\\s+/g,' ').trim().length : -1;
          var html = document.body ? document.body.innerHTML.length : -1;
          send('页面状态: 文字长度=' + len + ' HTML长度=' + html + ' JS块数=' + document.querySelectorAll('script[src]').length + ' 样式表=' + document.querySelectorAll('link[rel=stylesheet]').length);
        } catch(e){ send('report失败: ' + e); }
      }
      document.addEventListener('DOMContentLoaded', function(){ setTimeout(report, 1200); });
      window.addEventListener('load', function(){ setTimeout(report, 2500); });
    })();
    """

    private func setupProgress() {
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .systemBlue
        progress.trackTintColor = .clear
        progress.isHidden = true
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: banner.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let value = Float(webView.estimatedProgress)
            self.progress.progress = value
            self.progress.isHidden = value >= 1.0
        }
    }

    // MARK: - 诊断面板

    private func setupDiagPanel() {
        diagPanel.translatesAutoresizingMaskIntoConstraints = false
        diagPanel.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 0.96)
        diagPanel.isHidden = true
        view.addSubview(diagPanel)

        diagText.translatesAutoresizingMaskIntoConstraints = false
        diagText.backgroundColor = .clear
        diagText.textColor = UIColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)
        diagText.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        diagText.isEditable = false
        diagText.isScrollEnabled = true
        diagText.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        diagPanel.addSubview(diagText)

        NSLayoutConstraint.activate([
            diagPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diagPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diagPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            diagPanel.heightAnchor.constraint(equalToConstant: 132),

            diagText.leadingAnchor.constraint(equalTo: diagPanel.leadingAnchor, constant: 4),
            diagText.trailingAnchor.constraint(equalTo: diagPanel.trailingAnchor, constant: -4),
            diagText.topAnchor.constraint(equalTo: diagPanel.topAnchor, constant: 2),
            diagText.bottomAnchor.constraint(equalTo: diagPanel.bottomAnchor, constant: -2)
        ])
    }

    private func appendDiag(_ line: String) {
        diagLines.append(line)
        if diagLines.count > 10 { diagLines.removeFirst(diagLines.count - 10) }
        diagText.text = diagLines.joined(separator: "\n")
        diagPanel.isHidden = false
        let end = NSRange(location: diagText.text.count, length: 0)
        diagText.scrollRangeToVisible(end)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "diag" else { return }
        appendDiag("[\(Self.clock())] " + String(describing: message.body))
    }

    private static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - 工具栏

    private func buildToolbar() {
        let back = UIBarButtonItem(title: "后退", style: .plain, target: self, action: #selector(goBack))
        let home = UIBarButtonItem(title: "主页", style: .plain, target: self, action: #selector(reloadHome))
        let refresh = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))
        let lite = UIBarButtonItem(title: "轻量版", style: .plain, target: self, action: #selector(openLite))
        let settings = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings))
        let safari = UIBarButtonItem(title: "Safari", style: .plain, target: self, action: #selector(openInSafari))
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [back, spacer, home, spacer, lite, spacer, refresh, spacer, settings, spacer, safari]
    }

    // MARK: - 连接

    private func connect() {
        let url = serverURL
        bannerTitle.text = "LibreTV \(Self.appVersion) · \(url.absoluteString)"
        setStatus("正在连接服务器…")

        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25))

        probe(url) { [weak self] ok, message in
            guard let self = self else { return }
            if ok {
                self.setStatus("连上了（" + message + "）")
            } else {
                self.setStatus("连不上：\(message)")
                self.showErrorAlert(message)
            }
        }
    }

    private func probe(_ url: URL, completion: @escaping (Bool, String) -> Void) {
        probeTask?.cancel()
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 8
        conf.timeoutIntervalForResource = 12
        let session = URLSession(configuration: conf)
        probeTask = session.dataTask(with: URLRequest(url: url)) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let ns = error as NSError
                    var hint = "\(ns.localizedDescription)（\(ns.code)）"
                    if ns.code == -1009 || ns.code == -1003 || ns.code == -1004 || ns.code == -1001 {
                        hint += "；若网络正常，去 设置→隐私→本地网络 允许 LibreTV"
                    }
                    completion(false, hint)
                    return
                }
                if let http = response as? HTTPURLResponse {
                    completion(true, "HTTP \(http.statusCode)")
                } else {
                    completion(true, "服务器有响应")
                }
            }
        }
        probeTask?.resume()
    }

    @objc private func reloadHome() { connect() }

    @objc private func reload() {
        if webView.url == nil { connect() } else { webView.reload() }
    }

    @objc private func goBack() {
        if webView.canGoBack { webView.goBack() } else { connect() }
    }

    @objc private func openLite() {
        let base = serverURL.absoluteString.replacingOccurrences(of: "/lite.html", with: "")
        guard let url = URL(string: base.hasSuffix("/") ? base + "lite.html" : base + "/lite.html") else { return }
        setStatus("打开轻量版：" + url.absoluteString)
        webView.load(URLRequest(url: url))
    }

    @objc private func openInSafari() {
        if let current = webView.url, UIApplication.shared.canOpenURL(current) {
            UIApplication.shared.open(current, options: [:], completionHandler: nil)
        } else if UIApplication.shared.canOpenURL(serverURL) {
            UIApplication.shared.open(serverURL, options: [:], completionHandler: nil)
        }
    }

    @objc private func showSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "服务器地址",
            message: "填电脑上 LibreTV 的地址，例如 http://192.168.0.100:8080（轻量版加 /lite.html）。",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = self.serverURL.absoluteString
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并连接", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let text = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, URL(string: text) != nil else { return }
            UserDefaults.standard.set(text, forKey: Self.serverKey)
            self.errorAlertVisible = false
            self.webView.stopLoading()
            self.connect()
        })
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false
        setStatus("页面加载中…")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.isHidden = true
        errorAlertVisible = false
        setStatus("已打开：" + (webView.url?.absoluteString ?? ""))

        // 第三方检查：真的渲染出内容了吗？
        webView.evaluateJavaScript("(document.body ? document.body.innerText.trim().length : -1)") { [weak self] result, _ in
            guard let self = self else { return }
            let length = (result as? NSNumber)?.intValue ?? -1
            if length <= 0 {
                self.appendDiag("[\(Self.clock())] 原生检测: 正文为空（length=\(length)），JS 渲染未完成")
            } else {
                self.appendDiag("[\(Self.clock())] 原生检测: 正文长度 \(length)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebError(error)
    }

    private func handleWebError(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        progress.isHidden = true
        setStatus("页面加载失败：\(ns.localizedDescription)（\(ns.code)）")
        appendDiag("[\(Self.clock())] 导航失败: \(ns.localizedDescription)（\(ns.code)）")
        showErrorAlert(ns.localizedDescription + "（\(ns.code)）")
    }

    private func showErrorAlert(_ message: String) {
        guard !errorAlertVisible, presentedViewController == nil else { return }
        errorAlertVisible = true
        let alert = UIAlertController(
            title: "连不上服务器",
            message: "① 电脑上的 LibreTV 是否在运行；② 手机与电脑是否同一个 Wi-Fi；③ 设置→隐私→本地网络 里是否允许了 LibreTV。\n\n\(message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.errorAlertVisible = false
            self?.connect()
        })
        alert.addAction(UIAlertAction(title: "改地址", style: .default) { [weak self] _ in
            self?.errorAlertVisible = false
            self?.showSettings()
        })
        alert.addAction(UIAlertAction(title: "用 Safari 打开", style: .default) { [weak self] _ in
            self?.errorAlertVisible = false
            self?.openInSafari()
        })
        present(alert, animated: true)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }
}
