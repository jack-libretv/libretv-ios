import UIKit
import WebKit

/// 全屏 WKWebView 外壳：顶部常驻一条原生状态条（永远可见，便于排查），
/// 启动先探测服务器；连不上时给出明确原因，并提供「用 Safari 打开」兜底。
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private static let serverKey = "libretv.server"
    private static let defaultServer = "http://192.168.0.100:8080"
    private static let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?

    private let banner = UIView()
    private let bannerTitle = UILabel()
    private let bannerStatus = UILabel()

    private var errorAlertVisible = false
    private var probeTask: URLSessionDataTask?

    private var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
        return URL(string: raw) ?? URL(string: Self.defaultServer)!
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 浅色底：任何情况下都能一眼区分「App 起来了」和「App 没起来」
        view.backgroundColor = UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)

        setupBanner()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()

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

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .systemBlue
        progress.trackTintColor = .clear
        progress.isHidden = true
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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

        buildToolbar()
        setStatus("正在连接…")
        connect()
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

    private func buildToolbar() {
        let back = UIBarButtonItem(title: "后退", style: .plain, target: self, action: #selector(goBack))
        let home = UIBarButtonItem(title: "主页", style: .plain, target: self, action: #selector(reloadHome))
        let refresh = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))
        let settings = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings))
        let safari = UIBarButtonItem(title: "Safari", style: .plain, target: self, action: #selector(openInSafari))
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [back, spacer, home, spacer, refresh, spacer, settings, spacer, safari]
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    // MARK: - 连接

    private func connect() {
        let url = serverURL
        bannerTitle.text = "LibreTV \(Self.appVersion) · \(url.absoluteString)"
        setStatus("正在连接服务器…")

        probe(url) { [weak self] ok, message in
            guard let self = self else { return }
            if ok {
                self.setStatus("连上了（" + message + "），正在加载页面…")
                self.webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25))
            } else {
                self.setStatus("连不上：" + message)
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

    @objc private func openInSafari() {
        if UIApplication.shared.canOpenURL(serverURL) {
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
            self.webView.url = nil
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
