import BoothCore
import CoreImage
import CoreImage.CIFilterBuiltins

/// Guest colour modes. The Windows app used its own effect classes
/// (CBlackAndWhiteEffect, CCepiaToneEffect, antique, retro); these are
/// Core Image approximations.
public enum ColorEffects {
    public static func apply(_ effect: ColorEffect, to image: CIImage) -> CIImage {
        switch effect {
        case .color:
            return image
        case .grayscale:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = 0
            filter.contrast = 1.05
            return filter.outputImage ?? image
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = image
            filter.intensity = 0.9
            return filter.outputImage ?? image
        case .antique:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.6
            let vignette = CIFilter.vignette()
            vignette.inputImage = sepia.outputImage
            vignette.intensity = 0.8
            vignette.radius = 2
            return vignette.outputImage?.cropped(to: image.extent) ?? image
        case .retro:
            let filter = CIFilter.photoEffectTransfer()
            filter.inputImage = image
            return filter.outputImage ?? image
        }
    }
}
