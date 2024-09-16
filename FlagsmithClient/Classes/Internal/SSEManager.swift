//
//  SSEManager.swift
//  FlagsmithClient
//
//  Created by Gareth Reese on 13/09/2024.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Handles interaction with the Flagsmith SSE real-time API.
final class SSEManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var _session: URLSession!
    private var session: URLSession {
        get {
            propertiesSerialAccessQueue.sync { _session }
        }
        set {
            propertiesSerialAccessQueue.sync(flags: .barrier) {
                _session = newValue
            }
        }
    }
    
    private var _dataTask: URLSessionDataTask?
    private var dataTask: URLSessionDataTask? {
        get {
            propertiesSerialAccessQueue.sync { _dataTask }
        }
        set {
            propertiesSerialAccessQueue.sync(flags: .barrier) {
                _dataTask = newValue
            }
        }
    }
    
    // private var streamTask: Task<Void, Error>? = nil
    
    /// Base `URL` used for requests.
    private var _baseURL = URL(string: "https://realtime.flagsmith.com/")!
    var baseURL: URL {
        get {
            propertiesSerialAccessQueue.sync { _baseURL }
        }
        set {
            propertiesSerialAccessQueue.sync {
                _baseURL = newValue
            }
        }
    }
    
    /// API Key unique to an organization.
    private var _apiKey: String?
    var apiKey: String? {
        get {
            propertiesSerialAccessQueue.sync { _apiKey }
        }
        set {
            propertiesSerialAccessQueue.sync {
                _apiKey = newValue
            }
        }
    }
    
    var isStarted: Bool {
        return completionHandler != nil
    }
    
    private var completionHandler: CompletionHandler<FlagEvent>?
    private let serialAccessQueue = DispatchQueue(label: "sseFlagsmithSerialAccessQueue", qos: .default)
    let propertiesSerialAccessQueue = DispatchQueue(label: "ssePropertiesSerialAccessQueue", qos: .default)
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }
    
    // Helper function to process SSE data
    private func processSSEData(_ data: String) {
        // Parse and handle SSE events here
        print("Received SSE data: \(data)")
        
        // Split the data into lines and decode the 'data:' lines from JSON into FlagEvent objects
        let lines = data.components(separatedBy: "\n")
        for line in lines where line.hasPrefix("data:") {
            let json = line.replacingOccurrences(of: "data:", with: "")
            if let jsonData = json.data(using: .utf8) {
                do {
                    let flagEvent = try JSONDecoder().decode(FlagEvent.self, from: jsonData)
                    completionHandler?(.success(flagEvent))
                } catch {
                    if let error = error as? DecodingError {
                        completionHandler?(.failure(FlagsmithError.decoding(error)))
                    } else {
                        completionHandler?(.failure(FlagsmithError.unhandled(error)))
                    }
                }
            }
        }
    }
    
    // MARK: URLSessionDelegate
    
    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        serialAccessQueue.sync {
            // Print what's going on
            print("SSE received data: \(data)")
            // This is where we need to handle the data
            if let message = String(data: data, encoding: .utf8) {
                processSSEData(message)
            }
        }
    }
    
    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        serialAccessQueue.sync {
            if task != dataTask {
                return
            }
            
            if let error = error {
                if let error = error as? URLError, error.code == .cancelled || error.code == .timedOut {
                    // Reconnect to the SSE, the connection will have been dropped
                    if let completionHandler = completionHandler {
                        // Reconnect to the SSE, the connection will have been dropped
                        start(completion: completionHandler)
                    }
                }
            } else if let completionHandler = completionHandler {
                // Reconnect to the SSE, the connection will have been dropped
                start(completion: completionHandler)
            }
        }
    }
    
    // MARK: Public Methods
    
    func start(completion: @escaping CompletionHandler<FlagEvent>) {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion(.failure(FlagsmithError.apiKey))
            return
        }
        
        guard let completeEventSourceUrl = URL(string: "\(baseURL)sse/environments/\(apiKey)/stream") else {
            completion(.failure(FlagsmithError.apiURL("Invalid event source URL")))
            return
        }
        
        var request = URLRequest(url: completeEventSourceUrl)
        request.setValue("text/event-stream, application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        completionHandler = completion
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    func stop() {
        dataTask?.cancel()
        completionHandler = nil
    }
}
