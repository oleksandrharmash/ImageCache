//
//  ImageCache.swift
//
//  Created by Oleksandr Harmash
//  Copyright © Oleksandr Harmash. All rights reserved.
//

import UIKit

typealias ImageFetchingCompletion = (_ image: UIImage?) -> ()

//Large photos, stored in disk, lead to lags at CollectionView
//ImageCache created for avoid those lags

class ImageCache {
    static let shared = ImageCache()

    //MARK: - Properties
    private let cachingQueue = DispatchQueue(label: bundleID + ".imageCachingQueue",
                                             qos: .utility,
                                             attributes: .concurrent,
                                             autoreleaseFrequency:.workItem)

    private let isolationQueue = DispatchQueue(label: bundleID + ".imageIsolationQueue",
                                             qos: .userInitiated,
                                             attributes: .concurrent,
                                             autoreleaseFrequency:.workItem)
    //Hadle memory warnings
    private let memoryWarningsSource = DispatchSource.makeMemoryPressureSource(eventMask: DispatchSource.MemoryPressureEvent.warning,
                                                                               queue: DispatchQueue.main)
    
    private lazy var cache: NSCache<NSString, AnyObject> = {
        let cache = NSCache<NSString, AnyObject>()
        cache.totalCostLimit = 50
        return cache
    }()
    
    private lazy var cachedCompletions: [String: [ImageFetchingCompletion?]? ] = {
        return [String: [ImageFetchingCompletion?]? ]()
    }()

    init() {
        memoryWarningsSource.setEventHandler { [weak self] in
            self?.cache.removeAllObjects()
        }
        memoryWarningsSource.resume()
    }
    
    //MARK: - Public
    func imageAt(path imagePath: String, completion: @escaping ImageFetchingCompletion)  {
        cachingQueue.async {
            let NSKey = NSString(string: imagePath)
            
            switch self.cachedObjectForKey(NSKey) {
            case let value as UIImage:
                completion(value)
                break
                
            case _ as Bool:
                var completions = self.cachedCompletions[imagePath] ?? []
                completions?.append(completion)
                self.cachedCompletions[imagePath] = completions
                break
                
            default:
                
                self.setObject(true as AnyObject, forKey: NSKey, cost: 0)
                
                guard let image = self.loadImageAtPath(imagePath) else {
                    self.removeObjectForKey(NSKey)
                    completion(nil)
                    return
                }
                
                self.setObject(image, forKey: NSKey, cost: 1)
                
                if let completions = self.cachedCompletions[imagePath] {
                    for completion in completions! {
                        completion?(image)
                    }
                    self.cachedCompletions.removeValue(forKey: imagePath)
                }
                completion(image)
            }
        }
    }

    func removeImageWithPath(_ path: String) {
        removeObjectForKey(NSString.init(string: path))
    }
}

private extension ImageCache {
    func setObject(_ object: AnyObject, forKey key: NSString, cost: Int) {
        isolationQueue.async(flags: .barrier) {
            self.cache.setObject(object, forKey: key, cost: cost)
        }
    }
    
    func cachedObjectForKey(_ key: NSString) -> AnyObject? {
        var res: AnyObject? = nil
        isolationQueue.sync {
            res = cache.object(forKey: key)
        }
        return res
    }
    
    func removeObjectForKey(_ key: NSString) {
        isolationQueue.async(flags: .barrier) {
            self.cache.removeObject(forKey: key)
        }
    }
    
    func loadImageAtPath(_ path: String) -> UIImage? {
        if FileManager.default.fileExists(atPath: path) {
            return UIImage.forceLoadFrom(path: path)
        }
        
        return UIImage(contentsOfFile: path)?.forceLoad()
    }

}

private extension UIImage {
    
    static func forceLoadFrom(path: String) -> UIImage? {
        
        let url = URL.init(fileURLWithPath: path)
       
        guard let provider = CGDataProvider.init(url: url as CFURL) else { return nil }
        
        if url.pathExtension == "png" {
            return CGImage(pngDataProviderSource: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent)?.forceLoadToUIImage()
        }
        
        return CGImage(jpegDataProviderSource: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)?.forceLoadToUIImage()
    }
    
   func forceLoad() -> UIImage? {
        return cgImage?.forceLoadToUIImage()
    }
}

private extension CGImage {
    func forceLoadToUIImage() -> UIImage? {
        guard colorSpace != nil,
            let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
        
        context.draw(self, in: CGRect.init(x: 0, y: 0,
                                           width: CGFloat(width),
                                           height: CGFloat(height)))
        
        guard let decompressedRef = context.makeImage() else { return nil }
        
        return UIImage.init(cgImage: decompressedRef)
    }
}

extension UIImageView {
    private struct AssociatedKeys {
        static var imagePath: UInt8 = 0
    }
    
    private var cachedImagePath: AnyObject? {
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.imagePath, newValue, .OBJC_ASSOCIATION_COPY)
        }
        get  {
            return objc_getAssociatedObject(self, &AssociatedKeys.imagePath) as AnyObject?
        }
    }
    
    func setCachedImageWithPath(_ path: String) {
        cachedImagePath = path as AnyObject
        ImageCache.shared.imageAt(path: path) { [weak self] (image) in
            guard path == self?.cachedImagePath as? String else { return }
            DispatchQueue.main.async {
                self?.image = image
            }
            self?.cachedImagePath = nil
        }
    }
}
