import AppKit
import SwiftUI

struct FinderDropArea<Content: View>: NSViewRepresentable {
    let target: HubModel.UploadTarget?
    @Binding var isTargeted: Bool
    let accept: ([URL], HubModel.UploadTarget) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Host {
        let view = Host(rootView: content())
        view.sizingOptions = []
        view.registerForDraggedTypes([.fileURL])
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.rootView = content()
        view.target = target
        view.accept = accept
        view.setTargeted = { value in
            if isTargeted != value { isTargeted = value }
        }
    }

    final class Host: NSHostingView<Content> {
        var target: HubModel.UploadTarget?
        var accept: (([URL], HubModel.UploadTarget) -> Void)?
        var setTargeted: ((Bool) -> Void)?

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            updateTarget(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            updateTarget(sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            setTargeted?(false)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            canAccept(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { setTargeted?(false) }
            return acceptFileDrop(from: sender.draggingPasteboard, operations: sender.draggingSourceOperationMask)
        }

        func acceptFileDrop(from pasteboard: NSPasteboard, operations: NSDragOperation) -> Bool {
            guard operations.contains(.copy), let target, let accept,
                  let urls = pasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
                  ) as? [URL], !urls.isEmpty else { return false }

            // An upload conflict can open a sheet. Let AppKit finish the drag first.
            DispatchQueue.main.async { accept(urls, target) }
            return true
        }

        private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
            let allowed = canAccept(sender)
            setTargeted?(allowed)
            return allowed ? .copy : []
        }

        private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
            target != nil && sender.draggingSourceOperationMask.contains(.copy) &&
                sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        }
    }
}
