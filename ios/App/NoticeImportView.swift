import PhotosUI
import SwiftUI
import UIKit
import Vision

enum NoticeOCR {
    static func recognize(_ data: Data) async throws -> String {
        guard data.count <= 25_000_000 else { throw LedgerError.message("25MB 이하의 화면 캡처를 선택해주세요.") }
        guard let image = UIImage(data: data)?.cgImage else { throw LedgerError.message("이미지를 읽을 수 없습니다.") }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: LedgerError.message("화면에서 거래 문구를 찾지 못했습니다."))
                } else { continuation.resume(returning: text) }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

struct NoticeImportView: View {
    @EnvironmentObject var model: BudgetModel
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var sourceID = ""
    @State private var pastedText = ""
    @State private var working = false
    private var sources: [[String: Any]] {
        (model.settings["cardSources"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool ?? true }
    }
    var body: some View {
        Form {
            Section("카드사") {
                Picker("카드사", selection: $sourceID) {
                    ForEach(sources.indices, id: \.self) { index in
                        Text(sources[index]["name"] as? String ?? "")
                            .tag(sources[index]["id"] as? String ?? "")
                    }
                }
            }
            Section("푸시 화면 캡처") {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(working ? "기기에서 인식 중…" : "사진에서 푸시 화면 선택", systemImage: "text.viewfinder")
                }.disabled(working || sourceID.isEmpty)
                Text("앱은 이미지를 업로드하거나 장부에 저장하지 않습니다. 아이폰의 Vision OCR로 읽은 뒤 앱의 메모리 사본을 버리고, 카드번호가 가려진 거래 결과만 저장합니다. 사진 앱에 있는 원본 캡처는 사용자가 별도로 삭제할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("또는 알림 문구 붙여넣기") {
                TextEditor(text: $pastedText).frame(minHeight: 100)
                Button("문구 기록") { record(pastedText, origin: "shortcut") }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceID.isEmpty)
            }
        }.navigationTitle("푸시 화면 가져오기")
            .toolbar { Button("닫기") { dismiss() } }
            .task { if sourceID.isEmpty { sourceID = sources.first?["id"] as? String ?? "" } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                working = true
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw LedgerError.message("사진 데이터를 읽을 수 없습니다.")
                        }
                        let text = try await NoticeOCR.recognize(data)
                        record(text, origin: "screenshot")
                    } catch { model.message = error.localizedDescription }
                    photo = nil; working = false
                }
            }
    }
    private func record(_ text: String, origin: String) {
        guard let source = sources.first(where: { $0["id"] as? String == sourceID }) else {
            model.message = "카드사를 선택해주세요."; return
        }
        let ok = model.save("sms", ["text": text, "id": UUID().uuidString,
            "sourceName": source["name"] as? String ?? "", "origin": origin])
        pastedText = ""
        if ok { dismiss() }
    }
}
