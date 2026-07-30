import AVFoundation

extension AVAudioPCMBuffer {
    /// 이 버퍼의 최대 진폭(0...1). 소리가 실제로 들어오는지 판단하는 데 쓴다.
    ///
    /// 권한이 거부돼도 macOS는 콜백을 그대로 보내고 내용만 0으로 채운다. 그래서
    /// "콜백이 온다"만으로는 정상 동작을 알 수 없고 진폭을 봐야 한다.
    ///
    /// 샘플 형식마다 채널 포인터의 타입과 정규화 계수만 다르고, 훑는 방식은 같다.
    /// 배치를 구분하는 규칙은 `scanPeak`에 한 번만 둔다.
    func peakAmplitude(sampleCount: Int = 256) -> Float {
        guard frameLength > 0 else { return 0 }
        let step = max(1, Int(frameLength) / sampleCount)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = floatChannelData else { return 0 }
            return scanPeak(data, step: step) { abs($0) }

        case .pcmFormatInt16:
            guard let data = int16ChannelData else { return 0 }
            let scale = Float(Int16.max)
            return scanPeak(data, step: step) { abs(Float($0) / scale) }

        case .pcmFormatInt32:
            guard let data = int32ChannelData else { return 0 }
            let scale = Float(Int32.max)
            return scanPeak(data, step: step) { abs(Float($0) / scale) }

        case .otherFormat, .pcmFormatFloat64:
            // 직접 읽을 채널 포인터가 없는 형식. 무음으로 오진해 잘못된 경고를
            // 띄우지 않도록 "소리 있음"에 해당하는 값을 준다.
            return 1

        @unknown default:
            return 1
        }
    }

    /// 채널 데이터를 배치에 맞게 훑어 최대 진폭을 찾는다.
    ///
    /// **인터리브 여부 판정이 이 한 곳에만 있다.** `floatChannelData[0][frame]`은
    /// **디인터리브** 배치를 가정한 접근이다. Core Audio process tap은 Float32
    /// **인터리브**(`L,R,L,R...`)로 주므로, 같은 방식으로 읽으면 엉뚱한 위치를
    /// 짚어 진폭이 늘 0으로 나온다. 실제로 이 때문에 시스템 오디오가 "무음"으로
    /// 오진되는 버그가 있었다.
    ///
    /// - Parameter magnitude: 샘플 하나를 0...1 진폭으로 옮긴다. 정수 형식은
    ///   여기서 정규화한다.
    private func scanPeak<Sample>(
        _ data: UnsafePointer<UnsafeMutablePointer<Sample>>,
        step: Int,
        magnitude: (Sample) -> Float
    ) -> Float {
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        var peak: Float = 0

        if format.isInterleaved {
            // 채널이 한 버퍼에 번갈아 담긴다. 프레임 f의 채널 c는 f*channels+c.
            let samples = data[0]
            for frame in Swift.stride(from: 0, to: frames, by: step) {
                for channel in 0..<channels {
                    peak = max(peak, magnitude(samples[frame * channels + channel]))
                }
            }
        } else {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in Swift.stride(from: 0, to: frames, by: step) {
                    peak = max(peak, magnitude(samples[frame]))
                }
            }
        }

        return peak
    }
}
