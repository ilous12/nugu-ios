//
//  NuguServiceWebView.swift
//  NuguServiceKit
//
//  Created by 김진님/AI Assistant개발 Cell on 2020/06/15.
//  Copyright (c) 2020 SK Telecom Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import UIKit
import WebKit

final public class NuguServiceWebView: WKWebView {
    
    public static let serviceSettingUrl = "https://webview.sktnugu.com/3pp/main.html?screenCode=setting_webview"
    public static let agreementUrl = "https://webview.sktnugu.com/3pp/agreement/list.html"
    
    private static let domain = "https://webview.sktnugu.com"
    
    private enum MethodType: String, CaseIterable {
        case openExternalApp
        case openInAppBrowser
        case closeWindow
    }
    
    // MARK: Member Variables
    
    public weak var javascriptDelegate: NuguServiceWebJavascriptDelegate?
    private let scriptMessageName = "NuguWebCommonHandler"
    
    // MARK: Initialize
    
    required init?(coder: NSCoder) {
        let webViewConfiguration = WKWebViewConfiguration()

        //UserController
        let userContentController = WKUserContentController()
        
        //Preference
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = true
        
        webViewConfiguration.preferences = preferences
        webViewConfiguration.userContentController = userContentController
        
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]),
                         modifiedSince: Date(timeIntervalSince1970: 0),
                         completionHandler: {})
        webViewConfiguration.websiteDataStore = store
        
        super.init(frame: .zero, configuration: webViewConfiguration)
        translatesAutoresizingMaskIntoConstraints = false
        
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: scriptMessageName)
    }
    
    deinit {
        configuration.userContentController.removeScriptMessageHandler(forName: scriptMessageName)
    }
}

// MARK: - WKScriptMessageHandler

extension NuguServiceWebView: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        log.debug(message)        
        guard let jsonDictionary = (message.body as? [String: Any]),
            let methodName = jsonDictionary["method"] as? String,
            let body = jsonDictionary["body"],
            let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []),
            let methodType = MethodType(rawValue: methodName) else { return }
        
        switch methodType {
        case .openExternalApp:
            guard let openExternalAppItem = try? JSONDecoder().decode(WebOpenExternalApp.self, from: bodyData) else { return }
            javascriptDelegate?.openExternalApp(openExternalAppItem: openExternalAppItem)
        case .openInAppBrowser:
            guard let jsonObject = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: AnyHashable],
                let url = jsonObject["url"] as? String else { return }
            javascriptDelegate?.openInAppBrowser(url: url)
        case .closeWindow:
            guard let jsonObject = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: AnyHashable],
                let reason = jsonObject["reason"] as? String else { return }
            javascriptDelegate?.closeWindow(reason: reason)
        }
    }
}

// MARK: - Cookie Setting

public extension NuguServiceWebView {
    func setNuguServiceCookie(nuguServiceCookie: NuguServiceCookie) {
        guard let encodedCookie = try? JSONEncoder().encode(nuguServiceCookie),
            let cookieAsDictionary = (try? JSONSerialization.jsonObject(with: encodedCookie, options: [])) as? [String: Any] else { return }
        
        log.debug(cookieAsDictionary)
        
        let script = cookieAsDictionary
            .map { (element) -> HTTPCookie? in
                let cookieProperties = [
                    HTTPCookiePropertyKey.name: element.key,
                    HTTPCookiePropertyKey.value: element.value,
                    HTTPCookiePropertyKey.domain: NuguServiceWebView.domain,
                    HTTPCookiePropertyKey.path: "/"
                ]
                return HTTPCookie(properties: cookieProperties)
        }
        .compactMap({ $0 })
        .stringValue
        
        let cookieScript = WKUserScript(source: script,
                                        injectionTime: .atDocumentStart,
                                        forMainFrameOnly: false)
        configuration.userContentController.addUserScript(cookieScript)
    }
}

// MARK: - URL Request

public extension NuguServiceWebView {
    func loadUrlString(_ urlString: String?, with queries: [URLQueryItem]? = nil) {
        guard let urlString = urlString,
        let url = URL(string: urlString) else { return }
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let queries = queries, queries.count > 0 {
            if urlComponents?.queryItems == nil {
                urlComponents?.queryItems = queries
            } else {
                urlComponents?.queryItems?.append(contentsOf: queries)
            }
        }
        guard let urlWithQueries = urlComponents?.url else { return }
        let urlRequest = URLRequest(url: urlWithQueries,
                                    cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 30)
        load(urlRequest)
    }
}
