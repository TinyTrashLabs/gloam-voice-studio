import StudioKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gvoice = UTType(exportedAs: "fm.gloam.gvoice",
                               conformingTo: .zip)
}

struct DataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.gvoice, .wav]
    static let writableContentTypes: [UTType] = [.gvoice, .wav]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
