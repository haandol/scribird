import AVFoundation
import CoreMedia
import Foundation
@testable import Scribird

/// 오디오 파일을 전사 파이프라인에 밀어넣는 테스트 하네스.
///
/// 마이크·시스템 출력 캡처는 하드웨어를 요구해 `swift test`로 덮을 수 없지만, 캡처
/// **이후**의 경로(리샘플링·시각 부여·전사·언어 중재)는 파일로 재현할 수 있다. 실제 발화가
/// 어떤 텍스트·신뢰도·시각으로 돌아오는지는 합성 입력으로는 알 수 없으므로, 회귀를 잡으려면
/// 실제 오디오가 필요하다.
///
/// **오디오 파일은 저장소에 넣지 않는다.** 이 프로젝트는 녹음된 대화를 커밋하지 않으며,
/// 이 픽스처도 의료 상담 대화라 예외가 아니다. 파일이 없으면 해당 테스트는 건너뛴다 —
/// 파일을 가진 사람에게만 도는 테스트이고, CI에서는 조용히 빠진다.
enum AudioFixture {
    /// 픽스처 경로를 바꿀 환경 변수. 다른 파일로 같은 검증을 돌릴 때 쓴다.
    static let pathVariable = "SCRIBIRD_STT_FIXTURE"

    /// 기본 픽스처. 영어 의료 상담 대화 16.6초, 16kHz 모노 mp3.
    private static let defaultPath = "~/Downloads/metformin-medication.mp3"

    /// 픽스처의 실제 발화 내용(정답).
    ///
    /// 전사 품질을 재려면 정답이 있어야 한다. 이 문장은 오디오를 들은 사람이 적은 것이고,
    /// 전사 결과와 비교하는 기준이 된다.
    static let groundTruth = """
        Do you take any medication? Yeah, so insulin, well metformin. And then that's it.
        """

    /// 정답에서 반드시 인식돼야 하는 핵심 단어들.
    ///
    /// 조사·감탄사는 모델마다 달라지지만 이 단어들은 내용을 담고 있어, 빠지면 회의록으로서
    /// 쓸모가 없다. 실측에서 `medication`·`insulin`은 잡혔고 **`metformin`은 실패했다**
    /// (`I'm at Foreman`으로 인식). 그 실패가 이 픽스처를 고른 이유다.
    static let keywords = ["medication", "insulin", "metformin"]

    /// 실측에서 실제로 놓친 단어. 개선을 재는 기준선이다.
    ///
    /// 약품명은 일반 어휘 모델의 약점이다. 이 값이 빈 배열이 되는 날은 모델이 개선된
    /// 것이므로, 테스트가 그것을 알려주도록 둔다.
    static let knownMisses = ["metformin"]

    /// 픽스처 파일 위치. 없으면 nil이고, 호출한 테스트는 건너뛴다.
    static var url: URL? {
        let raw = ProcessInfo.processInfo.environment[pathVariable] ?? defaultPath
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 픽스처가 없을 때 테스트에 남길 안내.
    static var skipReason: String {
        """
        STT 픽스처가 없어 건너뜁니다. \(pathVariable)로 경로를 지정하거나 \
        \(defaultPath)에 파일을 두세요.
        """
    }

    /// 파일을 전사기 입력 포맷으로 변환해 버퍼 배열로 돌려준다.
    ///
    /// 캡처 경로와 같은 변환기(`AudioStreamConverter`)를 거친다 — 테스트가 자체 변환을
    /// 하면 실제로 쓰이는 변환 경로를 검증하지 못한다.
    ///
    /// - Parameter chunkFrames: 한 번에 읽는 프레임 수. 캡처 콜백이 주는 버퍼 크기를
    ///   흉내내 여러 조각으로 나눠 넣는다. 한 덩어리로 넣으면 조각 경계에서 생기는
    ///   문제(시각 누적, 변환기 재사용)를 놓친다.
    static func buffers(
        from url: URL,
        to targetFormat: AVAudioFormat,
        chunkFrames: AVAudioFrameCount = 4096
    ) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AudioStreamConverter(
            from: file.processingFormat,
            to: targetFormat
        ) else {
            throw FixtureError.conversionUnavailable(
                from: file.processingFormat,
                to: targetFormat
            )
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ) else {
            throw FixtureError.bufferAllocationFailed
        }

        var converted: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            try file.read(into: input)
            guard input.frameLength > 0 else { break }
            guard let output = converter.convert(input) else { continue }
            converted.append(output)
        }
        guard !converted.isEmpty else { throw FixtureError.noAudioDecoded }
        return converted
    }

    /// 비교를 위해 텍스트를 정규화한다.
    ///
    /// 대소문자·구두점·연속 공백은 전사 품질과 무관하게 달라지므로 걷어낸다. 이것을 하지
    /// 않으면 `"medications?"`와 `"medications"`가 다른 단어로 잡혀 정확도가 실제보다
    /// 낮게 나온다.
    static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// 정답 대비 단어 오류율(WER).
    ///
    /// 편집 거리(삽입·삭제·치환)를 정답 단어 수로 나눈 값이다. 0이면 완벽하고, 1이면 정답
    /// 길이만큼 틀렸다는 뜻이다. 감탄사(`um`, `uh`)가 많은 실제 발화에서는 삽입이 늘어 값이
    /// 커지므로, 절대값보다 **회귀 감지**에 쓴다.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

        // Levenshtein 거리. 행 두 개만 유지하면 되므로 전체 표를 잡지 않는다.
        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for (i, refWord) in ref.enumerated() {
            current[0] = i + 1
            for (j, hypWord) in hyp.enumerated() {
                let substitution = previous[j] + (refWord == hypWord ? 0 : 1)
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                current[j + 1] = min(substitution, insertion, deletion)
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    /// 전사 결과에 들어 있는 핵심 단어들.
    ///
    /// **단복수는 같은 단어로 본다.** 정답은 `medication`인데 전사는 `medications`를 냈다 —
    /// 내용상 같은 단어이므로 이것을 실패로 세면 회귀 감지가 아니라 어미 비교가 된다.
    /// 접두 일치로 판정해 `medication` ⊂ `medications`를 흡수한다.
    static func foundKeywords(in transcript: String) -> [String] {
        let words = normalize(transcript)
        return keywords.filter { keyword in
            let target = keyword.lowercased()
            return words.contains { $0.hasPrefix(target) || target.hasPrefix($0) && $0.count >= 5 }
        }
    }

    enum FixtureError: LocalizedError {
        case conversionUnavailable(from: AVAudioFormat, to: AVAudioFormat)
        case bufferAllocationFailed
        case noAudioDecoded

        var errorDescription: String? {
            switch self {
            case .conversionUnavailable(let from, let to):
                "픽스처 포맷을 변환할 수 없습니다: \(from) → \(to)"
            case .bufferAllocationFailed:
                "읽기 버퍼를 만들 수 없습니다."
            case .noAudioDecoded:
                "픽스처에서 오디오를 하나도 읽지 못했습니다."
            }
        }
    }
}
