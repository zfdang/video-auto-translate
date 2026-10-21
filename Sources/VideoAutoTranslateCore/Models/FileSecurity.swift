import Foundation

public extension URL {
    /// 解析所有符号链接（包括各层级父目录符号链接别名）后的绝对规范化路径 (FU02)
    var canonicalFilePath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(self.path, &buffer) != nil {
            return String(cString: buffer)
        }
        // 若目标文件尚不存在，解析其父目录符号链接后拼接文件名
        let parent = self.deletingLastPathComponent()
        if realpath(parent.path, &buffer) != nil {
            let resolvedParent = String(cString: buffer)
            return (resolvedParent as NSString).appendingPathComponent(self.lastPathComponent)
        }
        return self.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 判断当前 URL 与另一 URL 是否指向同一底层物理文件（支持父目录别名、符号链接与硬链接）
    func pointsToSameFile(as other: URL) -> Bool {
        if self.canonicalFilePath == other.canonicalFilePath {
            return true
        }
        if let idA = try? self.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let idB = try? other.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            if idA.isEqual(idB) {
                return true
            }
        }
        return false
    }
}
