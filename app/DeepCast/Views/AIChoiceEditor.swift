import SwiftUI

/// Pickers for research, script, verifier and speech – used in Settings and per episode.
struct AIChoiceEditor: View {
    @Binding var choice: AIChoice
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Sprachmodelle", selection: $choice.llmMode) {
            ForEach(LLMMode.allCases) { Text($0.title).tag($0) }
        }
        if choice.llmMode == .openRouter {
            modelPicker("Recherche (Plan, Aussagen)", selection: $choice.research)
            modelPicker("Skript (Gliederung, Dialog)", selection: $choice.script)
            Toggle("Unabhängiger Prüfer", isOn: Binding(
                get: { choice.verifier != nil },
                set: { choice.verifier = $0 ? AppSettings.defaultVerifier : nil }))
            if let verifier = choice.verifier {
                modelPicker("Prüfer (Faktencheck)", selection: Binding(get: { verifier }, set: { choice.verifier = $0 }))
            }
        }
        Picker("Sprachausgabe (TTS)", selection: $choice.speechMode) {
            ForEach(SpeechMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private func modelPicker(_ title: LocalizedStringKey, selection: Binding<ModelRef>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModelProvider.allCases, id: \.self) { provider in
                let models = settings.pickerModels(including: selection.wrappedValue).filter { $0.provider == provider }
                if !models.isEmpty {
                    Section(provider.label + (settings.hasKey(for: provider) ? "" : " – kein Key")) {
                        ForEach(models) { model in Text(model.displayName).tag(model) }
                    }
                }
            }
        }
    }
}

extension AIChoice {
    var summary: String {
        let speech = speechMode == .appleOnly ? "Apple-Stimmen" : "Fish Audio"
        guard llmMode == .openRouter else { return "Apple Intelligence · \(speech)" }
        let verifierText = verifier.map { " · Prüfer: \($0.displayName)" } ?? ""
        return "Recherche: \(research.displayName) · Skript: \(script.displayName)\(verifierText) · \(speech)"
    }
}
