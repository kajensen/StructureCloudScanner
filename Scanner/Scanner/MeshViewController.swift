//
//	This file is a Swift port of the Structure SDK sample app "Scanner".
//	Copyright © 2016 Occipital, Inc. All rights reserved.
//	http://structure.io
//
//  MeshViewController.swift
//
//  Ported by Christopher Worley on 8/20/16.
//  Modified by Kurt Jensen on 2/15/17.
//

import MessageUI
import ImageIO

protocol MeshViewControllerDelegate: class {
    
    func meshViewControllerWillDismiss()
    func meshViewControllerDidDismiss()
    func meshViewControllerDidRequestColorizing(_ mesh: STMesh,  previewCompletionHandler: @escaping () -> Void, enhancedCompletionHandler: @escaping () -> Void) -> Bool
    func meshViewControllerDidRequestHoleFilling(_ mesh: STMesh,  previewCompletionHandler: @escaping () -> Void, enhancedCompletionHandler: @escaping () -> Void) -> Bool
    func meshViewControllerDidExport(_ objURL: URL, stlURL: URL, scaledStlURL: URL?)
    
}

open class MeshViewController: UIViewController, UIGestureRecognizerDelegate {
    
    weak var delegate: MeshViewControllerDelegate?
    
    // force the view to redraw.
    var needsDisplay: Bool = false
    var colorEnabled: Bool = false
    
    fileprivate var _mesh: STMesh? = nil
    var mesh: STMesh? {
        get {
            return _mesh
        }
        set {
            _mesh = newValue
            if _mesh != nil {
                self.renderer!.uploadMesh(_mesh!)
                self.trySwitchToColorRenderingMode()
                self.needsDisplay = true
            }
        }
    }
    
    fileprivate var _holeFilledMesh: STMesh? = nil
    var holeFilledMesh: STMesh? {
        get {
            return _holeFilledMesh
        }
        set {
            if _holeFilledMesh == nil && _holeFilledMesh != newValue {
                _holeFilledMesh = newValue
                mesh = _holeFilledMesh
            }
        }
    }
    
    var projectionMatrix: GLKMatrix4 = GLKMatrix4Identity {
        didSet {
            setCameraProjectionMatrix(projectionMatrix)
        }
    }
    
    var volumeCenter = GLKVector3Make(0,0,0) {
        didSet {
            resetMeshCenter(volumeCenter)
        }
    }
    
    @IBOutlet weak var eview: EAGLView!
    @IBOutlet weak var displayControl: UISegmentedControl!
    @IBOutlet weak var meshViewerMessageLabel: UILabel!
    
    var displayLink: CADisplayLink?
    var renderer: MeshRenderer!
    var viewpointController: ViewpointController!
    var viewport = [GLfloat](repeating: 0, count: 4)
    var modelViewMatrixBeforeUserInteractions: GLKMatrix4?
    var projectionMatrixBeforeUserInteractions: GLKMatrix4?
    
    var mailViewController: MFMailComposeViewController?
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        renderer = MeshRenderer.init()
        viewpointController = ViewpointController.init(screenSizeX: Float(self.view.frame.size.width), screenSizeY: Float(self.view.frame.size.height))
        let font = UIFont.boldSystemFont(ofSize: 14)
        let attributes: [AnyHashable: Any] = [NSFontAttributeName : font]
        displayControl.setTitleTextAttributes(attributes, for: UIControlState())
        renderer.setRenderingMode(.lightedGray)
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if displayLink != nil {
            displayLink!.invalidate()
            displayLink = nil
        }
        displayLink = CADisplayLink(target: self, selector: #selector(MeshViewController.draw))
        displayLink!.add(to: RunLoop.main, forMode: RunLoopMode.commonModes)
        viewpointController.reset()
        if !colorEnabled {
            displayControl.removeSegment(at: 2, animated: false)
        }
    }
    
    // Make sure the status bar is disabled (iOS 7+)
    override open var prefersStatusBarHidden : Bool {
        return true
    }
    
    override open func didReceiveMemoryWarning () {
    }
    
    func setupGL (_ context: EAGLContext) {
        (self.view as! EAGLView).context = context
        EAGLContext.setCurrent(context)
        renderer.initializeGL( GLenum(GL_TEXTURE3))
        self.eview.setFramebuffer()
        let framebufferSize: CGSize = self.eview.getFramebufferSize()
        // The iPad's diplay conveniently has a 4:3 aspect ratio just like our video feed.
        // Some iOS devices need to render to only a portion of the screen so that we don't distort
        // our RGB image. Alternatively, you could enlarge the viewport (losing visual information),
        // but fill the whole screen.
        // if you want to keep aspect ratio
        //		var imageAspectRatio: CGFloat = 1
        //
        //        if abs(framebufferSize.width / framebufferSize.height - 640.0 / 480.0) > 1e-3 {
        //            imageAspectRatio = 480.0 / 640.0
        //        }
        //
        //        viewport[0] = Float(framebufferSize.width - framebufferSize.width * imageAspectRatio) / 2
        //        viewport[1] = 0
        //        viewport[2] = Float(framebufferSize.width * imageAspectRatio)
        //        viewport[3] = Float(framebufferSize.height)
        // if you want full screen
        viewport[0] = 0
        viewport[1] = 0
        viewport[2] = Float(framebufferSize.width)
        viewport[3] = Float(framebufferSize.height)
    }
    
