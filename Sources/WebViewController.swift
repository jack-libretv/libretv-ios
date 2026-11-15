import UIKit
import WebKit

/// 全屏 WKWebView 外壳：加载 LibreTV，底部工具栏可改服务器地址、刷新、后退。
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private static let serverKey = "libretv.server"
    private static let defaultServer = "http://192.168.0.100:8080"

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    private var errorAlertVisible = false

    private var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
        return URL(string: raw) ?? URL(string: Self.defaultServer)!
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .systemTeal
        progress.trackTintColor = .clear
        progress.isHidden = true
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let value = Float(webView.estimatedProgress)
            self.progress.progress = value
            self.progress.isHidden = value >= 1.0
        }

        buildChrome()
        loadHome()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.isToolbarHidden = false
    }

    // MARK: - 界面

    private func buildChrome() {
        let back = UIBarButtonItem(title: "后退", style: .plain, target: self, action: #selector(goBack))
        let home = UIBarButtonItem(title: "主页", style: .plain, target: self, action: #selector(loadHome))
        let refresh = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))
        let settings = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings))
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        toolbarItems = [back, spacer, home, spacer, refresh, spacer, settings]
        navigationItem.title = "LibreTV"
        navigationController?.isToolbarHidden = false
        navigationItem.largeTitleDisplayMode = .never
    }

    // MARK: - 加载

    @objc private func loadHome() {
        let url = serverURL
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15))
        navigationItem.title = url.host ?? "LibreTV"
    }

    @objc private func reload() {
        if webView.url == nil {
            loadHome()
        } else {
            webView.reload()
        }
    }

    @objc private func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            loadHome()
        }
    }

    @objc private func showSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "服务器地址",
            message: "填这台电脑上 LibreTV 的地址，例如 http://192.168.0.100:8080。",
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
        alert.addAction(UIAlertAction(title: "保存并打开", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let text = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, URL(string: text) != nil else { return }
            UserDefaults.standard.set(text, forKey: Self.serverKey)
            self.errorAlertVisible = false
            self.loadHome()
        })
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.isHidden = true
        errorAlertVisible = false
        if let host = webView.url?.host {
            navigationItem.title = host
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        // 取消、重定向中断之类不算故障
        guard ns.code != NSURLErrorCancelled, ns.code != 102 else { return }
        guard !errorAlertVisible, presentedViewController == nil else { return }
        errorAlertVisible = true

        let alert = UIAlertController(
            title: "连不上服务器",
            message: "确认电脑上的 LibreTV 正在运行，手机和电脑在同一 Wi-Fi，并在「设置」里填对地址。\n\n\(ns.localizedDescription)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.errorAlertVisible = false
            self?.loadHome()
        })
        alert.addAction(UIAlertAction(title: "改地址", style: .default) { [weak self] _ in
            self?.errorAlertVisible = false
            self?.showSettings()
        })
        present(alert, animated: true)
    }

    // MARK: - WKUIDelegate

    /// 页面里的 window.open / target=_blank 一律在当前视图打开，不跳浏览器
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
        guard presentedViewController == nil else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }
}
