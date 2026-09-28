import AVFoundation
import Foundation

extension AVAudioPCMBuffer {
    /// Creates an independent silent buffer with the same format and length.
    func silentCopy() -> AVAudioPCMBuffer? {
        copyBuffer(silenced: true)
    }

    /// Creates an independent buffer with the same format, length and contents.
    func copied() -> AVAudioPCMBuffer? {
        copyBuffer(silenced: false)
    }

    private func copyBuffer(silenced: Bool) -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let destinationData = destination[index].mData else { return nil }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            if silenced {
                // Muting must not read source samples, including a missing pointer.
                memset(destinationData, 0, byteCount)
            } else {
                guard let sourceData = source[index].mData else { return nil }
                memcpy(destinationData, sourceData, byteCount)
            }
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }
}
