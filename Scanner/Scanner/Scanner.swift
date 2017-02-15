//
//  Scanner.swift
//  Scanner
//
//  Created by Kurt Jensen on 2/15/17.
//  Copyright © 2017 stashdump.com. All rights reserved.
//


struct DynamicOptions {
    var newTrackerIsOn = true
    var newTrackerSwitchEnabled = true
    var highResColoring = false
    var highResColoringSwitchEnabled = false
    var newMapperIsOn = true
    var newMapperSwitchEnabled = true
    var highResMapping = true
    var highResMappingSwitchEnabled = true
}

// Volume resolution in meters

struct Options {
    // The initial scanning volume size will be 0.5 x 0.5 x 0.5 meters
    // (X is left-right, Y is up-down, Z is forward-back)
    var initVolumeSizeInMeters: GLKVector3 = GLKVector3Make(0.5, 0.5, 0.5)
    // The maximum number of keyframes saved in keyFrameManager
    var maxNumKeyFrames: Int = 48
    // Colorizer quality
    var colorizerQuality: STColorizerQuality = STColorizerQuality.highQuality
    // Take a new keyframe in the rotation difference is higher than 20 degrees.
    var maxKeyFrameRotation: CGFloat = CGFloat(20 * (M_PI / 180)) // 20 degrees
    // Take a new keyframe if the translation difference is higher than 30 cm.
    var maxKeyFrameTranslation: CGFloat = 0.3 // 30cm
    // Threshold to consider that the rotation motion was small enough for a frame to be accepted
    // as a keyframe. This avoids capturing keyframes with strong motion blur / rolling shutter.
    var maxKeyframeRotationSpeedInDegreesPerSecond: CGFloat = 1
    // Whether we should use depth aligned to the color viewpoint when Structure Sensor was calibrated.
    // This setting may get overwritten to false if no color camera can be used.
    var useHardwareRegisteredDepth: Bool = false
    // Whether to enable an expensive per-frame depth accuracy refinement.
    // Note: this option requires useHardwareRegisteredDepth to be set to false.
    var applyExpensiveCorrectionToDepth: Bool = true
    // Whether the colorizer should try harder to preserve appearance of the first keyframe.
    // Recommended for face scans.
    var prioritizeFirstFrameColor: Bool = true
    // Target number of faces of the final textured mesh.
    var colorizerTargetNumFaces: Int = 30000
    // Focus position for the color camera (between 0 and 1). Must remain fixed one depth streaming
    // has started when using hardware registered depth.
    let lensPosition: CGFloat = 0.75
}

enum ScannerState: Int {
    case cubePlacement = 0, scanning, viewing
}

// SLAM-related members.
struct SlamData {
    var initialized = false
    var showingMemoryWarning = false
    var prevFrameTimeStamp: TimeInterval = -1
    var scene: STScene? = nil
    var tracker: STTracker? = nil
    var mapper: STMapper? = nil
    var cameraPoseInitializer: STCameraPoseInitializer? = nil
    var initialDepthCameraPose: GLKMatrix4 = GLKMatrix4Identity
    var keyFrameManager: STKeyFrameManager? = nil
    var scannerState: ScannerState = .cubePlacement
    var volumeSizeInMeters = GLKVector3Make(Float.nan, Float.nan, Float.nan)
}

// Utility struct to manage a gesture-based scale.
struct PinchScaleState {
    
    var currentScale: CGFloat = 1
    var initialPinchScale: CGFloat = 1
}

func keepInRange(_ value: Float, minValue: Float, maxValue: Float) -> Float {
    if value.isNaN {
        return minValue
    }
    if value > maxValue {
        return maxValue
    }
    if value < minValue {
        return minValue
    }
    return value
}

struct AppStatus {
    let pleaseConnectSensorMessage = "Please connect Structure Sensor."
    let pleaseChargeSensorMessage = "Please charge Structure Sensor."
    let needColorCameraAccessMessage = "This app requires camera access to capture color.\nAllow access by going to Settings → Privacy → Camera."
    
    enum SensorStatus {
        case ok, needsUserToConnect, needsUserToCharge
    }
    
    // Structure Sensor status.
    var sensorStatus: SensorStatus = .ok
    // Whether iOS camera access was granted by the user.
    var colorCameraIsAuthorized = true
    // Whether there is currently a message to show.
    var needsDisplayOfStatusMessage = false
    // Flag to disable entirely status message display.
    var statusMessageDisabled = false
}

// Display related members.
struct DisplayData {
    
    // OpenGL context.
    var context: EAGLContext? = nil
    // OpenGL Texture reference for y images.
    var lumaTexture: CVOpenGLESTexture? = nil
    // OpenGL Texture reference for color images.
    var chromaTexture: CVOpenGLESTexture? = nil
    // OpenGL Texture cache for the color camera.
    var videoTextureCache: CVOpenGLESTextureCache? = nil
    // Shader to render a GL texture as a simple quad.
    var yCbCrTextureShader: STGLTextureShaderYCbCr? = nil
    var rgbaTextureShader: STGLTextureShaderRGBA? = nil
    var depthAsRgbaTexture: GLuint = 0
    // Renders the volume boundaries as a cube.
    var cubeRenderer: STCubeRenderer? = nil
    // OpenGL viewport.
    var viewport: [GLfloat] = [0, 0, 0, 0]
    // OpenGL projection matrix for the color camera.
    var colorCameraGLProjectionMatrix: GLKMatrix4 = GLKMatrix4Identity
    // OpenGL projection matrix for the depth camera.
    var depthCameraGLProjectionMatrix: GLKMatrix4 = GLKMatrix4Identity
    // Mesh rendering alpha
    var meshRenderingAlpha: Float = 0.8
}
