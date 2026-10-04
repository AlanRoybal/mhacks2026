import CoreImage.CIFilterBuiltins
import SwiftUI
import TwinKit

/// "Proof of income" (`POST /wallet/income-statement`): a statement of paid work built from Bounty's escrow
/// ledger, with a public link (and QR code) a landlord or lender can open to check it. Shared as a PDF.
struct IncomeStatementSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var period: Period = .year
    @State private var statement: IncomeStatement?
    @State private var pdf: URL?
    @State private var isWorking = false
    @State private var error: String?

    enum Period: String, CaseIterable, Identifiable {
        case year, ninetyDays = "90d", all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .year: "This year"
            case .ninetyDays: "Last 90 days"
            case .all: "All time"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: period) { _, _ in statement = nil; pdf = nil }
                } footer: {
                    Text("Only payouts that left escrow count. Each statement gets a link anyone can open to check the numbers with Bounty, so a landlord or lender doesn\u{2019}t have to take a screenshot on trust.")
                }

                if let statement {
                    Section("Statement") {
                        LabeledContent("Paid to you", value: statement.totalPaid.formatted(.currency(code: "USD")))
                        LabeledContent("Paid jobs", value: "\(statement.jobCount)")
                        LabeledContent("Reliability", value: statement.stats.reliability.formatted(.percent.precision(.fractionLength(0))))
                        ForEach(statement.months, id: \.month) { month in
                            LabeledContent(Self.monthTitle(month.month), value: month.total.formatted(.currency(code: "USD")))
                        }
                    }
                    Section {
                        if let url = URL(string: statement.verifyUrl) {
                            HStack(spacing: 14) {
                                if let qr = QRCode.image(for: statement.verifyUrl) {
                                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Link("Open verification page", destination: url)
                                    Text(statement.verifyUrl).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                                }
                            }
                        }
                        if let pdf {
                            ShareLink(item: pdf, preview: SharePreview("Bounty income statement")) {
                                Label("Share PDF", systemImage: "square.and.arrow.up")
                            }
                        }
                    } header: {
                        Text("Verification")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Proof of income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else if statement == nil {
                        Button("Create") { Task { await create() } }
                    }
                }
            }
        }
    }

    private func create() async {
        guard let api = services.api else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let fresh: IncomeStatement = try await api.request(.post, "wallet/income-statement", body: ["period": period.rawValue])
            statement = fresh
            pdf = StatementPDF.write(fresh, periodTitle: period.title)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func monthTitle(_ month: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: month) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

struct IncomeStatement: Decodable, Sendable {
    struct Month: Decodable, Sendable { let month: String; let total: Decimal; let jobs: Int }
    struct Job: Decodable, Sendable { let title: String; let paidAt: Date; let amount: Decimal; let reference: String? }
    struct Stats: Decodable, Sendable { let reliability: Double; let jobsCompleted: Int; let rating: Double? }

    let id: String
    let workerName: String
    let issuedAt: Date
    let totalPaid: Decimal
    let jobCount: Int
    let months: [Month]
    let jobs: [Job]
    let stats: Stats
    let verifyUrl: String
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Renders the statement to a one-page US Letter PDF in the temporary directory.
@MainActor
enum StatementPDF {
    static func write(_ statement: IncomeStatement, periodTitle: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bounty income statement.pdf")
        let renderer = ImageRenderer(content: StatementDocument(statement: statement, periodTitle: periodTitle).frame(width: 612, height: 792))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

private struct StatementDocument: View {
    let statement: IncomeStatement
    let periodTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bounty").font(.system(size: 22, weight: .bold))
                    Text("Income statement \u{00B7} \(periodTitle)").font(.system(size: 13)).foregroundStyle(.gray)
                }
                Spacer()
                if let qr = QRCode.image(for: statement.verifyUrl) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 84, height: 84)
                }
            }
            Text(statement.workerName).font(.system(size: 18, weight: .semibold))
            Text(statement.totalPaid.formatted(.currency(code: "USD"))).font(.system(size: 36, weight: .bold))
            Text("\(statement.jobCount) paid jobs \u{00B7} reliability \(statement.stats.reliability.formatted(.percent.precision(.fractionLength(0))))\(statement.stats.rating.map { " \u{00B7} rated \($0.formatted())/5" } ?? "")")
                .font(.system(size: 12)).foregroundStyle(.gray)
            Divider()
            ForEach(Array(statement.jobs.prefix(18).enumerated()), id: \.offset) { _, job in
                HStack {
                    Text(job.paidAt.formatted(date: .abbreviated, time: .omitted)).frame(width: 90, alignment: .leading)
                    Text(job.title).lineLimit(1)
                    Spacer()
                    Text(job.amount.formatted(.currency(code: "USD")))
                }
                .font(.system(size: 11))
            }
            if statement.jobs.count > 18 {
                Text("\(statement.jobs.count - 18) more on the verification page").font(.system(size: 11)).foregroundStyle(.gray)
            }
            Spacer()
            Divider()
            Text("Verify at \(statement.verifyUrl)").font(.system(size: 9, design: .monospaced))
            Text("Issued \(statement.issuedAt.formatted(date: .long, time: .shortened)). Every amount was held in escrow by Bounty and released after the work was verified. Bounty generates this statement from its payment ledger; the worker can\u{2019}t edit it.")
                .font(.system(size: 9)).foregroundStyle(.gray)
        }
        .padding(48)
        .foregroundStyle(.black)
        .background(.white)
    }
}
