//
//	This file is a Swift port of the Structure SDK sample app "Scanner".
//	Copyright © 2016 Occipital, Inc. All rights reserved.
//	http://structure.io
//
//  ScanViewController.swift
//
//  Ported by Christopher Worley on 8/20/16.
//  Modified by Kurt Jensen on 2/15/17.
//

import Foundation
import UIKit

protocol ScanViewControllerDelegate: class {
    func scanViewControllerDidExport(_ objURL: URL, stlURL: URL, scaledStlURL: URL?)
}

class ScanViewController: UIViewController, STBackgroundTaskDelegate, UIGestureRecognizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
	
    @IBOutlet weak var eview: EAGLView!

	@IBOutlet weak var enableNewTrackerSwitch: UISwitch!
	@IBOutlet weak var enableHighResolutionColorSwitch: UISwitch!
	@IBOutlet weak var enableNewMapperSwitch: UISwitch!
	@IBOutlet weak var enableHighResMappingSwitch: UISwitch!
	@IBOutlet weak var appStatusMessageLabel: UILabel!
	@IBOutlet weak var scanButton: UIButton!
	@IBOutlet weak var resetButton: UIButton!
	@IBOutlet weak var doneButton: UIButton!
	@IBOutlet weak var trackingLostLabel: UILabel!
	@IBOutlet weak var enableNewTrackerView: UIView!
    @IBOutlet weak var instructionOverlay: UIView!
    @IBOutlet weak var calibrationOverlay: UIView!
    
    weak var delegate: ScanViewControllerDelegate?

	// Structure Sensor controller.
	var _sensorController: STSensorController!
	var _structureStreamConfig: STStreamConfig!
	var _slamState = SlamData()
	var _options = Options()
	var _dynamicOptions: DynamicOptions!
	// Manages the app status messages.
	var _appStatus = AppStatus()
	var _display: DisplayData? = DisplayData()
	// Most recent gravity vector from IMU.
	var _lastGravity: GLKVector3!
	// Scale of the scanning volume.
	var _volumeScale = PinchScaleState()
	// Mesh viewer controllers.
	var meshViewController: MeshViewController!
	// IMU handling.
	var _motionManager: CMMotionManager? = nil
	var _imuQueue: OperationQueue? = nil
