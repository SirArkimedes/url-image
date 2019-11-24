//
//  DownloadService.swift
//  
//
//  Created by Dmytro Anokhin on 21/11/2019.
//

import Foundation


@available(iOS 13.0, tvOS 13.0, macOS 10.15, watchOS 6.0, *)
protocol DownloadService: AnyObject {

    func add(_ handler: DownloadHandler, forURLRequest urlRequest: URLRequest)

    func remove(_ handler: DownloadHandler, fromURLRequest urlRequest: URLRequest)

    func load(urlRequest: URLRequest, after delay: TimeInterval, expiryDate: Date?)
}


@available(iOS 13.0, tvOS 13.0, macOS 10.15, watchOS 6.0, *)
final class DownloadServiceImpl: DownloadService {

    init(remoteFileCache: RemoteFileCacheService) {
        let urlSessionConfiguration = URLSessionConfiguration.default.copy() as! URLSessionConfiguration
        urlSessionConfiguration.httpMaximumConnectionsPerHost = 1

        urlSessionDelegate = URLSessionDelegateWrapper()
        urlSession = URLSession(configuration: urlSessionConfiguration, delegate: urlSessionDelegate, delegateQueue: queue)

        self.remoteFileCache = remoteFileCache

        func downloaderForTask(_ task: URLSessionTask) -> DownloadCoordinator? {
            guard let urlRequest = task.originalRequest else {
                return nil
            }

            return urlRequestToDownloaderMap[urlRequest]
        }

        urlSessionDelegate.finishDownloadingCallback = { task, tmpURL in
            guard let downloader = downloaderForTask(task) as? FileDownloadCoordinator else {
                return
            }

            downloader.finishDownloading(with: tmpURL)
        }

        urlSessionDelegate.writeDataCallback = { task, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
            guard let downloader = downloaderForTask(task) as? FileDownloadCoordinator else {
                return
            }

            if totalBytesExpectedToWrite > 0 {
                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                downloader.progress(Float(progress))
            }
            else {
                downloader.progress(nil)
            }
        }

        urlSessionDelegate.receiveDataCallback = { task, data in
            guard let downloader = downloaderForTask(task) as? DataDownloadCoordinator else {
                return
            }

            downloader.append(data: data)
        }

        urlSessionDelegate.completeCallback = { task, error in
            guard let downloader = downloaderForTask(task) else {
                return
            }

            (downloader as? DataDownloadCoordinator)?.finishDownloading()
            downloader.complete(with: error)
        }
    }

    func add(_ handler: DownloadHandler, forURLRequest urlRequest: URLRequest) {
        queue.addOperation {
            let downloader: DownloadCoordinator

            if let existingDownloader = self.urlRequestToDownloaderMap[urlRequest] {
                downloader = existingDownloader
            }
            else {
                downloader = self.createDownloader(forURLRequest: urlRequest, inMemory: handler.inMemory)

                downloader.completionCallback = {
                    self.queue.addOperation {
                        self.urlRequestToDownloaderMap.removeValue(forKey: urlRequest)
                    }
                }

                self.urlRequestToDownloaderMap[urlRequest] = downloader
            }

            downloader.addHandler(handler)
        }
    }

    func remove(_ handler: DownloadHandler, fromURLRequest urlRequest: URLRequest) {
        queue.addOperation {
            guard let downloader = self.urlRequestToDownloaderMap[urlRequest] else {
                return
            }

            let handlersToRemove = downloader.handlers.filter { $0 === handler }

            for handler in handlersToRemove {
                downloader.removeHandler(handler)
            }

            if downloader.handlers.isEmpty {
                self.urlRequestToDownloaderMap[urlRequest]?.cancel()
            }
        }
    }

    func load(urlRequest: URLRequest, after delay: TimeInterval, expiryDate: Date?) {
        queue.addOperation {
            guard let downloader = self.urlRequestToDownloaderMap[urlRequest] else {
                assertionFailure("Downloader must be created before calling load")
                return
            }

            if let expiryDate = expiryDate {
                if let currentExpiryDate = downloader.expiryDate {
                    // If there is expiry date make sure to use the latest of two
                    downloader.expiryDate = currentExpiryDate < expiryDate ? expiryDate : currentExpiryDate
                }
                else {
                    downloader.expiryDate = expiryDate
                }
            }

            downloader.resume(after: delay)
        }
    }

    // MARK: Private

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "URLImage.DownloadServiceImpl.queue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    private let urlSession: URLSession
    private let urlSessionDelegate: URLSessionDelegateWrapper

    private unowned let remoteFileCache: RemoteFileCacheService

    private var _urlRequestToDownloaderMap: [URLRequest: DownloadCoordinator] = [:]

    private var urlRequestToDownloaderMap: [URLRequest: DownloadCoordinator] {
        get {
            assert(OperationQueue.current === queue, "Must only be accessed on the designated queue: '\(queue.name!)'")
            return _urlRequestToDownloaderMap
        }

        set {
            assert(OperationQueue.current === queue, "Must only be accessed on the designated queue: '\(queue.name!)'")
            _urlRequestToDownloaderMap = newValue
        }
    }

    private func createDownloader(forURLRequest urlRequest: URLRequest, inMemory: Bool) -> DownloadCoordinator {
        let downloader: DownloadCoordinator

        if inMemory {
            let task = urlSession.dataTask(with: urlRequest)
            downloader = DataDownloadCoordinator(url: urlRequest.url!, task: task, remoteFileCache: remoteFileCache)
        }
        else {
            let task = urlSession.downloadTask(with: urlRequest)
            downloader = FileDownloadCoordinator(url: urlRequest.url!, task: task, remoteFileCache: remoteFileCache)
        }

        return downloader
    }
}