    @IBAction func dismissView(_ sender: AnyObject) {
        holeFilledMesh = nil
        _holeFilledMesh = nil
        displayControl.selectedSegmentIndex = 1
        renderer.setRenderingMode(.lightedGray)
        delegate?.meshViewControllerWillDismiss()
        renderer.releaseGLBuffers()
        renderer.releaseGLTextures()
        displayLink!.invalidate()
        displayLink = nil
        mesh = nil
        self.eview.context = nil
        dismiss(animated: true, completion: {
            self.delegate?.meshViewControllerDidDismiss()
        })
    }
    
    //MARK: - MeshViewer setup when loading the mesh
    
    func setCameraProjectionMatrix (_ projection: GLKMatrix4) {
        viewpointController.setCameraProjection(projection)
        projectionMatrixBeforeUserInteractions = projection
    }
    
    func resetMeshCenter (_ center: GLKVector3) {
        viewpointController.reset()
        viewpointController.setMeshCenter(center)
        modelViewMatrixBeforeUserInteractions = viewpointController.currentGLModelViewMatrix()
    }
    
    func saveJpegFromRGBABuffer( _ filename: String, src_buffer: UnsafeMutableRawPointer, width: Int, height: Int) {
        let file: UnsafeMutablePointer<FILE>? = fopen(filename, "w")
        if file == nil {
            return
        }
        var colorSpace: CGColorSpace?
        var alphaInfo: CGImageAlphaInfo!
        var bmcontext: CGContext?
        colorSpace = CGColorSpaceCreateDeviceRGB()
        alphaInfo = .noneSkipLast
        bmcontext = CGContext(data: src_buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace!, bitmapInfo: alphaInfo.rawValue)!
        var rgbImage: CGImage? = bmcontext!.makeImage()
        bmcontext = nil
        colorSpace = nil
        var jpgData: CFMutableData? = CFDataCreateMutable(nil, 0)
        var imageDest: CGImageDestination? = CGImageDestinationCreateWithData(jpgData!, "public.jpeg" as CFString, 1, nil)
        var kcb = kCFTypeDictionaryKeyCallBacks
        var vcb = kCFTypeDictionaryValueCallBacks
        // Our empty IOSurface properties dictionary
        var options: CFDictionary? = CFDictionaryCreate(kCFAllocatorDefault, nil, nil, 0, &kcb, &vcb)
        CGImageDestinationAddImage(imageDest!, rgbImage!, options!)
        CGImageDestinationFinalize(imageDest!)
        imageDest = nil
        rgbImage = nil
        options = nil
        fwrite(CFDataGetBytePtr(jpgData!), 1, CFDataGetLength(jpgData!), file!)
        fclose(file!)
        jpgData = nil
    }
    
    @IBAction func exportMesh(_ sender: AnyObject) {
        guard let meshToSend = mesh else {
            let alert = UIAlertController.init(title: "Error", message: "Exporting the mesh failed", preferredStyle: .alert)
            let defaultAction = UIAlertAction.init(title: "OK", style: .default, handler: nil)
            alert.addAction(defaultAction)
            present(alert, animated: true, completion: nil)
            return
        }
        if let objURL = Export.saveOBJ("export.obj", data: meshToSend) {
            Export.saveSTL("export.stl", 1000, objURL: objURL, completion: { (originalURL, scaledURL) in
                self.delegate?.meshViewControllerDidExport(objURL, stlURL: originalURL, scaledStlURL: scaledURL)
                self.dismissView(sender)
            })
        }
    }

    //MARK: Rendering
    
    func draw () {
        self.eview.setFramebuffer()
        glViewport(GLint(viewport[0]), GLint(viewport[1]), GLint(viewport[2]), GLint(viewport[3]))
        let viewpointChanged = viewpointController.update()
        // If nothing changed, do not waste time and resources rendering.
        if !needsDisplay && !viewpointChanged {
            return
        }
        var currentModelView = viewpointController.currentGLModelViewMatrix()
        var currentProjection = viewpointController.currentGLProjectionMatrix()
        renderer!.clear()
        withUnsafePointer(to: &currentProjection) { (one) -> () in
            withUnsafePointer(to: &currentModelView, { (two) -> () in
                        one.withMemoryRebound(to: GLfloat.self, capacity: 16, { (onePtr) -> () in
                    two.withMemoryRebound(to: GLfloat.self, capacity: 16, { (twoPtr) -> () in
                                        renderer!.render(onePtr,modelViewMatrix: twoPtr)
                    })
                })
            })
        }
        needsDisplay = false
        let _ = self.eview.presentFramebuffer()
    }
    
