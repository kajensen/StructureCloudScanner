//
//	Extensions for Swift port of the Structure SDK sample app "Scanner".
//	Copyright © 2016 Christopher Worley. All rights reserved.
//
//  Scan+Util.swift
//
//  Ported by Christopher Worley on 8/20/16.
//  Modified by Kurt Jensen on 2/15/17.
//

import ImageIO
import SceneKit
import SceneKit.ModelIO

extension Timer {
	class func schedule(_ delay: TimeInterval, handler: @escaping (CFRunLoopTimer?) -> Void) -> Timer {
		let fireDate = delay + CFAbsoluteTimeGetCurrent()
		let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireDate, 0, 0, 0, handler)
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, CFRunLoopMode.commonModes)
		return timer!
	}
}

public extension Float {
	public static let epsilon: Float = 1e-8
	func nearlyEqual(_ b: Float) -> Bool {
		return abs(self - b) < Float.epsilon
	}
}

class Export {
    
    class var baseURL: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    class func saveOBJ(_ name: String, data: STMesh) -> URL? {
        guard let url = baseURL?.appendingPathComponent(name) else { return nil }
        let options: [AnyHashable: Any] = [kSTMeshWriteOptionFileFormatKey: STMeshWriteOptionFileFormat.objFile.rawValue]
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(atPath: url.path)
        }
        do {
            try data.write(toFile: url.path, options: options)
            return URL(fileURLWithPath: url.path)
        } catch {
            return nil
        }
    }
    
    class func saveSTL(_ name: String, _ scale: Float?, objURL: URL, completion: @escaping (_ stlURL: URL, _ scaledStlURL: URL?) -> Void) {
        guard name.components(separatedBy: ".").last == "stl" else {
            return
        }
        if let stlURL = Export.baseURL?.appendingPathComponent(name) {
            let asset = MDLAsset(url: objURL)
            try? asset.export(to: stlURL)
            if let scale = scale {
                let scene = SCNScene(mdlAsset: asset)
                scene.rootNode.scale = SCNVector3Make(scale, scale, scale)
                if let stlScaledURL = Export.baseURL?.appendingPathComponent("scaled_"+name) {
                    scene.write(to: stlScaledURL, options: [:], delegate: nil, progressHandler: { (progress, error, stop) in
                        let string = "\(progress), \(error))"
                        NSLog("%@", string)
                        if progress >= 1 {
                            completion(stlURL, stlScaledURL)
                        }
                    })
                }
            } else {
                completion(stlURL, nil)
            }
        }
    }
    
}

