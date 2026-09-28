import SwiftUI

struct FileTranscriptionView: View {
    @Bindable var model: FileTranscriptionModel
    let languageSettings: AppLanguageSettings

    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("파일 전사", "Transcribe File"))
                .font(.headline)
            Text(tr("음성 파일을 기기에서 전사합니다. 화자는 구분하지 않습니다.",
                    "Transcribe audio files on this Mac. Speakers are not identified."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("파일 선택…", "Choose File…")) { model.chooseFile() }
                    .disabled(model.isRunning)
                Text(model.source?.lastPathComponent ?? tr("선택한 파일 없음", "No file selected"))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.source?.path ?? "")
            }
            HStack {
                Picker(tr("음성 인식 방식", "ASR engine"), selection: $model.engine) {
                    ForEach(FileTranscriptionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .disabled(model.isRunning)
            }
            if model.engine == .qwen3 {
                Text(tr("Apple Silicon 전용입니다. 처음 시작할 때 실행 환경과 모델(약 2.3GB)을 다운로드합니다. 시간 표시는 20초 이하 오디오 구간 기준입니다.",
                        "Requires Apple Silicon. First use downloads the runtime and model (about 2.3 GB). Timestamps describe audio chunks of up to 20 seconds."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker(tr("음성 언어", "Audio language"), selection: $model.language) {
                    ForEach(FileTranscription.languages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(model.isRunning)
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button(model.isCancelling ? tr("취소 중…", "Cancelling…") : tr("취소", "Cancel")) {
                        model.cancel()
                    }.disabled(model.isCancelling)
                } else {
                    Button(tr("전사 시작", "Transcribe")) { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.source == nil)
                }
            }
            ScrollView {
                Text(model.text.isEmpty
                     ? tr("전사 결과가 여기에 표시됩니다.", "The transcript will appear here.")
                     : model.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let directory = model.outputDirectory {
                Button(model.result == nil
                       ? tr("작업 폴더 열기", "Open Working Folder")
                       : tr("저장된 트랜스크립트 폴더 열기", "Open Saved Transcript Folder")) {
                    _ = SessionFolderOpener.system.open(directory)
                }
                .help(directory.path)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 480)
    }
}