//	var _holeFilledMesh: STMesh? = nil
	var _naiveColorizeTask: STBackgroundTask? = nil
	var _enhancedColorizeTask: STBackgroundTask? = nil
	var _holeFillingTask: STBackgroundTask? = nil
	var _depthAsRgbaVisualizer: STDepthToRgba? = nil
	var _useColorCamera = true
    var trackerShowingScanStart = false
	var avCaptureSession: AVCaptureSession? = nil
	var videoDevice: AVCaptureDevice? = nil
    var hasLaunched = false

	deinit {
		avCaptureSession!.stopRunning()
		if EAGLContext.current() == _display!.context {
			EAGLContext.setCurrent(nil)
		}
		unregisterNotificationHandlers()
	}
	
	func unregisterNotificationHandlers() {
		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
	}

	func registerNotificationHandlers() {
		// Make sure we get notified when the app becomes active to start/restore the sensor state if necessary.
		NotificationCenter.default.addObserver(self, selector: #selector(ScanViewController.appDidBecomeActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
	}

    override func viewDidLoad() {
        super.viewDidLoad()
        // initially hide tracker view
		enableNewTrackerView.isHidden = true
		enableNewTrackerView.alpha = 0.0
        calibrationOverlay.alpha = 0
        calibrationOverlay.isHidden = true
        instructionOverlay.alpha = 0
        instructionOverlay.isHidden = true
        // Do any additional setup after loading the view.
        _slamState.initialized = false
        _enhancedColorizeTask = nil
        _naiveColorizeTask = nil
		setupGL()
		setupUserInterface()
        meshViewController = storyboard?.instantiateViewController(withIdentifier: "MeshViewController") as! MeshViewController
		setupStructureSensor()
		setupIMU()
		// Later, we’ll set this true if we have a device-specific calibration
		_useColorCamera = STSensorController.approximateCalibrationGuaranteedForDevice()

		registerNotificationHandlers()
		
		initializeDynamicOptions()
		syncUIfromDynamicOptions()
    }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		// The framebuffer will only be really ready with its final size after the view appears.
		self.eview.setFramebuffer()

		setupGLViewport()
		updateAppStatusMessage()

        let defaults = UserDefaults.standard

         if !defaults.bool(forKey: "instructionOverlay") {

            let _ = Timer.schedule(10.0, handler: {_ in
                self.instructionOverlay.isHidden = false
                self.instructionOverlay.alpha = 1
                let _ = Timer.schedule(15.0, handler: { _ in
                    UIView.animate(withDuration: 0.3, animations: {

                        self.instructionOverlay!.alpha = 0
                        self.instructionOverlay!.isHidden = true
                    })
                })
            })
        }
		// We will connect to the sensor when we receive appDidBecomeActive.
    }

	func appDidBecomeActive() {
		if currentStateNeedsSensor() {
			let _ = connectToStructureSensorAndStartStreaming()
		}
		// Abort the current scan if we were still scanning before going into background since we
		// are not likely to recover well.
		if _slamState.scannerState == .scanning {
			resetButtonPressed(resetButton)
		}
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
        NSLog("respondToMemoryWarning")
        switch _slamState.scannerState {
        case .viewing:
            // If we are running a colorizing task, abort it
            if _enhancedColorizeTask != nil && !_slamState.showingMemoryWarning {
                _slamState.showingMemoryWarning = true
                // stop the task
                _enhancedColorizeTask!.cancel()
                _enhancedColorizeTask = nil
                // hide progress bar
                self.meshViewController.hideMeshViewerMessage()
                let alertCtrl = UIAlertController(title: "Memory Low", message: "Colorizing was canceled.", preferredStyle: .alert)
                let okAction = UIAlertAction(title: "OK", style: .default, handler: { _ in
                    self._slamState.showingMemoryWarning = false
                })
                alertCtrl.addAction(okAction)
                // show the alert in the meshViewController
                self.meshViewController.present(alertCtrl, animated: true, completion: nil)
            }
        case .scanning:
            if !_slamState.showingMemoryWarning {
                _slamState.showingMemoryWarning = true
                let alertCtrl = UIAlertController(title: "Memory Low", message: "Scanning will be stopped to avoid loss.", preferredStyle: .alert)
                let okAction = UIAlertAction(title: "OK", style: .default, handler: { _ in
                    self._slamState.showingMemoryWarning = false
                    self.enterViewingState()
                })
                alertCtrl.addAction(okAction)
                present(alertCtrl, animated: true, completion: nil)
            }
        default:
            break
        }
    }

	func initializeDynamicOptions() {
		_dynamicOptions = DynamicOptions()
		_dynamicOptions.highResColoring = videoDeviceSupportsHighResColor()
		_dynamicOptions.highResColoringSwitchEnabled = _dynamicOptions.highResColoring
	}

	func syncUIfromDynamicOptions() {
		// This method ensures the UI reflects the dynamic settings.
		enableNewTrackerSwitch.isOn = _dynamicOptions.newTrackerIsOn
		enableNewTrackerSwitch.isEnabled = _dynamicOptions.newTrackerSwitchEnabled
		enableHighResMappingSwitch.isOn = _dynamicOptions.highResMapping
		enableHighResMappingSwitch.isEnabled = _dynamicOptions.highResMappingSwitchEnabled
		enableNewMapperSwitch.isOn = _dynamicOptions.newMapperIsOn
		enableNewMapperSwitch.isEnabled = _dynamicOptions.newMapperSwitchEnabled
		enableHighResolutionColorSwitch.isOn = _dynamicOptions.highResColoring
		enableHighResolutionColorSwitch.isEnabled = _dynamicOptions.highResColoringSwitchEnabled
	}

	func setupUserInterface() {
		appStatusMessageLabel.alpha = 0
		appStatusMessageLabel.layer.zPosition = 100
	}

	override var prefersStatusBarHidden : Bool {
		return true
	}

	func presentMeshViewer(_ mesh: STMesh) {

		meshViewController.setupGL(_display!.context!)
		meshViewController.colorEnabled = _useColorCamera
		meshViewController.mesh = mesh
		meshViewController.setCameraProjectionMatrix(_display!.depthCameraGLProjectionMatrix)

		// Sample a few points to estimate the volume center
		var totalNumVertices: Int32 = 0
		for  i in 0..<mesh.numberOfMeshes() {
			totalNumVertices += mesh.number(ofMeshVertices: Int32(i))
		}

		let sampleStep = Int(max(1, totalNumVertices / 1000))
		var sampleCount: Int32 = 0
		var volumeCenter = GLKVector3Make(0, 0,0)

		for i in 0..<mesh.numberOfMeshes() {
			let numVertices = Int(mesh.number(ofMeshVertices: i))
			let vertex = mesh.meshVertices(Int32(i))

			for j in stride(from: 0, to: numVertices, by: sampleStep) {
				volumeCenter = GLKVector3Add(volumeCenter, (vertex?[Int(j)])!)
				sampleCount += 1
			}
		}

		if sampleCount > 0 {
			volumeCenter = GLKVector3DivideScalar(volumeCenter, Float(sampleCount))
		} else {
			volumeCenter = GLKVector3MultiplyScalar(_slamState.volumeSizeInMeters, 0.5)
		}

		meshViewController.resetMeshCenter(volumeCenter)
        meshViewController.delegate = self
        
        let nc = UINavigationController(rootViewController: meshViewController)
		present(nc, animated: true, completion: nil)
	}

	func enterCubePlacementState() {
		// Switch to the Scan button.
		scanButton.isHidden = false
		doneButton.isHidden = true
		resetButton.isHidden = true
		// We'll enable the button only after we get some initial pose.
		scanButton.isHidden = false
		// Cannot be lost in cube placement mode.
		trackingLostLabel.isHidden = true
		setColorCameraParametersForInit()
		_slamState.scannerState = .cubePlacement
		// Restore dynamic options UI state, as we may be coming back from scanning state, where they were all disabled.
		syncUIfromDynamicOptions()
		updateIdleTimer()
	}

	func enterScanningState() {
		// This can happen if the UI did not get updated quickly enough.
		if !_slamState.cameraPoseInitializer!.hasValidPose {
			print("Warning: not accepting to enter into scanning state since the initial pose is not valid.")
			return
		}
		// Switch to the Done button.
		scanButton.isHidden = true
		doneButton.isHidden = false
		resetButton.isHidden = false
		// Prepare the mapper for the new scan.
		setupMapper()
        _slamState.tracker!.initialCameraPose = _slamState.cameraPoseInitializer!.cameraPose
		// We will lock exposure during scanning to ensure better coloring.
		setColorCameraParametersForScanning()
		_slamState.scannerState = .scanning
		// Temporarily disable options while we're scanning.
		enableNewTrackerSwitch.isEnabled = false
		enableHighResolutionColorSwitch.isEnabled = false
		enableNewMapperSwitch.isEnabled = false
		enableHighResMappingSwitch.isEnabled = false
	}

	func enterViewingState() {
		// Cannot be lost in view mode.
		hideTrackingErrorMessage()
		_appStatus.statusMessageDisabled = true
		updateAppStatusMessage()
		// Hide the Scan/Done/Reset button.
		scanButton.isHidden = true
		doneButton.isHidden = true
		resetButton.isHidden = true
		_sensorController.stopStreaming()
		if _useColorCamera {
			stopColorCamera()
		}
		_slamState.mapper!.finalizeTriangleMesh()
		let mesh = _slamState.scene!.lockAndGetMesh()
		presentMeshViewer(mesh!)
		_slamState.scene!.unlockMesh()
		_slamState.scannerState = .viewing
		updateIdleTimer()
	}

	//MARK: -  Structure Sensor Management

	func currentStateNeedsSensor() -> Bool {
		switch _slamState.scannerState {
		// Initialization and scanning need the sensor.
		case .cubePlacement, .scanning:
			return true
		// Other states don't need the sensor.
		default:
			return false
		}
	}

	//MARK: - IMU

	func setupIMU() {
		_lastGravity = GLKVector3.init(v: (0, 0, 0))
		// 60 FPS is responsive enough for motion events.
		let fps: Double = 60
		_motionManager = CMMotionManager.init()
		_motionManager!.accelerometerUpdateInterval = 1.0 / fps
		_motionManager!.gyroUpdateInterval = 1.0 / fps
		// Limiting the concurrent ops to 1 is a simple way to force serial execution
		_imuQueue = OperationQueue.init()
		_imuQueue!.maxConcurrentOperationCount = 1
		let dmHandler: CMDeviceMotionHandler = { motion, _ in
			// Could be nil if the self is released before the callback happens.
			if self.view != nil {
				self.processDeviceMotion(motion!, error: nil)
			}
		}
		_motionManager!.startDeviceMotionUpdates(to: _imuQueue!, withHandler: dmHandler)
	}

	func processDeviceMotion(_ motion: CMDeviceMotion, error: NSError?) {
		if _slamState.scannerState == .cubePlacement {
			// Update our gravity vector, it will be used by the cube placement initializer.
			_lastGravity = GLKVector3Make(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
		}
		if _slamState.scannerState == .cubePlacement || _slamState.scannerState == .scanning {
			if _slamState.tracker != nil {
				// The tracker is more robust to fast moves if we feed it with motion data.
				_slamState.tracker!.updateCameraPose(with: motion)
			}
		}
	}
	
	//MARK: - UI Callbacks

    @IBAction func calibrationButtonClicked(_ button: UIButton) {
        STSensorController.launchCalibratorAppOrGoToAppStore()
    }

    @IBAction func instructionButtonClicked(_ button: UIButton) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "instructionOverlay")
        instructionOverlay.isHidden = true
    }

	@IBAction func newTrackerSwitchChanged(_ sender: UISwitch) {
		_dynamicOptions.newTrackerIsOn = enableNewTrackerSwitch.isOn
		onSLAMOptionsChanged()
	}

	@IBAction func highResolutionColorSwitchChanged(_ sender: UISwitch) {
		_dynamicOptions.highResColoring = self.enableHighResolutionColorSwitch.isOn
		if (avCaptureSession != nil) {
			stopColorCamera()
			// The dynamic option must be updated before the camera is restarted.
			_dynamicOptions.highResColoring = self.enableHighResolutionColorSwitch.isOn
			if _useColorCamera {
				startColorCamera()
			}
		}
		// Force a scan reset since we cannot changing the image resolution during the scan is not
		// supported by STColorizer.
		onSLAMOptionsChanged() // will call UI sync
	}

	@IBAction func newMapperSwitchChanged(_ sender: UISwitch) {
		_dynamicOptions.newMapperIsOn = self.enableNewMapperSwitch.isOn
		onSLAMOptionsChanged() // will call UI sync
	}

	@IBAction func highResMappingSwitchChanged(_ sender: UISwitch) {
		_dynamicOptions.highResMapping = self.enableHighResMappingSwitch.isOn
		onSLAMOptionsChanged() // will call UI sync
	}

	func onSLAMOptionsChanged() {
		syncUIfromDynamicOptions()
		// A full reset to force a creation of a new tracker.
		resetSLAM()
		clearSLAM()
		setupSLAM()
		// Restore the volume size cleared by the full reset.
		adjustVolumeSize( volumeSize: _slamState.volumeSizeInMeters)
	}

	func adjustVolumeSize(volumeSize: GLKVector3) {
		// Make sure the volume size remains between 10 centimeters and 3 meters.
		let x = keepInRange(volumeSize.x, minValue: 0.1, maxValue: 3)
		let y = keepInRange(volumeSize.y, minValue: 0.1, maxValue: 3)
		let z = keepInRange(volumeSize.z, minValue: 0.1, maxValue: 3)
		_slamState.volumeSizeInMeters = GLKVector3.init(v: (x, y, z))
		_slamState.cameraPoseInitializer!.volumeSizeInMeters = _slamState.volumeSizeInMeters
		_display!.cubeRenderer!.adjustCubeSize(_slamState.volumeSizeInMeters)
	}

	@IBAction func scanButtonPressed(_ sender: UIButton) {
        // hide windows while scanning
        trackerShowingScanStart =  !enableNewTrackerView.isHidden
        toggleTracker(false)
        enterScanningState()
	}

	@IBAction func resetButtonPressed(_ sender: UIButton) {
        // restore window after scanning
        if trackerShowingScanStart {
            toggleTracker(true)
        }
		resetSLAM()
	}

	@IBAction func doneButtonPressed(_ sender: UIButton) {
        // restore window after scanning
        if trackerShowingScanStart {
            toggleTracker(true)
        }
		enterViewingState()
	}

	// Manages whether we can let the application sleep.
	func updateIdleTimer() {
		if isStructureConnectedAndCharged() && currentStateNeedsSensor() {
			// Do not let the application sleep if we are currently using the sensor data.
			UIApplication.shared.isIdleTimerDisabled = true
		} else {
			// Let the application sleep if we are only viewing the mesh or if no sensors are connected.
			UIApplication.shared.isIdleTimerDisabled = false
		}
	}

	func showTrackingMessage(_ message: String) {
		trackingLostLabel.text = message
		trackingLostLabel.isHidden = false
	}

	func hideTrackingErrorMessage() {
		trackingLostLabel.isHidden = true
	}

	func showAppStatusMessage(_ msg: String) {
		_appStatus.needsDisplayOfStatusMessage = true
		view.layer.removeAllAnimations()
		appStatusMessageLabel.text = msg
		appStatusMessageLabel.isHidden = false
		// Progressively show the message label.
		view!.isUserInteractionEnabled = false
		UIView.animate(withDuration: 0.5, animations: {
			self.appStatusMessageLabel.alpha = 1.0
		})
	}

	func hideAppStatusMessage() {
		if !_appStatus.needsDisplayOfStatusMessage {
			return
		}
		_appStatus.needsDisplayOfStatusMessage = false
		view.layer.removeAllAnimations()
		UIView.animate(withDuration: 0.5, animations: {
			self.appStatusMessageLabel.alpha = 0
			}, completion: { _ in
				// If nobody called showAppStatusMessage before the end of the animation, do not hide it.
				if !self._appStatus.needsDisplayOfStatusMessage {

					// Could be nil if the self is released before the callback happens.
					if self.view != nil {
						self.appStatusMessageLabel.isHidden = true
						self.view.isUserInteractionEnabled = true
					}
				}
		})
	}

	func updateAppStatusMessage() {
		// Skip everything if we should not show app status messages (e.g. in viewing state).
		if _appStatus.statusMessageDisabled {
			hideAppStatusMessage()
			return
		}
		// First show sensor issues, if any.
		switch _appStatus.sensorStatus {
		case .needsUserToConnect:
			showAppStatusMessage(_appStatus.pleaseConnectSensorMessage)
			return
		case .needsUserToCharge:
			showAppStatusMessage(_appStatus.pleaseChargeSensorMessage)
			return
		case .ok:
			break
		}
		// Then show color camera permission issues, if any.
		if !_appStatus.colorCameraIsAuthorized {
			showAppStatusMessage(_appStatus.needColorCameraAccessMessage)
			return
		}
		// If we reach this point, no status to show.
		hideAppStatusMessage()
	}

	@IBAction func pinchGesture(_ sender: UIPinchGestureRecognizer) {
		if sender.state == .began {
			if _slamState.scannerState == .cubePlacement {
				_volumeScale.initialPinchScale = _volumeScale.currentScale / sender.scale
			}
		} else if sender.state == .changed {
			if _slamState.scannerState == .cubePlacement {
				// In some special conditions the gesture recognizer can send a zero initial scale.
				if !_volumeScale.initialPinchScale.isNaN {
					_volumeScale.currentScale = sender.scale * _volumeScale.initialPinchScale
					// Don't let our scale multiplier become absurd
					_volumeScale.currentScale = CGFloat(keepInRange(Float(_volumeScale.currentScale), minValue: 0.01, maxValue: 1000))
					let newVolumeSize: GLKVector3 = GLKVector3MultiplyScalar(_options.initVolumeSizeInMeters, Float(_volumeScale.currentScale))
					adjustVolumeSize( volumeSize: newVolumeSize)
				}
			}
		}
	}

    @IBAction func toggleNewTrackerVisible(_ sender: UILongPressGestureRecognizer) {
        if (sender.state == .began) {
            toggleTracker(enableNewTrackerView.isHidden)
        }
    }

    func toggleTracker(_ show: Bool) {
        if show {
            // set alpha to 0.9
            enableNewTrackerView.alpha = 0
            enableNewTrackerView.isHidden = false
            UIView.animate(withDuration: 0.3, delay: 0.0, options: .curveEaseOut, animations: { () -> Void in
                self.enableNewTrackerView.alpha = 0.9
                }, completion: { (finished: Bool) -> Void in
                    self.enableNewTrackerView.isHidden = false
            })
        } else {
            // set alpha to 0.0
            UIView.animate(withDuration: 1.0, delay: 0.0, options: .curveEaseOut, animations: { () -> Void in
                self.enableNewTrackerView.alpha = 0.0

                }, completion: { (finished: Bool) -> Void in
                    self.enableNewTrackerView.isHidden = true
            })
        }
    }
    
}

