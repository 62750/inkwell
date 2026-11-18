import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ObjectiveC

// MARK: - 文件选择器（UIKit 直接 present）
//
// 走过的弯路：
//   1. SwiftUI .fileImporter —— 在 iOS 26 上和 .searchable / 多个 presentation
//      共存时完成回调不触发，表现就是"点打开没反应"
//   2. .sheet { UIDocumentPickerViewController } —— 二次嵌套 modal，部分版本白屏
//
// 现在直接用 UIKit 从最顶层 VC present，delegate 用关联对象保活。
// asCopy: true 让系统把文件复制进 App 沙盒，返回的 URL 直接可读。

enum FilePicker {

    private static var delegateKey: UInt8 = 0

    static func present(types: [UTType] = [.item],
                        allowsMultiple: Bool = true,
                        onPick: @escaping ([URL]) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            var top = window.rootViewController else {
            logE("import", "找不到活动窗口，无法弹出文件选择器")
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }

        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = allowsMultiple
        vc.shouldShowFileExtensions = true

        let delegate = PickerDelegate(handler: onPick)
        objc_setAssociatedObject(vc, &delegateKey, delegate,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        vc.delegate = delegate

        logD("import", "弹出文件选择器")
        // 从 Menu 里触发时，等菜单收起动画结束再 present，避免 present 被丢弃
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var target = top
            while let presented = target.presentedViewController {
                target = presented
            }
            target.present(vc, animated: true)
        }
    }

    final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        private let handler: ([URL]) -> Void

        init(handler: @escaping ([URL]) -> Void) {
            self.handler = handler
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            logD("import", "选中 \(urls.count) 个文件：\(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
            handler(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            logD("import", "用户取消")
        }
    }
}
