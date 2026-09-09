import SwiftUI

struct MeetingLanguagePicker: View {
    let title: String
    let recorder: MeetingRecorder

    var body: some View {
        Picker(title, selection: Binding(
            get: { recorder.language },
            set: { next in Task { await recorder.chooseLanguage(next) } }
        )) {
            ForEach(recorder.availableLanguages) { language in
                Text(language.displayName).tag(language)
            }
        }
        .disabled(recorder.availableLanguages.isEmpty || recorder.isPreparingModel)
    }
}