extension ScanViewController: MeshViewControllerDelegate {

    func meshViewControllerDidExport(_ objURL: URL, stlURL: URL, scaledStlURL: URL?) {
        let string = "export \(objURL) \(stlURL) \(scaledStlURL)"
        NSLog(string)
        delegate?.scanViewControllerDidExport(objURL, stlURL: stlURL, scaledStlURL: scaledStlURL)
    }
    
	func meshViewControllerWillDismiss() {
		// If we are running colorize work, we should cancel it.
		if _naiveColorizeTask != nil {
			_naiveColorizeTask!.cancel()
			_naiveColorizeTask = nil
		}
		if _enhancedColorizeTask != nil {
			_enhancedColorizeTask!.cancel()
			_enhancedColorizeTask = nil
		}
		if _holeFillingTask != nil {
			_holeFillingTask!.cancel()
			_holeFillingTask = nil
		}
		self.meshViewController.hideMeshViewerMessage()
	}

	func meshViewControllerDidDismiss() {
		_appStatus.statusMessageDisabled = false
		updateAppStatusMessage()
		let _ = connectToStructureSensorAndStartStreaming()
		resetSLAM()
	}

    func backgroundTask(_ sender: STBackgroundTask!, didUpdateProgress progress: Double) {
		if sender == _naiveColorizeTask {
            DispatchQueue.main.async(execute: {
				self.meshViewController.showMeshViewerMessage(String.init(format: "Processing: % 3d%%", Int(progress*20)))
            })
		} else if sender == _enhancedColorizeTask {
            DispatchQueue.main.async(execute: {
            self.meshViewController.showMeshViewerMessage(String.init(format: "Processing: % 3d%%", Int(progress*80)+20))
            })
		} else if sender == _holeFillingTask {
			DispatchQueue.main.async(execute: {
				self.meshViewController.showMeshViewerMessage(String.init(format: "Hole filling: % 3d%%", Int(progress*80)+20))
			})
		}
	}
	