    //MARK: Touch & Gesture Control
    
    @IBAction func tapStopGesture(_ sender: UITapGestureRecognizer) {
    }
    
    @IBAction func tapGesture(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            viewpointController.onTouchBegan()
        }
    }
    
    @IBAction func pinchScaleGesture(_ sender: UIPinchGestureRecognizer) {
        // Forward to the ViewpointController.
        if sender.state == .began {
            viewpointController.onPinchGestureBegan(Float(sender.scale))
        }
        else if sender.state == .changed {
            viewpointController.onPinchGestureChanged(Float(sender.scale))
        }
    }
    
    @IBAction func oneFingerPanGesture(_ sender: UIPanGestureRecognizer) {
        let touchPos = sender.location(in: view)
        let touchVel = sender.velocity(in: view)
        let touchPosVec = GLKVector2Make(Float(touchPos.x), Float(touchPos.y))
        let touchVelVec = GLKVector2Make(Float(touchVel.x), Float(touchVel.y))
        if sender.state == .began {
            viewpointController.onOneFingerPanBegan(touchPosVec)
        }
        else if sender.state == .changed {
            viewpointController.onOneFingerPanChanged(touchPosVec)
        }
        else if sender.state == .ended {
            viewpointController.onOneFingerPanEnded(touchVelVec)
        }
    }
    
    @IBAction func twoFingersPanGesture(_ sender: AnyObject) {
        if sender.numberOfTouches != 2 {
            return
        }
        let touchPos = sender.location(in: view)
        let touchVel = sender.velocity(in: view)
        let touchPosVec = GLKVector2Make(Float(touchPos.x), Float(touchPos.y))
        let touchVelVec = GLKVector2Make(Float(touchVel.x), Float(touchVel.y))
        if sender.state == .began {
            viewpointController.onTwoFingersPanBegan(touchPosVec)
        }
        else if sender.state == .changed {
            viewpointController.onTwoFingersPanChanged(touchPosVec)
        }
        else if sender.state == .ended {
            viewpointController.onTwoFingersPanEnded(touchVelVec)
        }
    }
    
    //MARK: UI Control
    
    func trySwitchToColorRenderingMode() {
        // Choose the best available color render mode, falling back to LightedGray
        // This method may be called when colorize operations complete, and will
        // switch the render mode to color, as long as the user has not changed
        // the selector.
        if displayControl.selectedSegmentIndex == 2 {
            if	mesh!.hasPerVertexUVTextureCoords() {
                renderer.setRenderingMode(.textured)
            } else if mesh!.hasPerVertexColors() {
                renderer.setRenderingMode(.perVertexColor)
            } else {
                renderer.setRenderingMode(.lightedGray)
            }
        }
        else if displayControl.selectedSegmentIndex == 3 {
            if	mesh!.hasPerVertexUVTextureCoords() {
                renderer.setRenderingMode(.textured)
            } else if mesh!.hasPerVertexColors() {
                renderer.setRenderingMode(.perVertexColor)
            } else {
                renderer.setRenderingMode(.lightedGray)
            }
        }
    }
    
    @IBAction func displayControlChanged(_ sender: AnyObject) {
        switch displayControl.selectedSegmentIndex {
        case 0: // x-ray
                renderer.setRenderingMode(.xRay)
            case 1: // lighted-gray
                renderer.setRenderingMode(.lightedGray)
            case 2: // color
                trySwitchToColorRenderingMode()
                let meshIsColorized: Bool = mesh!.hasPerVertexColors() || mesh!.hasPerVertexUVTextureCoords()
                if !meshIsColorized {
                        colorizeMesh()
            }
            case 3: // hole fill
                trySwitchToColorRenderingMode()
                if holeFilledMesh == nil {
                fillMesh()
            }
            default:
            break
        }
        needsDisplay = true
    }
    
    func colorizeMesh() {
        let _ = delegate?.meshViewControllerDidRequestColorizing(self.mesh!, previewCompletionHandler: {
        }, enhancedCompletionHandler: {
                // Hide progress bar.
            self.hideMeshViewerMessage()
        })
    }
    
    func fillMesh() {
        let _ = delegate?.meshViewControllerDidRequestHoleFilling(self.mesh!, previewCompletionHandler: {
        }, enhancedCompletionHandler: {
            // Hide progress bar.
            self.hideMeshViewerMessage()
        })
    }
    
    func hideMeshViewerMessage() {
        UIView.animate(withDuration: 0.5, animations: {
            self.meshViewerMessageLabel.alpha = 0.0
        }, completion: { _ in
            self.meshViewerMessageLabel.isHidden = true
        })
    }
    
    func showMeshViewerMessage(_ msg: String) {
        meshViewerMessageLabel.text = msg
        if meshViewerMessageLabel.isHidden == true {
                meshViewerMessageLabel.alpha = 0.0
            meshViewerMessageLabel.isHidden = false
                UIView.animate(withDuration: 0.5, animations: {
                self.meshViewerMessageLabel.alpha = 1.0
            })
        }
    }
}
