import AVFoundation

extension AVAudioPCMBuffer {
    /// 이 버퍼의 최대 진폭(0...1). 소리가 실제로 들어오는지 판단하는 데 쓴다.
    ///
    /// 권한이 거부돼도 macOS는 콜백을 그대로 보내고 내용만 0으로 채운다. 그래서
    /// "콜백이 온다"만으로는 정상 동작을 알 수 없고 진폭을 봐야 한다.
    ///
    /// 인터리브 여부를 반드시 구분해야 한다. `floatChannelData[0][frame]`은
    /// **디인터리브** 배치를 가정한 접근이다. Core Audio process tap은 Float32
    /// **인터리브**(`L,R,L,R...`)로 주므로, 같은 방식으로 읽으면 엉뚱한 위치를
    /// 짚어 진폭이 늘 0으로 나온다. 실제로 이 때문에 시스템 오디오가 "무음"으로
    /// 오진되는 버그가 있었다.
    func peakAmplitude(sampleCount: Int = 256) -> Float {
        guard frameLength > 0 else { return 0 }
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        let step = max(1, frames / sampleCount)
        var peak: Float = 0

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = floatChannelData else { return 0 }
            if format.isInterleaved {
                // 채널이 한 버퍼에 번갈아 담긴다. 프레임 f의 채널 c는 f*channels+c.
                let samples = data[0]
                for frame in Swift.stride(from: 0, to: frames, by: step) {
                    for channel in 0..<channels {
                        peak = max(peak, abs(samples[frame * channels + channel]))
                    }
                }
            } else {
                for channel in 0..<channels {
                    let samples = data[channel]
                    for frame in Swift.stride(from: 0, to: frames, by: step) {
                        peak = max(peak, abs(samples[frame]))
                    }
                }
            }

        case .pcmFormatInt16:
            guard let data = int16ChannelData else { return 0 }
            let scale = Float(Int16.max)
            if format.isInterleaved {
                let samples = data[0]
                for frame in Swift.stride(from: 0, to: frames, by: step) {
                    for channel in 0..<channels {
                        peak = max(peak, abs(Float(samples[frame * channels + channel]) / scale))
                    }
                }
            } else {
                for channel in 0..<channels {
                    let samples = data[channel]
                    for frame in Swift.stride(from: 0, to: frames, by: step) {
                        peak = max(peak, abs(Float(samples[frame]) / scale))
                    }
                }
            }

        case .pcmFormatInt32:
            guard let data = int32ChannelData else { return 0 }
            let scale = Float(Int32.max)
            if format.isInterleaved {
                let samples = data[0]
                for frame in Swift.stride(from: 0, to: frames, by: step) {
                    for channel in 0..<channels {
                        peak = max(peak, abs(Float(samples[frame * channels + channel]) / scale))
                    }
                }
            } else {
                for channel in 0..<channels {
                    let samples = data[channel]
                    for frame in Swift.stride(from: 0, to: frames, by: step) {
                        peak = max(peak, abs(Float(samples[frame]) / scale))
                    }
                }
            }

        case .otherFormat, .pcmFormatFloat64:
            // 직접 읽을 채널 포인터가 없는 형식. 무음으로 오진해 잘못된 경고를
            // 띄우지 않도록 "소리 있음"에 해당하는 값을 준다.
            return 1

        @unknown default:
            return 1
        }

        return peak
    }
}