	func meshViewControllerDidRequestColorizing(_ mesh: STMesh, previewCompletionHandler: @escaping () -> Void, enhancedCompletionHandler: @escaping () -> Void) -> Bool {
		if _holeFillingTask != nil || _naiveColorizeTask != nil || _enhancedColorizeTask != nil { // already one running?
			NSLog("Already running background task!")
			return false
		}
		_naiveColorizeTask = try! STColorizer.newColorizeTask(with: mesh,
		                   scene: _slamState.scene,
		                   keyframes: _slamState.keyFrameManager!.getKeyFrames(),
		                   completionHandler: { error in
							if error != nil {
                                print("Error during colorizing: \(error?.localizedDescription)")
                            } else {
                                DispatchQueue.main.async(execute: {
                                    previewCompletionHandler()
                                    self.meshViewController.mesh = mesh

									self.performEnhancedColorize(mesh, enhancedCompletionHandler:enhancedCompletionHandler)
                                    })
                                    self._naiveColorizeTask = nil
                                }
			},
		                   options: [kSTColorizerTypeKey : STColorizerType.perVertex.rawValue,
            kSTColorizerPrioritizeFirstFrameColorKey: _options.prioritizeFirstFrameColor]
		)

		if _naiveColorizeTask != nil {
			// Release the tracking and mapping resources. It will not be possible to resume a scan after this point
//			_slamState.mapper!.reset()
//			_slamState.tracker!.reset()
			_naiveColorizeTask!.delegate = self
			_naiveColorizeTask!.start()
			return true
		}
		return false
	}

