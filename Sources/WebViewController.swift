import UIKit
import WebKit

/// 全屏 WKWebView 外壳：启动先探测服务器，连不上给出文字提示，不出现黑屏。
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private static let serverKey = "libretv.server"
    private static let defaultServer = "http://192.168.0.100:8080"

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?

    private let statusPill = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var errorAlertVisible = false
    private var probeTask: URLSessionDataTask?

    private var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
        return URL(string: raw) ?? URL(string: Self.defaultServer)!
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1)

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
        webView.backgroundColor = .clear
        webView.isHidden = true
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .systemTeal
        progress.trackTintColor = .clear
        progress.isHidden = true
        view.addSubview(progress)

        // 状态提示胶囊
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.backgroundColor = UIColor(white: 0.15, alpha: 0.92)
        statusPill.layer.cornerRadius = 14
        statusPill.layer.masksToBounds = true
        view.addSubview(statusPill)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        statusPill.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusPill.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusPill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusPill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),

            spinner.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 14),
            spinner.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -12)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let value = Float(webView.estimatedProgress)
            self.progress.progress = value
            self.progress.isHidden = value >= 1.0
        }

        buildChrome()
        connect()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    // MARK: - 界面

    private func buildChrome() {
        let back = UIBarButtonItem(title: "后退", style: .plain, target: self, action: #selector(goBack))
        let home = UIBarButtonItem(title: "主页", style: .plain, target: self, action: #selector(reloadHome))
        let refresh = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(reload))
        let settings = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings))
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [back, spacer, home, spacer, refresh, spacer, settings]
        navigationItem.title = "LibreTV"
        navigationItem.largeTitleDisplayMode = .never
    }

    private func showStatus(_ text: String, spinning: Bool = true) {
        statusLabel.text = text
        statusPill.isHidden = false
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func hideStatus() {
        spinner.stopAnimating()
        statusPill.isHidden = true
    }

    // MARK: - 连接

    private func connect() {
        let url = serverURL
        navigationItem.title = url.host ?? "LibreTV"
        showStatus("正在连接\n\(url.absoluteString)")

        probe(url) { [weak self] ok, message in
            guard let self = self else { return }
            if ok {
                self.showStatus("已连上服务器，正在加载页面…")
                self.webView.isHidden = false
                self.webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
            } else {
                self.showStatus("连不上服务器\n\(message)\n\n点底部「设置」改地址，或「刷新」重试", spinning: false)
                self.showErrorAlert(message)
            }
        }
    }

    private func probe(_ url: URL, completion: @escaping (Bool, String) -> Void) {
        probeTask?.cancel()
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 8
        conf.timeoutIntervalForResource = 10
        let session = URLSession(configuration: conf)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        probeTask = session.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let ns = error as NSError
                    completion(false, "\(ns.localizedDescription)（\(ns.code)）")
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

    @objc private func reloadHome() {
        connect()
    }

    @objc private func reload() {
        if webView.url == nil || !statusPill.isHidden {
            connect()
        } else {
            webView.reload()
        }
    }

    @objc private func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            connect()
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
        alert.addAction(UIAlertAction(title: "保存并连接", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let text = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, URL(string: text) != nil else { return }
            UserDefaults.standard.set(text, forKey: Self.serverKey)
            self.errorAlertVisible = false
            self.connect()
        })
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.isHidden = true
        errorAlertVisible = false
        hideStatus()
        if let host = webView.url?.host {
            navigationItem.title = host
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
        showStatus("页面加载失败\n\(ns.localizedDescription)（\(ns.code)）\n\n点底部「刷新」重试", spinning: false)
        showErrorAlert(ns.localizedDescription)
    }

    private func showErrorAlert(_ message: String) {
        guard !errorAlertVisible, presentedViewController == nil else { return }
        errorAlertVisible = true
        let alert = UIAlertController(
            title: "连不上服务器",
            message: "确认电脑上的 LibreTV 正在运行、手机与电脑在同一 Wi-Fi、电脑防火墙已放行 8080。\n\n\(message)",
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
