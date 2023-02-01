// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import CoreData
import Pulse
import Combine

#if os(iOS)

struct ConsoleTextView: View {
    @StateObject private var viewModel = ConsoleTextViewModel()
    @State private var shareItems: ShareItems?
    @State private var isShowingSettings = false
    @ObservedObject private var settings: ConsoleTextViewSettings = .shared

    let entities: CurrentValueSubject<[NSManagedObject], Never>
    let events: PassthroughSubject<ConsoleUpdateEvent, Never>
    var options: TextRenderer.Options?
    var onClose: (() -> Void)?

    var body: some View {
        RichTextView(viewModel: viewModel.text)
            .textViewBarItemsHidden(true)
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let options = options {
                    viewModel.options = options
                }
                viewModel.bind(entities: entities, events: events)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let onClose = onClose {
                        Button(action: onClose) {
                            Text("Cancel")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Menu(content: {
                            AttributedStringShareMenu(shareItems: $shareItems) {
                                viewModel.text.textStorage
                            }
                        }, label: {
                            Label("Share...", systemImage: "square.and.arrow.up")
                        })
                        Menu(content: { menu }) {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(item: $shareItems, content: ShareView.init)
            .sheet(isPresented: $isShowingSettings) { settingsView }
    }

    @ViewBuilder
    private var menu: some View {
        Section {
            Button(action: { viewModel.isExpanded.toggle() }) {
                Label(viewModel.isExpanded ? "Collapse Details" : "Expand Details", systemImage: viewModel.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Button(action: viewModel.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.disabled(viewModel.isButtonRefreshHidden)
        }
        Section {
            Button(action: { isShowingSettings = true }) {
                Label("Settings", systemImage: "gearshape")
            }
        }
        //            // Unfortunately, this isn't working properly in UITextView (use WebView!)
        //            Button(action: viewModel.text.scrollToBottom) {
        //                Label("Scroll to Bottom", systemImage: "arrow.down")
        //            }
    }

    private var settingsView: some View {
        NavigationView {
            ConsoleTextViewSettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button("Done") {
                    isShowingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        viewModel.reloadOptions()
                        viewModel.refresh()
                    }
                })
        }
    }
}

private struct ConsoleTextViewSettingsView: View {
    @ObservedObject private var settings: ConsoleTextViewSettings = .shared

    var body: some View {
        Form {
            Section(header: Text("Appearance")) {
                Picker("Color Mode", selection: $settings.colorMode) {
                    Text("Automatic").tag(TextRenderer.ColorMode.automatic)
                    Text("Full").tag(TextRenderer.ColorMode.full)
                    Text("Monochrome").tag(TextRenderer.ColorMode.monochrome)
                }
            }
            Section(header: Text("Request Info")) {
                Toggle("Request Headers", isOn: $settings.showsRequestHeaders)
                Toggle("Response Headers", isOn: $settings.showsResponseHeaders)
                Toggle("Request Body", isOn: $settings.showsRequestBody)
                Toggle("Response Body", isOn: $settings.showsResponseBody)
            }
            Section {
                Button("Reset Settings") {
                    settings.reset()
                }
                .foregroundColor(.red)
            }
        }
    }
}

#warning("when expand, perform a diff insert-remove to make sure ranges are updated")

struct ConsoleTextItemViewModel {
    var range: NSRange = NSRange(location: NSNotFound, length: 0)
}

final class ConsoleTextViewModel: ObservableObject {
    var text = RichTextViewModel()
    var options: TextRenderer.Options = .init()

    @Published var isExpanded = false
    @Published private(set) var isButtonRefreshHidden = true

    private var content: NetworkContent = []
    private var expanded: Set<NSManagedObjectID> = []
    private let settings = ConsoleTextViewSettings.shared
    private var entities: CurrentValueSubject<[NSManagedObject], Never> = .init([])
    private var lastTimeRefreshHidden = Date().addingTimeInterval(-3)
    private var objectIDs: [UUID: NSManagedObjectID] = [:]
    private var items: [ConsoleTextItemViewModel] = []
    private var cancellables: [AnyCancellable] = []

    init() {
        self.text.onLinkTapped = { [unowned self] in onLinkTapped($0) }
        self.reloadOptions()

        $isExpanded.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.expanded.removeAll()
            self?.refreshText()
        }.store(in: &cancellables)
    }

#warning("fix crash during search")
#warning("add an option to pause")

    func bind(entities: CurrentValueSubject<[NSManagedObject], Never>, events: PassthroughSubject<ConsoleUpdateEvent, Never>) {
        self.entities = entities

        events.sink { [weak self] in
            switch $0 {
            case .reload:
                self?.refresh()
            case .diff(let diff):
                self?.apply(diff)
            }
        }.store(in: &cancellables)

        self.refresh()
    }

    func apply(_ diff: CollectionDifference<NSManagedObjectID>) {
        let renderer = TextRenderer(options: options)
        text.performUpdates {
            for change in diff {
                switch change {
                case let .insert(offset, _, _):
                    insertEntity(at: offset, storage: $0, using: renderer)
                case let .remove(offset, _, _):
                    removeEntity(at: offset, storage: $0)
                }
            }
        }
    }

    private func insertEntity(at offset: Int, storage: NSTextStorage, using renderer: TextRenderer) {
        let reversedIndex = items.endIndex - offset
        let entity = entities.value[offset]
        var viewModel = ConsoleTextItemViewModel()

        let string = render(entity, using: renderer)

        let insertionStringIndex = reversedIndex > 0 ? items[reversedIndex - 1].range.upperBound : 0
        viewModel.range = NSRange(location: insertionStringIndex, length: string.length)

        storage.insert(string, at: insertionStringIndex)
        items.insert(viewModel, at: reversedIndex)

        for index in (reversedIndex + 1)..<items.endIndex {
            items[index].range.location += viewModel.range.length
        }
    }

    private func removeEntity(at offset: Int, storage: NSTextStorage) {
        let reversedIndex = items.endIndex - offset - 1
        let viewModel = items[reversedIndex]
        items.remove(at: reversedIndex)
        storage.deleteCharacters(in: viewModel.range)

        for index in reversedIndex..<items.endIndex {
            items[index].range.location -= viewModel.range.length
        }
    }

    func reloadOptions() {
        content = makeNetworkContent()
        options.color = settings.colorMode
        text.isLinkDetectionEnabled = false
    }

    func refresh() {
        self.refreshText()
        self.hideRefreshButton()
    }

#warning("when refershing, take advantage of ConsoleTextEntityViewModel cache (use a dictionary?)")
    private func refreshText() {
        let entities = entities.value.reversed()
        let renderer = TextRenderer(options: options)
        let output = NSMutableAttributedString()
        var items: [ConsoleTextItemViewModel] = []
        for entity in entities {
            var viewModel = ConsoleTextItemViewModel()
            let string = render(entity, using: renderer)
            viewModel.range = NSRange(location: output.length, length: string.length)
            output.append(string)
            items.append(viewModel)
        }
        self.items = items
        self.text.display(output)
    }

    private func render(_ entity: NSManagedObject, using renderer: TextRenderer) -> NSAttributedString {
        if let task = entity as? NetworkTaskEntity {
            render(task, using: renderer)
        } else if let message = entity as? LoggerMessageEntity {
            if let task = message.task {
                render(task, using: renderer)
            } else {
                render(message, using: renderer)
            }
        } else {
            fatalError("Unsuppported entity: \(entity)")
        }
        renderer.addSpacer()
        return renderer.make()
    }

    private func render(_ message: LoggerMessageEntity, using renderer: TextRenderer) {
        if let task = message.task {
            render(task, using: renderer)
        } else {
            renderer.render(message)
        }
    }

    private func render(_ task: NetworkTaskEntity, using renderer: TextRenderer) {
        let isExpanded = isExpanded || expanded.contains(task.objectID)
        guard !isExpanded else {
            return renderer.render(task, content: content) // Render everything
        }

        renderer.render(task, content: [.header])

        let uuid = UUID()
        objectIDs[uuid] = task.objectID
        var attributes = renderer.helper.attributes(role: .body2, weight: .regular)
        attributes[.foregroundColor] = UXColor.systemBlue
        attributes[.link] = URL(string: "pulse://expand/\(uuid.uuidString)")
        attributes[.objectId] = task.objectID
        attributes[.isTechnical] = true
        attributes[.underlineColor] = UXColor.clear
        renderer.append(NSAttributedString(string: "Show More\n", attributes: attributes))
    }

    private func makeNetworkContent() -> NetworkContent {
        var content = NetworkContent()
        func setEnabled(_ isEnabled: Bool, _ value: NetworkContent) {
            if isEnabled { content.insert(value) } else { content.remove(value) }
        }
        content.insert(.errorDetails)
        setEnabled(settings.showsRequestHeaders, .currentRequestHeaders)
        setEnabled(settings.showsRequestBody, .requestBody)
        setEnabled(settings.showsResponseHeaders, .responseHeaders)
        setEnabled(settings.showsResponseBody, .responseBody)
        return content
    }

    func onLinkTapped(_ url: URL) -> Bool {
        guard url.scheme == "pulse",
              url.host == "expand",
              let uuid = UUID(uuidString: url.lastPathComponent),
              let objectID = objectIDs[uuid] else {
            return false
        }
        expand(objectID)
        return true
    }

    private func expand(_ objectID: NSManagedObjectID) {
        // TODO: both searches are O(N) which isn't great
        guard let task = findTask(withObjectID: objectID) else {
            return
        }
        expanded.insert(objectID)

        var foundRange: NSRange?
        text.textStorage.enumerateAttribute(.objectId, in: NSRange(location: 0, length: text.textStorage.length)) { value, range, stop in
            if value as? NSManagedObjectID == objectID {
                foundRange = range
                stop.pointee = true
            }
        }
        if let range = foundRange {
            let details = TextRenderer(options: options).make {
                $0.addSpacer()
                $0.render(task, content: content)
            }
            text.performUpdates { storage in
                storage.replaceCharacters(in: range, with: details)
            }
        }
    }

    private func findTask(withObjectID objectID: NSManagedObjectID) -> NetworkTaskEntity? {
        if let messages = entities.value as? [LoggerMessageEntity] {
            return messages.first { $0.task?.objectID == objectID }?.task
        } else if let tasks = entities.value as? [NetworkTaskEntity] {
            return tasks.first { $0.objectID == objectID }
        } else {
            fatalError("Unsupported entities: \(entities)")
        }
    }

    private func hideRefreshButton() {
        guard !isButtonRefreshHidden else { return }
        isButtonRefreshHidden = true
    }

    private func showRefreshButtonIfNeeded() {
        guard isButtonRefreshHidden else { return }
        isButtonRefreshHidden = false
    }
}

#if DEBUG
struct ConsoleTextView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                ConsoleTextView(entities: entities) { _ in
                    return // Use default settings
                }
            }
            .previewDisplayName("Default")

            NavigationView {
                ConsoleTextView(entities: entities) {
                    $0.color = .full
                }
            }
            .previewDisplayName("Full Color")

            NavigationView {
                ConsoleTextView(entities: entities) {
                    $0.color = .monochrome
                }
            }
            .previewDisplayName("Monochrome")
        }
    }
}

private let entities = try! LoggerStore.mock.allMessages().filter {
    $0.logLevel != .trace
}

private extension ConsoleTextView {
    init(entities: [NSManagedObject], _ configure: (inout TextRenderer.Options) -> Void) {
        var options = TextRenderer.Options(color: .automatic)
        configure(&options)
        self.init(entities: .init(entities.reversed()), events: .init(), options: options, onClose: {})
    }
}

#endif

#endif