	func performEnhancedColorize(_ mesh: STMesh, enhancedCompletionHandler: @escaping () -> Void) {
        _enhancedColorizeTask = try! STColorizer.newColorizeTask(with: mesh, scene: _slamState.scene, keyframes: _slamState.keyFrameManager!.getKeyFrames(), completionHandler: {error in
            if error != nil {
                NSLog("Error during colorizing: %@", error!.localizedDescription)
            } else {
                DispatchQueue.main.async(execute: {
                    enhancedCompletionHandler()
					self.meshViewController.mesh = mesh
                })
                self._enhancedColorizeTask = nil
            }
            }, options: [kSTColorizerTypeKey : STColorizerType.textureMapForObject.rawValue, kSTColorizerPrioritizeFirstFrameColorKey: _options.prioritizeFirstFrameColor, kSTColorizerQualityKey: _options.colorizerQuality.rawValue, kSTColorizerTargetNumberOfFacesKey: _options.colorizerTargetNumFaces])
		if _enhancedColorizeTask != nil {
			// We don't need the keyframes anymore now that the final colorizing task was started.
			// Clearing it now gives a chance to early release the keyframe memory when the colorizer
			// stops needing them.
//            _slamState.keyFrameManager!.clear()
			_enhancedColorizeTask!.delegate = self
			_enhancedColorizeTask!.start()
		}
	}

