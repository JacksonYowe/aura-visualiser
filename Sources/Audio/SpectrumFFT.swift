import Accelerate
import Foundation

/// Windowed FFT with preallocated buffers (no allocation per frame).
final class SpectrumFFT {
    let n: Int
    let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    /// Amplitude per bin; a full-scale sine reads ≈ 1.
    let magnitudes: UnsafeMutablePointer<Float>
    private var scale: Float

    init(log2n: Int) {
        n = 1 << log2n
        half = n / 2
        self.log2n = vDSP_Length(log2n)
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = .allocate(capacity: n)
        real = .allocate(capacity: half)
        imag = .allocate(capacity: half)
        magnitudes = .allocate(capacity: half)
        magnitudes.initialize(repeating: 0, count: half)
        var sum: Float = 0
        vDSP_sve(window, 1, &sum, vDSP_Length(n))
        // zrip returns |X| scaled by 2 relative to the textbook transform; the window's
        // coherent gain (sum/n) is divided out so amplitude is window-independent.
        scale = 1 / sum
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate(); windowed.deallocate()
        real.deallocate(); imag.deallocate(); magnitudes.deallocate()
    }

    func process(_ input: UnsafePointer<Float>) {
        vDSP_vmul(input, 1, window, 1, windowed, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(half))
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(half))
    }
}