	func meshViewControllerDidRequestHoleFilling(_ mesh: STMesh, previewCompletionHandler: @escaping () -> Void, enhancedCompletionHandler: @escaping () -> Void) -> Bool {
		if _holeFillingTask != nil || _naiveColorizeTask != nil || _enhancedColorizeTask != nil { // already one running?
			NSLog("Already running background task!")
			return false
		}
		_holeFillingTask = STMesh.newFillHolesTask(with: mesh, completionHandler: { result, error in
						if error != nil {
						NSLog("Error during hole filling: \(error?.localizedDescription)")
						} else {
								DispatchQueue.main.async(execute: {
									previewCompletionHandler()
								
									let meshIsColorized: Bool = result!.hasPerVertexColors() || result!.hasPerVertexUVTextureCoords()
									if !meshIsColorized {
										// colorize the mesh
										let _ = self.meshViewControllerDidRequestColorizing(result!, previewCompletionHandler: previewCompletionHandler, enhancedCompletionHandler:enhancedCompletionHandler)
									}
									else {
										self.meshViewController.holeFilledMesh = result!
										// close progress window
										enhancedCompletionHandler()
									}

								})
						}
				self._holeFillingTask = nil
			})
		if _holeFillingTask != nil {
			_holeFillingTask!.delegate = self
			_holeFillingTask!.start()
			return true
		}
		return false
	}

}
